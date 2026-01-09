-- ============================================================================
-- # OEE Monitoring Demo (Plant with Lines A, B, C)
-- ============================================================================
--
-- This script:
-- 1. Creates an OEE hypertable for three production lines (A, B, C)
-- 2. Inserts line metadata (production_lines)
-- 3. Generates demo OEE and environmental data (every 5 seconds for 7 days)
-- 4. Enables compression (columnstore) with a 24-hour policy
-- 5. Creates a 1-hour continuous aggregate (oee_1h) with real-time enabled
-- 6. Provides example queries for OEE per line and row-count comparison
--
-- Prerequisites:
-- - TigerData / TimescaleDB-compatible service with time-series + analytics
-- - Run this in psql or TigerData Console "Data" tab as a single script
-- ============================================================================


-- ============================================================================
-- ## Create Main OEE Hypertable
-- ============================================================================
-- Main OEE time-series table for three production lines A, B, C

CREATE TABLE oee_timeseries (
    time                 TIMESTAMPTZ NOT NULL,
    line_id              TEXT        NOT NULL,   -- 'A', 'B', 'C'
    shift                SMALLINT,               -- 1,2,3

    -- time / state metrics (per sample window, e.g. 5 seconds)
    planned_time_seconds         SMALLINT,
    planned_downtime_seconds     SMALLINT,
    unplanned_downtime_seconds   SMALLINT,
    runtime_seconds              SMALLINT,

    -- production output
    ideal_cycle_time_seconds DOUBLE PRECISION,   -- design target
    actual_output            INTEGER,            -- # parts produced
    good_output              INTEGER,            -- # good parts

    -- OEE components (stored as 0–1)
    availability   DOUBLE PRECISION,
    performance    DOUBLE PRECISION,
    quality        DOUBLE PRECISION,
    oee            DOUBLE PRECISION,            -- derived: A*P*Q (0–1)

    -- environmental signals
    temperature_c       DOUBLE PRECISION,
    vibration_mm_s      DOUBLE PRECISION,
    noise_db            DOUBLE PRECISION,
    energy_kwh          DOUBLE PRECISION,

    PRIMARY KEY (line_id, time)
)
WITH (
   tsdb.hypertable,
   tsdb.partition_column = 'time',
   tsdb.segmentby        = 'line_id',
   tsdb.orderby          = 'time DESC'
);


-- Helpful index to quickly filter by time alone if needed
CREATE INDEX IF NOT EXISTS idx_oee_time ON oee_timeseries (time DESC);



-- ============================================================================
-- ## Create Production Line Dimension Table
-- ============================================================================
-- Simple dimension table describing three production lines A, B, C

CREATE TABLE production_lines (
    line_id    TEXT PRIMARY KEY,  -- 'A', 'B', 'C'
    line_name  TEXT,
    plant      TEXT,
    target_oee DOUBLE PRECISION   -- e.g. 0.85 for 85%
);

INSERT INTO production_lines (line_id, line_name, plant, target_oee) VALUES
  ('A', 'Assembly Line A', 'Plant-1', 0.85),
  ('B', 'Assembly Line B', 'Plant-1', 0.88),
  ('C', 'Packaging Line C', 'Plant-1', 0.80);



-- ============================================================================
-- ## Data Generation Function
-- ============================================================================
-- Generates demo OEE + environmental data for lines A, B, C
-- Default: last 7 days, 5-second interval

CREATE OR REPLACE FUNCTION generate_oee_timeseries_demo(
    p_days INTEGER DEFAULT 7,
    p_interval_seconds INTEGER DEFAULT 5
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_start timestamptz := now() - make_interval(days => p_days);
    v_end   timestamptz := now();
BEGIN
    WITH base AS (
        SELECT
            ts,
            lp.line_id,

            -- Simple 3-shift logic
            CASE 
                WHEN EXTRACT(HOUR FROM ts) BETWEEN 6 AND 13 THEN 1
                WHEN EXTRACT(HOUR FROM ts) BETWEEN 14 AND 21 THEN 2
                ELSE 3
            END AS shift,

            -- 5-second sample window
            p_interval_seconds AS planned_time_seconds,

            -- Planned downtime (e.g. lunch + shift change)
            CASE 
                WHEN EXTRACT(HOUR FROM ts) = 12 THEN p_interval_seconds
                WHEN EXTRACT(HOUR FROM ts) = 14 AND EXTRACT(MINUTE FROM ts) < 15 THEN p_interval_seconds
                ELSE 0
            END AS planned_downtime_seconds,

            -- Unplanned downtime: depends on line profile
            CASE 
                WHEN random() < lp.unplanned_rate THEN p_interval_seconds
                ELSE 0
            END AS unplanned_downtime_seconds,

            lp.ideal_cycle_time_seconds,
            lp.throughput_rate,
            lp.parts_per_window,
            lp.good_rate,
            lp.base_performance,
            lp.base_quality,
            lp.temp_bias,
            lp.vibration_base,
            lp.vibration_spread,
            lp.noise_base,
            lp.energy_per_window
        FROM (
            -- Line profiles: A, B = assembly, C = packaging
            SELECT
                'A'::TEXT AS line_id,
                0.015     AS unplanned_rate,
                0.9       AS base_performance,
                0.97      AS base_quality,
                0.7       AS ideal_cycle_time_seconds,
                0.8       AS throughput_rate,
                1         AS parts_per_window,
                0.98      AS good_rate,
                3.0       AS temp_bias,
                0.4       AS vibration_base,
                0.6       AS vibration_spread,
                72        AS noise_base,
                0.0015    AS energy_per_window
            UNION ALL
            SELECT
                'B',
                0.010,
                0.88,
                0.96,
                0.8,
                0.7,
                1,
                0.97,
                2.0,
                0.3,
                0.4,
                68,
                0.0013
            UNION ALL
            SELECT
                'C',
                0.008,
                0.93,
                0.98,
                0.5,
                0.9,
                2,
                0.99,
                1.5,
                0.2,
                0.3,
                75,
                0.0020
        ) lp
        CROSS JOIN generate_series(
            v_start,
            v_end,
            make_interval(secs => p_interval_seconds)
        ) ts
    ),
    calc AS (
        SELECT
            ts AS time,
            line_id,
            shift,
            planned_time_seconds,
            planned_downtime_seconds,
            unplanned_downtime_seconds,

            -- Runtime: planned - downtime (clamped >= 0)
            GREATEST(
                0,
                planned_time_seconds
                - planned_downtime_seconds
                - unplanned_downtime_seconds
            ) AS runtime_seconds,

            ideal_cycle_time_seconds + (random() * 0.05) AS ideal_cycle_time_seconds,

            -- Actual output: only when running
            CASE 
                WHEN random() < throughput_rate
                     AND GREATEST(
                           0,
                           planned_time_seconds
                           - planned_downtime_seconds
                           - unplanned_downtime_seconds
                         ) > 0
                THEN parts_per_window
                ELSE 0
            END AS actual_output,

            -- Good output: slight scrap rate
            CASE 
                WHEN random() < good_rate
                     AND GREATEST(
                           0,
                           planned_time_seconds
                           - planned_downtime_seconds
                           - unplanned_downtime_seconds
                         ) > 0
                THEN parts_per_window
                ELSE 0
            END AS good_output,

            -- Availability (0–1)
            CASE 
                WHEN planned_time_seconds = 0 THEN 0
                ELSE GREATEST(
                       0,
                       planned_time_seconds
                       - planned_downtime_seconds
                       - unplanned_downtime_seconds
                     )::DOUBLE PRECISION / planned_time_seconds
            END AS availability,

            -- Performance (0.8–1.0-ish, biased per line)
            (base_performance + (random() * 0.1)) AS performance,

            -- Quality (0.95–0.99-ish, per line)
            (base_quality + random() * 0.02) AS quality,

            -- OEE (0–1)
            (
                CASE 
                    WHEN planned_time_seconds = 0 THEN 0
                    ELSE GREATEST(
                           0,
                           planned_time_seconds
                           - planned_downtime_seconds
                           - unplanned_downtime_seconds
                         )::DOUBLE PRECISION / planned_time_seconds
                END
                * (base_performance + (random() * 0.1))
                * (base_quality + random() * 0.02)
            ) AS oee,

            -- Temperature: base + daily wave + line bias
            25
            + 5 * sin(EXTRACT(EPOCH FROM ts)/3600.0)
            + temp_bias
            + random()*1.0 AS temperature_c,

            -- Vibration: assembly lines higher
            vibration_base + random()*vibration_spread AS vibration_mm_s,

            -- Noise: packaging noisy, others less
            noise_base + random()*3.0 AS noise_db,

            -- Energy: per 5s window scaled by availability
            (
                CASE 
                    WHEN planned_time_seconds = 0 THEN 0
                    ELSE GREATEST(
                           0,
                           planned_time_seconds
                           - planned_downtime_seconds
                           - unplanned_downtime_seconds
                         )::DOUBLE PRECISION / planned_time_seconds
                END
                * energy_per_window
                * (0.9 + random()*0.2)
            ) AS energy_kwh
        FROM base
    )
    INSERT INTO oee_timeseries (
        time,
        line_id,
        shift,
        planned_time_seconds,
        planned_downtime_seconds,
        unplanned_downtime_seconds,
        runtime_seconds,
        ideal_cycle_time_seconds,
        actual_output,
        good_output,
        availability,
        performance,
        quality,
        oee,
        temperature_c,
        vibration_mm_s,
        noise_db,
        energy_kwh
    )
    SELECT
        time,
        line_id,
        shift,
        planned_time_seconds,
        planned_downtime_seconds,
        unplanned_downtime_seconds,
        runtime_seconds,
        ideal_cycle_time_seconds,
        actual_output,
        good_output,
        availability,
        performance,
        quality,
        oee,
        temperature_c,
        vibration_mm_s,
        noise_db,
        energy_kwh
    FROM calc;
END;
$$;


-- Generate demo data: last 7 days, every 5 seconds
SELECT generate_oee_timeseries_demo(7, 5);



-- ============================================================================
-- ## Enable Compression (Columnstore) + Policy
-- ============================================================================
-- Enable compression and add a compression policy
-- to compress chunks older than 24 hours.

ALTER TABLE oee_timeseries
SET (
  timescaledb.compress = true,
  timescaledb.compress_segmentby = 'line_id',
  timescaledb.compress_orderby   = 'time DESC'
);

-- Add compression policy: compress chunks older than 24 hours
SELECT add_compression_policy(
  'oee_timeseries',
  INTERVAL '24 hours',
  if_not_exists => true
);

-- ============================================================================
-- ## Inspect Hypertable Chunks & Compression Stats
-- ============================================================================
-- Use these queries to inspect the internal chunk layout of oee_timeseries
-- and measure compression effectiveness.

-- List chunks, their time ranges, and compression status
SELECT
   chunk_name,
   range_start,
   range_end,
   is_compressed
FROM timescaledb_information.chunks
WHERE hypertable_name = 'oee_timeseries'
ORDER BY range_start;

-- Compression stats: total size before vs after compression
SELECT 
    pg_size_pretty(before_compression_total_bytes) AS before_compression,
    pg_size_pretty(after_compression_total_bytes)  AS after_compression,
    round(
      (1 - (after_compression_total_bytes::numeric / NULLIF(before_compression_total_bytes,0))) * 100,
      2
    ) AS compression_savings_pct
FROM hypertable_compression_stats('oee_timeseries');

-- ============================================================================
-- ## Create 1-Hour Continuous Aggregate
-- ============================================================================
-- 1-hour rollup of OEE metrics and environment data per line

CREATE MATERIALIZED VIEW oee_1h
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', time) AS bucket,
    line_id,

    -- time metrics
    SUM(planned_time_seconds)       AS planned_time_seconds,
    SUM(planned_downtime_seconds)   AS planned_downtime_seconds,
    SUM(unplanned_downtime_seconds) AS unplanned_downtime_seconds,
    SUM(runtime_seconds)            AS runtime_seconds,

    -- production
    SUM(actual_output)              AS actual_output,
    SUM(good_output)                AS good_output,
    AVG(ideal_cycle_time_seconds)   AS ideal_cycle_time_seconds,

    -- OEE components (averaged)
    AVG(availability) AS availability,
    AVG(performance)  AS performance,
    AVG(quality)      AS quality,
    AVG(oee)          AS oee,

    -- environment
    AVG(temperature_c)  AS temperature_c,
    AVG(vibration_mm_s) AS vibration_mm_s,
    AVG(noise_db)       AS noise_db,
    SUM(energy_kwh)     AS energy_kwh
FROM oee_timeseries
GROUP BY bucket, line_id;


-- Enable real-time reads (include raw + materialized data)
ALTER MATERIALIZED VIEW oee_1h
SET (timescaledb.materialized_only = false);


-- Continuous aggregate refresh policy (rolling 7 days)
SELECT add_continuous_aggregate_policy(
  'oee_1h',
  start_offset      => INTERVAL '7 days',
  end_offset        => INTERVAL '5 minutes',
  schedule_interval => INTERVAL '5 minutes'
);



-- ============================================================================
-- ## Example Queries: OEE per Production Line
-- ============================================================================
-- OEE by line for last 24 hours (raw hypertable)

SELECT
    line_id,
    ROUND((AVG(availability) * 100)::numeric, 2)  AS availability_pct,
    ROUND((AVG(performance) * 100)::numeric, 2)   AS performance_pct,
    ROUND((AVG(quality) * 100)::numeric, 2)       AS quality_pct,
    ROUND((AVG(oee) * 100)::numeric, 2)           AS oee_pct
FROM oee_timeseries
WHERE time >= now() - INTERVAL '24 hours'
GROUP BY line_id
ORDER BY line_id;


-- OEE by line for last 7 days (raw hypertable)

SELECT
    line_id,
    ROUND((AVG(availability) * 100)::numeric, 2)  AS availability_pct,
    ROUND((AVG(performance) * 100)::numeric, 2)   AS performance_pct,
    ROUND((AVG(quality) * 100)::numeric, 2)       AS quality_pct,
    ROUND((AVG(oee) * 100)::numeric, 2)           AS oee_pct
FROM oee_timeseries
WHERE time >= now() - INTERVAL '7 days'
GROUP BY line_id
ORDER BY line_id;


-- OEE by line for last 7 days using 1h CAGG (oee_1h)

SELECT
    line_id,
    ROUND((AVG(availability) * 100)::numeric, 2) AS availability_pct,
    ROUND((AVG(performance)  * 100)::numeric, 2) AS performance_pct,
    ROUND((AVG(quality)      * 100)::numeric, 2) AS quality_pct,
    ROUND((AVG(oee)          * 100)::numeric, 2) AS oee_pct
FROM oee_1h
WHERE bucket >= now() - INTERVAL '7 days'
GROUP BY line_id
ORDER BY line_id;



-- ============================================================================
-- ## Row Count Comparison: Raw vs CAGG
-- ============================================================================
-- Compare total number of rows between raw hypertable and 1-hour CAGG

SELECT
    (SELECT COUNT(*) FROM oee_timeseries) AS raw_count,
    (SELECT COUNT(*) FROM oee_1h)         AS cagg_1h_count;

-- ============================================================================
-- ## Performance Comparison: Raw vs 1h Continuous Aggregate
-- ============================================================================
-- Use these two queries to *demonstrate* performance benefits.
-- 1. Run the RAW query first and note execution time.
-- 2. Then run the CAGG query and note execution time.
-- Optionally uncomment EXPLAIN ANALYZE to show the query plan.

-- === RAW hypertable: OEE per line for last 2 months ===

EXPLAIN ANALYZE
SELECT
    line_id,
    ROUND((AVG(availability) * 100)::numeric, 2)  AS availability_pct,
    ROUND((AVG(performance) * 100)::numeric, 2)   AS performance_pct,
    ROUND((AVG(quality) * 100)::numeric, 2)       AS quality_pct,
    ROUND((AVG(oee) * 100)::numeric, 2)           AS oee_pct
FROM oee_timeseries
WHERE time >= now() - INTERVAL '2 months'
GROUP BY line_id
ORDER BY line_id;

-- === 1h Continuous Aggregate: OEE per line for last 2 months ===

EXPLAIN ANALYZE
SELECT
    line_id,
    ROUND((AVG(availability) * 100)::numeric, 2) AS availability_pct,
    ROUND((AVG(performance)  * 100)::numeric, 2) AS performance_pct,
    ROUND((AVG(quality)      * 100)::numeric, 2) AS quality_pct,
    ROUND((AVG(oee)          * 100)::numeric, 2) AS oee_pct
FROM oee_1h
WHERE bucket >= now() - INTERVAL '2 months'
GROUP BY line_id
ORDER BY line_id;

-- The 1h CAGG query should:
-- - Scan far fewer rows
-- - Use the materialized view instead of raw hypertable chunks
-- - Execute significantly faster, especially as data volume grows

