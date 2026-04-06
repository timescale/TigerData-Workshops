-- ============================================================================
-- # Oil & Gas Well Production Monitoring and Optimization
-- ============================================================================
-- Oil and gas operations generate continuous streams of production telemetry
-- from wellheads, downhole gauges, and surface equipment. This data —
-- pressure readings, flow rates, temperature, and choke position — arrives
-- at 15-minute intervals and must be stored, queried, and acted on at scale.
--
-- TigerData is purpose-built for this workload: high-ingest time-series data
-- with long-term retention, 90%+ compression, and SQL-based analytics across
-- months and years of production history — no new query language, no pipeline
-- overhead, no costly rebuilds as asset counts grow.
--
-- This workshop walks through building a production-grade well monitoring
-- database on TigerData, from schema design to continuous aggregates,
-- tiered storage, and automated data lifecycle policies.
-- ============================================================================
-- ## Prerequisites
-- ============================================================================
-- 1. A TigerData Cloud service with time-series and analytics enabled
--    https://console.cloud.timescale.com/signup
--
-- 2. Connection string from the TigerData Console:
--    postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require
--
-- 3. psql CLI installed (recommended):
--    https://www.tigerdata.com/blog/how-to-install-psql-on-mac-ubuntu-debian-windows
--
-- 4. Basic SQL knowledge
-- ============================================================================
-- ## What You'll Learn
-- ============================================================================
-- - Hypertables:           time-partitioned tables optimised for telemetry ingest
-- - Columnar compression:  90%+ storage reduction without sacrificing query speed
-- - Continuous aggregates: pre-computed daily rollups that auto-refresh in real time
-- - Tiered storage:        hot/warm/cold data tiers on S3 for multi-year retention
-- - Data retention:        automated lifecycle policies for raw telemetry
-- ============================================================================


-- ============================================================================
-- ## Setup: Drop Existing Objects
-- ============================================================================
-- (highlight and run this block to reset the workshop environment)

DROP TABLE IF EXISTS well_production CASCADE;
DROP TABLE IF EXISTS wells CASCADE;


-- ============================================================================
-- ## Create Tables
-- ============================================================================

-- Standard PostgreSQL reference table for well and field metadata.
-- This is the relational layer — static data that changes infrequently.
CREATE TABLE wells (
  id              SERIAL       PRIMARY KEY,
  well_name       VARCHAR(50)  NOT NULL,
  field_name      VARCHAR(50)  NOT NULL,
  operator        VARCHAR(100) NOT NULL,
  production_type VARCHAR(10)  NOT NULL CHECK (production_type IN ('Oil', 'Gas', 'Dual')),
  status          VARCHAR(20)  NOT NULL CHECK (status IN ('Active', 'Inactive', 'Suspended')),
  depth_ft        INTEGER,
  latitude        DOUBLE PRECISION,
  longitude       DOUBLE PRECISION,
  spud_date       DATE
);

-- Hypertable to store real-time wellhead and downhole telemetry.
--
-- Key TigerData settings:
--   tsdb.partition_column = 'time'
--       Automatically partitions data into weekly chunks by timestamp.
--       TigerData skips irrelevant chunks during time-range scans (chunk exclusion)
--       without reading a single row — critical for long-range production queries.
--
--   tsdb.enable_columnstore = true
--       Stores data in columnar format for 90%+ compression and faster
--       aggregation queries (AVG, SUM) that touch only a subset of columns.
--
--   tsdb.segmentby = 'well_id'
--       Each compressed segment holds all readings for one well.
--       Enables fast per-well queries without full table scans.
--
--   tsdb.orderby = 'time DESC'
--       Within each segment, readings are sorted newest-first — matching
--       the most common access pattern for operational dashboards.
--
--   tsdb.sparse_index = 'minmax(wellhead_pressure), minmax(oil_rate)'
--       Lightweight metadata per compressed segment.
--       WHERE wellhead_pressure < 1500 skips any segment whose min > 1500
--       without decompressing — fast anomaly detection across years of data.

CREATE TABLE well_production (
  time                  TIMESTAMPTZ      NOT NULL,
  well_id               INTEGER          NOT NULL,
  oil_rate              DOUBLE PRECISION,           -- bbl/day equivalent (instantaneous)
  gas_rate              DOUBLE PRECISION,           -- Mcf/day equivalent (instantaneous)
  water_rate            DOUBLE PRECISION,           -- bbl/day equivalent (instantaneous)
  wellhead_pressure     DOUBLE PRECISION,           -- psi
  wellhead_temperature  DOUBLE PRECISION,           -- degrees Fahrenheit
  choke_size            DOUBLE PRECISION,           -- 1/64th inch
  downhole_pressure     DOUBLE PRECISION,           -- psi
  FOREIGN KEY (well_id) REFERENCES wells (id)
) WITH (
  tsdb.hypertable,
  tsdb.partition_column   = 'time',
  tsdb.enable_columnstore = true,
  tsdb.segmentby          = 'well_id',
  tsdb.orderby            = 'time DESC',
  tsdb.sparse_index       = 'minmax(wellhead_pressure), minmax(oil_rate)'
);


-- ============================================================================
-- ## Create Indexes
-- ============================================================================
-- TigerData automatically creates an index on the partition column (time).
-- Add a composite index for efficient per-well time-range queries —
-- the dominant access pattern in production monitoring dashboards.

CREATE INDEX ON well_production (well_id, time DESC);


-- ============================================================================
-- ## Sparse Indexes: Fast Filtering on Compressed Data
-- ============================================================================
-- Sparse indexes are lightweight metadata structures stored with each
-- compressed segment. They allow TigerData to skip entire segments
-- during filtering without decompressing any data — critical for
-- pressure and production threshold queries spanning years of telemetry.
--
-- minmax(wellhead_pressure): skip segments where the pressure range
--                             cannot satisfy a WHERE filter
-- minmax(oil_rate):          skip segments where production is outside
--                             the queried range
--
-- You can also add or update sparse indexes after table creation:

ALTER TABLE well_production SET (
  timescaledb.compress_index = 'minmax(wellhead_pressure), minmax(oil_rate)'
);


-- ============================================================================
-- ## Populate Wells Reference Table
-- ============================================================================
-- 20 wells across four major U.S. producing basins.
-- Mix of Oil, Gas, and Dual producers with Active/Inactive/Suspended status.

INSERT INTO wells (well_name, field_name, operator, production_type, status, depth_ft, latitude, longitude, spud_date) VALUES
-- Permian Basin (Midland, TX) — tight oil and dual producers
('PB-Wolfcamp-01',  'Permian Basin', 'Pioneer Resources',  'Oil',  'Active',    9800, 31.97, -102.08, '2018-03-12'),
('PB-Wolfcamp-02',  'Permian Basin', 'Pioneer Resources',  'Dual', 'Active',   10200, 31.85, -102.15, '2019-06-04'),
('PB-Spraberry-01', 'Permian Basin', 'Devon Resources',    'Oil',  'Active',    8700, 32.10, -101.90, '2017-11-20'),
('PB-Spraberry-02', 'Permian Basin', 'Devon Resources',    'Dual', 'Active',    9100, 32.05, -101.85, '2020-02-14'),
('PB-Delaware-01',  'Permian Basin', 'Halcyon Petroleum',  'Oil',  'Suspended', 11400, 31.60, -102.40, '2016-08-30'),
-- Eagle Ford (South Texas) — oil and gas producers
('EF-LaSalle-01',   'Eagle Ford',   'Atlas Energy',        'Oil',  'Active',    8200, 28.35,  -99.80, '2019-04-18'),
('EF-LaSalle-02',   'Eagle Ford',   'Atlas Energy',        'Gas',  'Active',    7900, 28.42,  -99.75, '2020-09-22'),
('EF-Webb-01',      'Eagle Ford',   'Pioneer Resources',   'Oil',  'Active',    8500, 27.90,  -99.50, '2018-07-11'),
('EF-Webb-02',      'Eagle Ford',   'Pioneer Resources',   'Dual', 'Inactive',  8300, 27.95,  -99.45, '2017-03-05'),
('EF-Dimmit-01',    'Eagle Ford',   'Halcyon Petroleum',   'Gas',  'Active',    7600, 28.60,  -99.95, '2021-01-30'),
-- Bakken (Williston Basin, ND) — oil and dual producers
('BK-McKenzie-01',  'Bakken',       'Devon Resources',     'Oil',  'Active',   10800, 47.92, -103.40, '2016-05-17'),
('BK-McKenzie-02',  'Bakken',       'Devon Resources',     'Dual', 'Active',   11100, 47.88, -103.35, '2017-10-08'),
('BK-Williams-01',  'Bakken',       'Halcyon Petroleum',   'Oil',  'Active',   10500, 48.15, -103.60, '2019-12-01'),
('BK-Williams-02',  'Bakken',       'Halcyon Petroleum',   'Oil',  'Suspended',10900, 48.08, -103.55, '2018-04-25'),
('BK-Mountrail-01', 'Bakken',       'Atlas Energy',        'Dual', 'Active',   11300, 48.35, -102.80, '2020-07-14'),
-- Marcellus (Appalachian Basin, WV/PA) — gas producers
('MC-Wetzel-01',    'Marcellus',    'Atlas Energy',        'Gas',  'Active',    7200, 39.55,  -80.92, '2018-09-03'),
('MC-Wetzel-02',    'Marcellus',    'Atlas Energy',        'Gas',  'Active',    7400, 39.48,  -80.88, '2019-11-19'),
('MC-Marshall-01',  'Marcellus',    'Pioneer Resources',   'Gas',  'Active',    6900, 39.72,  -80.65, '2020-05-27'),
('MC-Marshall-02',  'Marcellus',    'Pioneer Resources',   'Gas',  'Inactive',  7100, 39.68,  -80.70, '2017-02-08'),
('MC-Tyler-01',     'Marcellus',    'Devon Resources',     'Gas',  'Active',    7300, 39.30,  -80.75, '2021-03-15');

-- Verify:
SELECT COUNT(*) AS wells_loaded FROM wells;
SELECT * FROM wells ORDER BY field_name, well_name;


-- ============================================================================
-- ## Generate Production Telemetry
-- ============================================================================
-- Simulates 15-minute wellhead readings for all 20 wells.
--
-- CONFIGURABLE PARAMETERS — adjust these to control data volume:
-- ---------------------------------------------------------------
-- default: 90 days (~172,800 rows)
--
--   Volume reference:
--     30  days × 20 wells × 96 readings/day =   57,600 rows
--     90  days × 20 wells × 96 readings/day =  172,800 rows
--     365 days × 20 wells × 96 readings/day =  700,800 rows
--
-- NOTE: Edit the INTERVAL literal directly, e.g. INTERVAL '30 days' or INTERVAL '365 days'.
-- ---------------------------------------------------------------

INSERT INTO well_production (
  time, well_id,
  oil_rate, gas_rate, water_rate,
  wellhead_pressure, wellhead_temperature,
  choke_size, downhole_pressure
)
SELECT
  time,
  well_id,
  -- Oil rate: per-well base profile + random noise (bbl/day)
  GREATEST(0, 200 + (well_id * 23 % 400) + random() * 80 - 40)          AS oil_rate,
  -- Gas rate: varies by basin (Mcf/day)
  GREATEST(0, 1000 + (well_id * 47 % 3000) + random() * 300 - 150)      AS gas_rate,
  -- Water cut varies by well maturity (bbl/day)
  GREATEST(0, 80 + (well_id * 13 % 250) + random() * 40 - 20)           AS water_rate,
  -- Wellhead pressure: adjusted to 8,000–12,000 psi
  GREATEST(8000, 10000 + (well_id * 11 % 2000) + random() * 1000 - 500) AS wellhead_pressure,
  -- Wellhead temperature: 140–200 °F
  140 + (well_id % 10) * 3 + random() * 20                              AS wellhead_temperature,
  -- Choke size: 16–48 / 64ths of an inch
  16 + ((well_id * 3 + EXTRACT(DOY FROM time)::INT) % 8) * 4            AS choke_size,
  -- Downhole pressure: always higher than wellhead
  GREATEST(12000, 13000 + (well_id * 17 % 2000) + random() * 1000 - 500) AS downhole_pressure

FROM
  generate_series(
    date_trunc('day', NOW()) - INTERVAL '90 days',
    date_trunc('day', NOW()) - INTERVAL '1 second',
    INTERVAL '15 minutes'
  ) AS g1(time),
  generate_series(1, 20) AS g2(well_id);


-- ============================================================================
-- ## Examine Hypertable Partitions
-- ============================================================================
-- TigerData automatically partitions the hypertable into time-based chunks.
-- Each chunk covers one week of data. During time-range queries, chunks
-- outside the filter window are skipped entirely — no rows read, no I/O.

SELECT
  chunk_name,
  range_start,
  range_end,
  is_compressed
FROM timescaledb_information.chunks
WHERE hypertable_name = 'well_production'
ORDER BY range_start DESC;

-- Sample output (90 days of data):
--          chunk_name          |      range_start       |       range_end        | is_compressed
-- -----------------------------+------------------------+------------------------+---------------
--  _hyper_1_13_chunk           | 2026-03-24 00:00:00+00 | 2026-03-31 00:00:00+00 | f
--  _hyper_1_12_chunk           | 2026-03-17 00:00:00+00 | 2026-03-24 00:00:00+00 | f
--  ...


-- ============================================================================
-- ## Verify the Dataset
-- ============================================================================
SELECT COUNT(*) AS total_readings FROM well_production;
SELECT * FROM well_production ORDER BY time DESC LIMIT 10;


-- ============================================================================
-- ## Sample Queries
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Query 1: Real-Time Field Production Summary
-- ----------------------------------------------------------------------------
-- Current average production rates across all active wells, grouped by basin
-- and production type. This is the operational dashboard query — run
-- continuously to track field-level performance and spot underperforming basins.
-- ----------------------------------------------------------------------------
SELECT
  w.field_name,
  w.production_type,
  COUNT(DISTINCT p.well_id)                        AS active_wells,
  ROUND(AVG(p.oil_rate)::NUMERIC, 1)              AS avg_oil_bopd,
  ROUND(AVG(p.gas_rate)::NUMERIC, 1)              AS avg_gas_mcfd,
  ROUND(AVG(p.water_rate)::NUMERIC, 1)            AS avg_water_bwpd,
  ROUND(AVG(p.wellhead_pressure)::NUMERIC, 0)     AS avg_whp_psi
FROM well_production p
JOIN wells w ON p.well_id = w.id
WHERE p.time >= NOW() - INTERVAL '24 hours'
  AND w.status = 'Active'
GROUP BY w.field_name, w.production_type
ORDER BY avg_oil_bopd DESC;

-- Sample output:
--   field_name    | production_type | active_wells | avg_oil_bopd | avg_gas_mcfd | avg_water_bwpd | avg_whp_psi
-- ----------------+-----------------+--------------+--------------+--------------+----------------+-------------
--  Bakken         | Dual            |            2 |        508.9 |       1631.0 |          255.1 |        2352
--  Bakken         | Oil             |            2 |        477.5 |       1567.5 |          235.4 |        2338
--  Marcellus      | Gas             |            4 |        409.2 |       1836.1 |          248.0 |        2388
--  Eagle Ford     | Gas             |            2 |        396.8 |       1393.2 |          190.6 |        2308
--  ...


-- ----------------------------------------------------------------------------
-- Query 2: Daily Production Trend for a Specific Well
-- ----------------------------------------------------------------------------
-- 30-day rolling daily summary for a single well using time_bucket().
-- Collapses 96 raw 15-minute readings per day into one row per day —
-- essential for decline curve analysis and production optimisation reviews.
-- Change well_id to inspect any well in the dataset.
-- ----------------------------------------------------------------------------
SELECT
  time_bucket('1 day', time)                        AS day,
  ROUND(AVG(oil_rate)::NUMERIC, 1)                  AS avg_oil_bopd,
  ROUND(AVG(gas_rate)::NUMERIC, 1)                  AS avg_gas_mcfd,
  ROUND(AVG(water_rate)::NUMERIC, 1)                AS avg_water_bwpd,
  ROUND((SUM(oil_rate) / 96.0)::NUMERIC, 1)        AS est_daily_oil_bbls,
  ROUND(AVG(wellhead_pressure)::NUMERIC, 0)         AS avg_whp_psi
FROM well_production
WHERE well_id = 1                            -- change to any well_id of interest
  AND time >= NOW() - INTERVAL '30 days'
GROUP BY day
ORDER BY day;


-- Remember the time it took to run the query above. After enabling
-- compression and creating the continuous aggregate, run the same
-- query on the c-agg and compare the execution time.



-- ----------------------------------------------------------------------------
-- Query 3: Well Performance Ranking and Pressure Anomaly Detection
-- ----------------------------------------------------------------------------
-- Ranks all active wells by oil production rate over the past 7 days and
-- flags wells with abnormal wellhead pressure. Low wellhead pressure can
-- indicate skin damage, scale build-up, choke failure, or declining
-- reservoir pressure — all requiring field intervention.
--
-- Adjust the alert thresholds to match your operational limits.
-- ----------------------------------------------------------------------------
SELECT
  w.well_name,
  w.field_name,
  w.operator,
  ROUND(AVG(p.oil_rate)::NUMERIC, 1)                                       AS avg_oil_bopd,
  ROUND(AVG(p.wellhead_pressure)::NUMERIC, 0)                              AS avg_whp_psi,
  ROUND(AVG(p.downhole_pressure)::NUMERIC, 0)                              AS avg_dhp_psi,
  ROUND((AVG(p.downhole_pressure) - AVG(p.wellhead_pressure))::NUMERIC, 0) AS pressure_drawdown_psi,
  CASE
    WHEN AVG(p.wellhead_pressure) < 1500 THEN 'LOW PRESSURE — INVESTIGATE'
    WHEN AVG(p.oil_rate) < 150           THEN 'LOW PRODUCTION — REVIEW'
    ELSE 'Normal'
  END AS alert_status
FROM well_production p
JOIN wells w ON p.well_id = w.id
WHERE p.time >= NOW() - INTERVAL '7 days'
  AND w.status = 'Active'
GROUP BY w.well_name, w.field_name, w.operator
ORDER BY avg_oil_bopd DESC;

-- ============================================================================
-- ## Enable Columnarstore (Compression)
-- ============================================================================
-- TigerData's columnar compression delivers 90%+ storage reduction for
-- time-series telemetry. Unlike row-based storage, columnar format groups
-- all values of a single column (e.g., oil_rate) together — ideal for
-- production queries that aggregate a few columns across thousands of rows.
--
-- The columnstore policy compresses chunks automatically after the specified
-- threshold. Keep the most recent 7 days uncompressed for fast SCADA ingest,
-- and let TigerData compress everything older automatically.

-- Columnstore is already enabled via tsdb.enable_columnstore = true at 
-- table creation — no separate policy call needed.
CALL add_columnstore_policy('well_production', after => INTERVAL '7 days');

-- Optionally, manually compress all chunks to see immediate storage savings
-- (the policy only applies to future chunks as they age past the threshold):

SELECT compress_chunk(c, true) FROM show_chunks('well_production') c;

-- SELECT decompress_chunk(c, true) FROM show_chunks('well_production') c;


-- ============================================================================
-- ## Storage Saved by Compression
-- ============================================================================
-- The same query on the compressed hypertable runs faster because
-- columnar storage reduces I/O and the sparse indexes skip irrelevant segments.
-- Note: your compression ratio may vary depending on span of data ingested and data cardinality

SELECT
  pg_size_pretty(before_compression_total_bytes) AS before_compression,
  pg_size_pretty(after_compression_total_bytes)  AS after_compression,
  ROUND(
    (1 - after_compression_total_bytes::NUMERIC / before_compression_total_bytes)
    * 100, 1
  ) AS compression_pct
FROM hypertable_compression_stats('well_production');

-- Sample output (90 days, 20 wells, 15-min intervals):
--  before_compression | after_compression | compression_pct
-- --------------------+-------------------+-----------------
--  32 MB              | 3.1 MB            |            90.3

-- Per-chunk breakdown:
SELECT
  c.chunk_name,
  c.range_start,
  c.range_end,
  c.is_compressed,
  pg_size_pretty(s.before_compression_total_bytes) AS before,
  pg_size_pretty(s.after_compression_total_bytes)  AS after,
  ROUND(
    (s.before_compression_total_bytes::NUMERIC - s.after_compression_total_bytes::NUMERIC)
    / s.before_compression_total_bytes::NUMERIC * 100, 1
  ) AS compression_pct
FROM timescaledb_information.chunks c
JOIN chunk_compression_stats('well_production') s ON c.chunk_name = s.chunk_name
ORDER BY c.range_start DESC;


-- ============================================================================
-- ## Create a Continuous Aggregate: Daily Well Production Summary
-- ============================================================================
-- Continuous aggregates pre-compute daily rollups from 15-minute telemetry.
-- Instead of scanning 96 raw readings per well per day, reporting queries
-- hit a single pre-aggregated row — orders of magnitude faster for
-- dashboards covering weeks, months, or years of production history.
--
-- timescaledb.materialized_only = false ensures the view returns
-- real-time data for the most recent (not-yet-aggregated) period,
-- unlike a standard PostgreSQL materialized view which requires
-- a manual REFRESH MATERIALIZED VIEW to include new data.

-- DROP MATERIALIZED VIEW IF EXISTS daily_well_production;
CREATE MATERIALIZED VIEW daily_well_production
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
  time_bucket('1 day', time)  AS day,
  well_id,
  AVG(oil_rate)               AS avg_oil_bopd,
  AVG(gas_rate)               AS avg_gas_mcfd,
  AVG(water_rate)             AS avg_water_bwpd,
  SUM(oil_rate) / 96.0       AS total_oil_bbls,    -- 96 x 15-min intervals per day
  SUM(gas_rate) / 96.0       AS total_gas_mcf,
  AVG(wellhead_pressure)      AS avg_whp_psi,
  MIN(wellhead_pressure)      AS min_whp_psi,
  MAX(wellhead_pressure)      AS max_whp_psi,
  AVG(downhole_pressure)      AS avg_dhp_psi
FROM well_production
GROUP BY day, well_id;

-- Refresh policy: keeps the view current as new telemetry arrives.
-- Updates the last 3 days on each run to handle late-arriving field data.
SELECT add_continuous_aggregate_policy('daily_well_production',
  start_offset      => INTERVAL '3 days',
  end_offset        => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour');


-- ============================================================================
-- ## Query the Continuous Aggregate
-- ============================================================================
-- Same result as Query 2 above, but against pre-aggregated data.
-- Run EXPLAIN ANALYZE on both to compare execution plans and timing.

--EXPLAIN ANALYZE
SELECT
  d.day,
  w.well_name,
  w.field_name,
  ROUND(d.avg_oil_bopd::NUMERIC, 1)    AS avg_oil_bopd,
  ROUND(d.avg_gas_mcfd::NUMERIC, 1)    AS avg_gas_mcfd,
  ROUND(d.total_oil_bbls::NUMERIC, 1)  AS est_daily_oil_bbls,
  ROUND(d.avg_whp_psi::NUMERIC, 0)     AS avg_whp_psi
FROM daily_well_production d
JOIN wells w ON d.well_id = w.id
WHERE d.well_id = 1
  AND d.day >= NOW() - INTERVAL '30 days'
ORDER BY d.day;


-- ============================================================================
-- ## Real-Time Continuous Aggregates
-- ============================================================================
-- Insert a live reading and confirm the continuous aggregate reflects it
-- immediately — no REFRESH needed, unlike standard PostgreSQL materialized views.

INSERT INTO well_production (time, well_id, oil_rate, gas_rate, water_rate,
  wellhead_pressure, wellhead_temperature, choke_size, downhole_pressure)
VALUES (NOW(), 1, 420.5, 1850.0, 95.0, 2650.0, 172.3, 32, 4350.0);

SELECT
  day,
  well_id,
  ROUND(avg_oil_bopd::NUMERIC, 1)  AS avg_oil_bopd,
  ROUND(avg_whp_psi::NUMERIC, 0)   AS avg_whp_psi
FROM daily_well_production
WHERE well_id = 1
  AND day >= NOW() - INTERVAL '2 days'
ORDER BY day DESC;

-- The new reading appears immediately in the result.
-- This is the stark contrast to a standard PostgreSQL materialized view
-- that would require REFRESH MATERIALIZED VIEW before the row shows up.


-- ============================================================================
-- ## Tier Data to S3 Storage
-- ============================================================================
-- Production data from mature wells remains valuable for decline curve
-- analysis and reserve estimation — but is queried infrequently.
-- TigerData's tiered storage moves data older than 30 days to low-cost S3,
-- retaining full SQL queryability at a fraction of the storage cost.
--
-- Enable tiered storage first in the TigerData Console:
--   Service → Explorer → Storage Configuration → Tiering Storage → Enabled

SELECT add_tiering_policy('well_production', INTERVAL '30 days');

-- Enable tiered reads for this session:
ALTER DATABASE tsdb SET timescaledb.enable_tiered_reads TO true;

-- Monitor tiering status:
SELECT * FROM timescaledb_osm.chunks_queued_for_tiering
WHERE hypertable_name = 'well_production';

SELECT * FROM timescaledb_osm.tiered_chunks
WHERE hypertable_name = 'well_production';


-- ============================================================================
-- ## Data Retention Policy
-- ============================================================================
-- Raw 15-minute telemetry provides operational value for roughly one year.
-- After that, the daily_well_production continuous aggregate provides the
-- long-term production record at dramatically lower storage cost.
--
-- This policy automatically drops raw telemetry chunks older than 1 year.
-- The continuous aggregate retains the daily summaries indefinitely.

SELECT add_retention_policy('well_production', INTERVAL '1 year');


-- ============================================================================
-- ## Add spatial capabilities to wells
-- We add a geometry column and spatial index to enable
-- fast spatial queries like "wells within radius" or "nearest wells".
-- ============================================================================

-- Enable PostGIS extension
CREATE EXTENSION IF NOT EXISTS postgis;

-- Add a geometry column based on lat/lon
ALTER TABLE wells
ADD COLUMN geom geometry(Point, 4326);

-- Populate geom column from latitude and longitude
UPDATE wells
SET geom = ST_SetSRID(ST_MakePoint(longitude, latitude), 4326);

-- Create a GiST spatial index for fast spatial queries
CREATE INDEX idx_wells_geom ON wells USING GIST (geom);

-- Spatial + production query examples
-- We join wells to well_production to bring in the latest
-- production metrics for each well.

-- Example 1: Wells within 10 km of a given location, last 7 days
SELECT
    w.id,
    w.well_name,
    w.latitude,
    w.longitude,
    wp.time AS prod_time,
    wp.oil_rate,
    wp.gas_rate,
    wp.water_rate,
    wp.wellhead_pressure,
    wp.wellhead_temperature,
    wp.choke_size,
    wp.downhole_pressure
FROM wells w
JOIN well_production wp
    ON wp.well_id = w.id
    AND wp.time >= NOW() - INTERVAL '7 days'  -- last 7 days
WHERE ST_DWithin(
    w.geom::geography,
    ST_SetSRID(ST_MakePoint(-102.15, 31.90), 4326)::geography,
    10000
);

-- Example 2: 5 nearest wells, last 7 days
SELECT
    w.id,
    w.well_name,
    w.latitude,
    w.longitude,
    wp.time AS prod_time,
    wp.oil_rate,
    wp.gas_rate,
    wp.water_rate,
    wp.wellhead_pressure,
    wp.wellhead_temperature,
    wp.choke_size,
    wp.downhole_pressure,
    ST_Distance(
        w.geom::geography,
        ST_SetSRID(ST_MakePoint(-99.75, 28.42), 4326)::geography
    ) AS distance_m
FROM wells w
JOIN well_production wp
    ON wp.well_id = w.id
    AND wp.time >= NOW() - INTERVAL '7 days'
ORDER BY w.geom <-> ST_SetSRID(ST_MakePoint(-99.75, 28.42), 4326)
LIMIT 5;

-- Example 3: Wells inside a bounding box, last 7 days
SELECT
    w.id,
    w.well_name,
    w.latitude,
    w.longitude,
    wp.time AS prod_time,
    wp.oil_rate,
    wp.gas_rate,
    wp.water_rate,
    wp.wellhead_pressure,
    wp.wellhead_temperature,
    wp.choke_size,
    wp.downhole_pressure
FROM wells w
JOIN well_production wp
    ON wp.well_id = w.id
    AND wp.time >= NOW() - INTERVAL '7 days'
WHERE w.geom && ST_MakeEnvelope(-103, 27, -99, 32, 4326);

