-- ============================================================================
-- # Wind Energy — Step 03: Hypertables
-- ============================================================================
-- Two time-series streams:
--
--   wind_measurements  the raw "sensor" reading — what the anemometer says
--   power_generation   the DERIVED metric — what that wind is worth in kW
--
-- Splitting them is deliberate. Raw measurements are the system of record and
-- you never want to lose or rewrite them. Derived values are a function of the
-- raw data plus turbine geometry, so if the power model improves you can
-- recompute power_generation from wind_measurements without re-ingesting
-- anything. Keeping them in one table would couple the two lifecycles.
--
-- Note the modern declarative form: the hypertable is created by the WITH
-- clause on CREATE TABLE, not by a separate create_hypertable() call.
-- ============================================================================


-- ============================================================================
-- ## wind_measurements — the raw sensor stream
-- ============================================================================
-- Key TigerData settings:
--
--   tsdb.partition_column = 'time'
--       Partitions into weekly chunks. Time-range queries skip irrelevant
--       chunks entirely (chunk exclusion) without reading a row.
--
--   tsdb.enable_columnstore = true
--       Columnar storage for older chunks: large compression gains, and
--       aggregate queries only read the columns they touch.
--
--   tsdb.segmentby = 'turbine_id'
--       Each compressed segment holds one turbine's readings. The dashboard's
--       per-turbine time series is the dominant read pattern, so this lets a
--       single-turbine query touch one segment instead of scanning all 40.
--
--   tsdb.orderby = 'time DESC'
--       Newest-first within a segment, matching "show me the last 24 hours".
--
--   tsdb.sparse_index = 'minmax(wind_speed_ms)'
--       Per-segment min/max metadata. A query for storm conditions
--       (wind_speed_ms > 25) skips any segment whose max is below 25 without
--       decompressing it.

-- TWO wind speeds, and the distinction is physical rather than bookkeeping:
--
--   free_wind_speed_ms  the undisturbed regional wind — what a met mast at the
--                       edge of the site would read
--   wind_speed_ms       what THIS turbine's nacelle anemometer reads, after any
--                       upwind machines in the same plant have taken energy out
--                       of the air
--
-- Real SCADA systems record both, for exactly this reason: the difference is the
-- wake loss, and with only one of them you cannot tell "the wind dropped" from
-- "I am standing behind another turbine". Step 06 computes the second from the
-- first using the wake geometry precomputed in step 04.

CREATE TABLE wind_measurements (
  time                TIMESTAMPTZ      NOT NULL,
  turbine_id          UUID             NOT NULL,
  plant_id            UUID,                        -- denormalized, see power_generation
  free_wind_speed_ms  DOUBLE PRECISION,            -- undisturbed regional wind, m/s
  wind_speed_ms       DOUBLE PRECISION,            -- at the nacelle, after wake losses
  wind_direction_deg  DOUBLE PRECISION,            -- degrees, 0 = from north, clockwise
  temperature_c       DOUBLE PRECISION,            -- degrees Celsius
  source              TEXT             NOT NULL,   -- 'backfill' | 'model_live'
  CONSTRAINT wind_measurements_source_valid
    CHECK (source IN ('backfill', 'model_live')),
  CONSTRAINT wind_measurements_direction_range
    CHECK (wind_direction_deg >= 0 AND wind_direction_deg < 360)
) WITH (
  tsdb.hypertable,
  tsdb.partition_column   = 'time',
  tsdb.enable_columnstore = true,
  tsdb.segmentby          = 'turbine_id',
  tsdb.orderby            = 'time DESC',
  tsdb.sparse_index       = 'minmax(wind_speed_ms)'
);

-- TigerData indexes the partition column automatically. Add the composite
-- index for per-turbine time-range scans over the uncompressed hot window.
CREATE INDEX ON wind_measurements (turbine_id, time DESC);


-- ============================================================================
-- ## power_generation — the derived metric
-- ============================================================================
-- Four columns here are denormalized on purpose:
--
--   wind_speed_ms   copied from wind_measurements so a power-vs-wind chart is
--                   a single-table scan rather than a join across two
--                   hypertables on (time, turbine_id).
--
--   plant_id and    copied from the dimension tables so the plant-level and
--   region_name     region-level continuous aggregates can GROUP BY them with NO
--                   JOIN at all. This matters more than it looks: continuous
--                   aggregates that join a plain dimension table do NOT track
--                   changes to that table, so editing a region boundary or
--                   moving a turbine between plants would silently leave the
--                   rollup stale forever. Writing the dimension onto the fact
--                   row at insert time removes the trap.
--
--   wake_loss_pct   how much of this turbine's output was lost to upwind
--                   machines in its own plant, at this instant. Derived, and
--                   stored because it is expensive to recompute (it depends on
--                   the wind direction at that moment) and because it is the
--                   headline number for judging a plant's layout.
--
-- The cost is the usual one for denormalization: if a turbine is reassigned,
-- historical rows keep the old label. For a fleet-analytics rollup that is
-- arguably the behaviour you want anyway.

-- TWO power figures, and the pair is the point:
--
--   expected_power_kw  what the power curve says a HEALTHY turbine should make in
--                      the wind this turbine actually measured
--   power_kw           what it really produced
--
-- The ratio between them is the performance ratio, and it is the only way to see
-- a degrading turbine. Output alone cannot tell you: 800 kW is excellent in light
-- wind and alarming in a gale. Storing both as POWER rather than storing the ratio
-- is deliberate — sums of power aggregate cleanly at any grain, so
-- SUM(power_kw) / SUM(expected_power_kw) is a valid performance ratio for a
-- turbine, a plant, a region or the whole fleet. A stored ratio would need a
-- weight to survive the same rollup.

CREATE TABLE power_generation (
  time              TIMESTAMPTZ      NOT NULL,
  turbine_id        UUID             NOT NULL,
  plant_id          UUID,                     -- denormalized from turbines
  region_name       TEXT,                     -- denormalized from plants
  power_kw          DOUBLE PRECISION,         -- ACTUAL output, after fault derate
  expected_power_kw DOUBLE PRECISION,         -- healthy output at the same wind
  wind_speed_ms     DOUBLE PRECISION,         -- nacelle wind, after wake losses
  wake_loss_pct     DOUBLE PRECISION          -- % lost to upwind turbines in the plant
) WITH (
  tsdb.hypertable,
  tsdb.partition_column   = 'time',
  tsdb.enable_columnstore = true,
  tsdb.segmentby          = 'turbine_id',
  tsdb.orderby            = 'time DESC',
  tsdb.sparse_index       = 'minmax(power_kw), minmax(expected_power_kw)'
);

CREATE INDEX ON power_generation (turbine_id, time DESC);

-- Plant and region are the two rollup levels, so index both.
CREATE INDEX ON power_generation (plant_id, time DESC);
CREATE INDEX ON power_generation (region_name, time DESC);


-- ============================================================================
-- ## Verify
-- ============================================================================

SELECT hypertable_name, num_dimensions, compression_enabled
  FROM timescaledb_information.hypertables
 WHERE hypertable_name IN ('wind_measurements', 'power_generation')
 ORDER BY hypertable_name;

--  hypertable_name   | num_dimensions | compression_enabled
-- -------------------+----------------+---------------------
--  power_generation  |              1 | t
--  wind_measurements |              1 | t
-- (2 rows)

-- num_dimensions = 1 is intentional: we partition on time only. the Fleet Tracking workshop
-- explains at length why adding a second (space) dimension for the entity id
-- is the wrong lever for per-entity performance.
