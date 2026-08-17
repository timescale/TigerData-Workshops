-- ============================================================================
-- # Wind Energy — Step 08: The Continuous Aggregate Hierarchy
-- ============================================================================
-- Four aggregates arranged as a THREE-LEVEL ROLLUP CHAIN that mirrors the way the
-- dashboard is navigated:
--
--   power_generation                (raw: 96 turbines x up to 4 readings/hour)
--        |
--        +-- cagg_turbine_power_hourly      one row per TURBINE per hour
--                 |
--                 +-- cagg_turbine_power_daily   one row per TURBINE per day
--                 |
--                 +-- cagg_plant_power_hourly    one row per PLANT per hour
--                          |
--                          +-- cagg_regional_power_hourly
--                                                one row per REGION per hour
--
-- Each level is built on the level below, not on the raw hypertable. Two
-- consequences, and they are the whole point of this file:
--
--   REFRESH IS CHEAP. Rolling 96 pre-computed turbine rows into 12 plant rows
--   costs far less than re-reading the raw rows, and rolling 12 plant rows into 6
--   region rows costs almost nothing. The expensive scan happens once, at the
--   bottom, and every level above reuses it.
--
--   READS ARE FLAT. Every dashboard view reads the level matching its own
--   cardinality, so rows scanned stays roughly constant however large the fleet
--   grows. A fleet overview does not touch 96 turbines' worth of data to draw six
--   lines.
--
-- Step 11 measures both claims.
-- ============================================================================


-- ============================================================================
-- ## Setup: Drop Existing Objects
-- ============================================================================
-- Strict dependency order — children before parents, or the drop is refused.

DROP VIEW IF EXISTS v_turbine_hourly;
DROP VIEW IF EXISTS v_region_hourly;
DROP VIEW IF EXISTS v_plant_hourly;
DROP VIEW IF EXISTS v_wind_daily;
DROP VIEW IF EXISTS v_wind_hourly;
DROP MATERIALIZED VIEW IF EXISTS cagg_wind_daily;
DROP MATERIALIZED VIEW IF EXISTS cagg_wind_hourly;
DROP MATERIALIZED VIEW IF EXISTS cagg_regional_power_daily;
DROP MATERIALIZED VIEW IF EXISTS cagg_regional_power_hourly;
DROP MATERIALIZED VIEW IF EXISTS cagg_plant_power_daily;
DROP MATERIALIZED VIEW IF EXISTS cagg_plant_power_hourly;
DROP MATERIALIZED VIEW IF EXISTS cagg_turbine_power_daily;
DROP MATERIALIZED VIEW IF EXISTS cagg_turbine_power_hourly;


-- ============================================================================
-- ## Level 1: cagg_turbine_power_hourly — the foundation
-- ============================================================================
-- The only aggregate that reads the raw hypertable, so this is the one place the
-- expensive scan happens. Everything else is derived from it.
--
-- It carries plant_id AND region_name even though neither identifies a turbine.
-- That is deliberate: hierarchical aggregates CANNOT JOIN, so any column a higher
-- level needs to group by must already be present here. Both were denormalized
-- onto power_generation at insert time (step 03) precisely so this chain works.
--
-- `readings` is not decoration either — it is the weight that keeps every average
-- correct as it rolls up. See level 2.
--
-- Note materialized_only = false on every level. That turns on REAL-TIME
-- AGGREGATION, and in a hierarchy it recurses: a query against the region view
-- blends materialized region rows with live aggregation reaching all the way down
-- to raw rows newer than the last refresh. If ANY level in the chain were
-- materialized_only = true the recursion would stop there and every level above it
-- would go stale between refreshes. Real-time aggregation has also been OFF by
-- default since TimescaleDB 2.13, so it must be stated rather than assumed.

-- A note on CHUNK INTERVAL, because the obvious tuning here backfires.
--
-- A continuous aggregate's materialization defaults to a chunk interval of 10x
-- its source's — 70 days, given our 7-day raw chunks. A columnstore policy can
-- only compress a chunk once its NEWEST row is older than the policy window, so
-- with 70-day chunks and a 30-day policy roughly 100 days of aggregate always
-- stays in the rowstore. The apparent fix is to shrink the chunk interval so more
-- of it becomes eligible.
--
-- Measured on two years of history, `cagg_turbine_power_hourly`:
--
--   default 70-day chunks, no compression        777 MB
--   default 70-day chunks, compressed (10/12)    484 MB
--   14-day chunks, compressed (50/53)            857 MB   <-- worse than doing nothing
--
-- Shrinking the interval turned 12 chunks into 53, and each chunk carries its own
-- group indexes: 240 MB of index across the smaller chunks, which swamped the
-- extra compression. The default wins, so `chunk_interval` is deliberately NOT
-- set here.
--
-- Note also that `columnstore` cannot be set in this WITH clause at all —
-- TimescaleDB rejects it:
--   ERROR: cannot enable compression while creating a continuous aggregate
--   HINT:  Use ALTER MATERIALIZED VIEW to enable compression.
-- so the columnstore settings for all four aggregates live in step 09.

CREATE MATERIALIZED VIEW cagg_turbine_power_hourly
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket('1 hour', time)  AS bucket,
       turbine_id,
       plant_id,                              -- carried up for level 3
       region_name,                           -- carried up for level 4
       AVG(power_kw)                AS avg_power_kw,
       -- Carried at every level so performance ratio is SUM(actual)/SUM(expected)
       -- at any grain. See the note on performance ratio below.
       AVG(expected_power_kw)       AS avg_expected_power_kw,
       MIN(power_kw)                AS min_power_kw,
       MAX(power_kw)                AS max_power_kw,
       AVG(wind_speed_ms)           AS avg_wind_ms,
       MAX(wind_speed_ms)           AS max_wind_ms,
       AVG(wake_loss_pct)           AS avg_wake_loss_pct,
       MAX(wake_loss_pct)           AS max_wake_loss_pct,
       COUNT(*)                     AS readings
  FROM power_generation
 GROUP BY bucket, turbine_id, plant_id, region_name
WITH NO DATA;

-- Refresh policy. The offsets are the part worth understanding:
--
--   start_offset => 7 days   how far back each run looks for invalidated buckets.
--                            Must cover the window in which data can still arrive
--                            or be corrected.
--
--   end_offset => 1 hour     leave the current bucket alone. It is incomplete and
--                            still receiving writes, so its aggregate would be
--                            outdated within seconds. Real-time aggregation covers
--                            it instead — that division of labour is exactly what
--                            these two settings are for.
--
-- Keep start_offset shorter than any retention policy on the source. Refreshing a
-- bucket whose raw rows were already dropped rewrites it as EMPTY, silently
-- destroying history you thought you had rolled up.

-- Its refresh policy is registered after the initial fill — see
-- "Register the refresh policies" below.

-- Refreshed below, incrementally. See "Filling them".


-- ============================================================================
-- ## Level 2: cagg_turbine_power_daily — same grain, coarser bucket
-- ============================================================================
-- Per turbine, per day. Feeds long-window charts: over 90 days a daily series is
-- 90 points where the hourly one is 2,160, and no screen can render the
-- difference.
--
-- WEIGHTED AVERAGES, and this is the classic silent bug in a rollup chain.
-- AVG(avg_power_kw) is only correct when every input bucket holds the same number
-- of readings. Ours do not: the backfill writes hourly and the live simulation
-- writes every 15 minutes, so a bucket may hold 1 reading or 4. Averaging the
-- averages would over-weight the sparse hours.
--
--     SUM(avg_power_kw * readings) / SUM(readings)
--
-- is the arithmetic mean of the underlying readings whatever the bucket sizes.
-- MIN and MAX compose without any such caveat, which is why they roll up directly.
--
-- Hierarchical bucket rules: the parent bucket must be an integer multiple of the
-- child's. 1 day over 1 hour is fine. 90 minutes over 1 hour is rejected, and so
-- is a month over a week, because the number of weeks in a month is not an integer.

CREATE MATERIALIZED VIEW cagg_turbine_power_daily
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket('1 day', bucket) AS day,
       turbine_id,
       plant_id,
       region_name,
       SUM(avg_power_kw * readings)      / NULLIF(SUM(readings), 0) AS avg_power_kw,
       SUM(avg_expected_power_kw * readings) / NULLIF(SUM(readings), 0)
                                         AS avg_expected_power_kw,
       MIN(min_power_kw)                 AS min_power_kw,
       MAX(max_power_kw)                 AS max_power_kw,
       SUM(avg_wind_ms * readings)       / NULLIF(SUM(readings), 0) AS avg_wind_ms,
       MAX(max_wind_ms)                  AS max_wind_ms,
       SUM(avg_wake_loss_pct * readings) / NULLIF(SUM(readings), 0) AS avg_wake_loss_pct,
       MAX(max_wake_loss_pct)            AS max_wake_loss_pct,
       SUM(readings)                     AS readings
  FROM cagg_turbine_power_hourly
 GROUP BY day, turbine_id, plant_id, region_name
WITH NO DATA;

-- Its refresh policy is registered after the initial fill — see
-- "Register the refresh policies" below.

-- Refreshed below, incrementally, AFTER its parent.


-- ============================================================================
-- ## Level 3: cagg_plant_power_hourly — coarser grain, same bucket
-- ============================================================================
-- Per plant, per hour. The level at which a wind farm is actually managed: one
-- grid connection, one operator, one power purchase agreement, one crew.
--
-- This rolls up the GRAIN (turbine to plant) while keeping the BUCKET the same.
-- TimescaleDB accepts an hourly aggregate on an hourly aggregate — a 1x multiple
-- is still a multiple — and it is far cheaper than re-reading raw rows.
--
-- PLANT OUTPUT MUST NOT BE `SUM(power_kw)` OVER RAW ROWS. Worth dwelling on,
-- because the wrong version looks obviously right and silently multiplies.
--
-- Summing raw power readings inside a bucket sums across BOTH turbines AND time.
-- With hourly backfill each turbine contributes one reading, so the sum happens to
-- equal plant output. The moment the live simulation starts writing every 15
-- minutes each turbine contributes four, and "plant output" jumps 4x with no
-- change in actual generation. Measured on this dataset: 32,909 kW became
-- 67,275 kW when readings per bucket went from 8 to 16.
--
-- Power is an INSTANTANEOUS quantity. Aggregate it across turbines by summing;
-- across time by averaging. So:
--
--     SUM(avg_power_kw)   -- sum of per-turbine hourly MEANS
--
-- is the plant's mean output over the hour in kW, completely independent of how
-- many readings each turbine reported. Rolling up a pre-averaged child makes this
-- natural rather than fiddly — another reason the hierarchy earns its place.
--
-- For ENERGY rather than power, multiply by the bucket width:
-- plant_power_kw x 1 hour = kWh in that hour.

CREATE MATERIALIZED VIEW cagg_plant_power_hourly
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket('1 hour', bucket) AS bucket,
       plant_id,
       region_name,
       -- Mean output of the whole plant, kW. Reading-count independent.
       SUM(avg_power_kw)                 AS plant_power_kw,
       -- What a fully healthy plant should have made in the same wind.
       SUM(avg_expected_power_kw)        AS plant_expected_power_kw,
       -- Mean output of a single turbine, for comparing plants of different sizes.
       AVG(avg_power_kw)                 AS avg_turbine_power_kw,
       MIN(min_power_kw)                 AS min_turbine_power_kw,
       MAX(max_power_kw)                 AS max_turbine_power_kw,
       SUM(avg_wind_ms * readings)       / NULLIF(SUM(readings), 0) AS avg_wind_ms,
       MAX(max_wind_ms)                  AS max_wind_ms,
       SUM(avg_wake_loss_pct * readings) / NULLIF(SUM(readings), 0) AS avg_wake_loss_pct,
       -- One child row per turbine per bucket, so a plain COUNT is the headcount.
       COUNT(*)                          AS turbines_reporting,
       SUM(readings)                     AS readings
  FROM cagg_turbine_power_hourly
 -- GROUP BY the time_bucket EXPRESSION, not the alias.
 --
 -- The output column is named `bucket` and so is the INPUT column coming from the
 -- child aggregate. PostgreSQL resolves a bare name in GROUP BY against input
 -- columns first, so `GROUP BY bucket` silently groups by the child's bucket
 -- rather than by this level's time_bucket() call — and TimescaleDB then rejects
 -- the view with:
 --
 --   ERROR:  continuous aggregate view must include a valid time bucket function
 --
 -- which is a confusing message for what is really a name-shadowing problem. The
 -- daily aggregate above avoids it purely by accident, because it aliases to
 -- `day` and nothing shadows that.
 GROUP BY time_bucket('1 hour', bucket), plant_id, region_name
WITH NO DATA;

-- Its refresh policy is registered after the initial fill — see
-- "Register the refresh policies" below.

-- Refreshed below, incrementally, AFTER its parent.


-- ============================================================================
-- ## Level 4: cagg_regional_power_hourly — the portfolio view
-- ============================================================================
-- Per region, per hour. Six rows an hour for the entire world, which is exactly
-- what the fleet overview draws.
--
-- Built on the PLANT level, not on raw. By this point the chain has reduced the
-- raw rows for an hour to 96 turbine rows to 12 plant rows to 6 region rows, and
-- each step only had to read the step below it.
--
-- No join to `regions` anywhere in this file. Continuous aggregates have supported
-- joining a hypertable to a plain table since TimescaleDB 2.10, so it would be
-- legal — and a trap, because only changes to the HYPERTABLE are tracked for
-- invalidation. Redraw a region boundary and a joined aggregate keeps serving the
-- old grouping forever with nothing to signal it is stale. Carrying region_name up
-- the chain from the fact row avoids that entirely.

CREATE MATERIALIZED VIEW cagg_regional_power_hourly
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket('1 hour', bucket) AS bucket,
       region_name,
       -- Sum of plant means = region mean output, kW.
       SUM(plant_power_kw)               AS region_power_kw,
       SUM(plant_expected_power_kw)      AS region_expected_power_kw,
       AVG(avg_turbine_power_kw)         AS avg_turbine_power_kw,
       MIN(min_turbine_power_kw)         AS min_turbine_power_kw,
       MAX(max_turbine_power_kw)         AS max_turbine_power_kw,
       SUM(avg_wind_ms * readings)       / NULLIF(SUM(readings), 0) AS avg_wind_ms,
       MAX(max_wind_ms)                  AS max_wind_ms,
       SUM(avg_wake_loss_pct * readings) / NULLIF(SUM(readings), 0) AS avg_wake_loss_pct,
       SUM(turbines_reporting)           AS turbines_reporting,
       COUNT(*)                          AS plants_reporting,
       SUM(readings)                     AS readings
  FROM cagg_plant_power_hourly
 -- Again the explicit expression, not the alias — see the note on level 3.
 GROUP BY time_bucket('1 hour', bucket), region_name
WITH NO DATA;

-- Its refresh policy is registered after the initial fill — see
-- "Register the refresh policies" below.

-- Refreshed below, incrementally, AFTER its parent.


-- ============================================================================
-- ## Daily tiers for plant and region — completing the grid
-- ============================================================================
--
-- Every dashboard timeline uses the same three-tier zoom-selection pattern (see
-- 13_turbine_history.sql and the general form in GRAFANA_PLATFORM.md), and that
-- pattern needs a DAILY tier at each entity grain, not just the turbine grain.
-- Without these two, the region and plant timelines would have to fall back to the
-- hourly aggregate at every zoom level — reading 17,520 rows per region for a
-- two-year window instead of 730.
--
-- They are cheap. 12 plants x 730 days is 8,760 rows and 6 regions x 730 days is
-- 4,380 — a few MB between them, against the ~140 MB of their hourly parents.
--
-- Both roll up their OWN hourly aggregate, keeping the chain one level deep at each
-- step, and every mean is READING-COUNT WEIGHTED for the reason spelled out on
-- cagg_turbine_power_daily: an unweighted AVG() of hourly averages would weight a
-- partial hour the same as a full one, and over a 730-day window the partial hours
-- at both ends are exactly where a seasonal curve is read.

CREATE MATERIALIZED VIEW cagg_plant_power_daily
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket('1 day', bucket)   AS day,
       plant_id,
       region_name,
       SUM(plant_power_kw * readings)          / NULLIF(SUM(readings), 0) AS plant_power_kw,
       SUM(plant_expected_power_kw * readings) / NULLIF(SUM(readings), 0) AS plant_expected_power_kw,
       SUM(avg_turbine_power_kw * readings)    / NULLIF(SUM(readings), 0) AS avg_turbine_power_kw,
       MIN(min_turbine_power_kw)               AS min_turbine_power_kw,
       MAX(max_turbine_power_kw)               AS max_turbine_power_kw,
       SUM(avg_wind_ms * readings)             / NULLIF(SUM(readings), 0) AS avg_wind_ms,
       MAX(max_wind_ms)                        AS max_wind_ms,
       SUM(avg_wake_loss_pct * readings)       / NULLIF(SUM(readings), 0) AS avg_wake_loss_pct,
       MAX(turbines_reporting)                 AS turbines_reporting,
       SUM(readings)                           AS readings
  FROM cagg_plant_power_hourly
 GROUP BY time_bucket('1 day', bucket), plant_id, region_name
WITH NO DATA;

-- Its refresh policy is registered after the initial fill — see
-- "Register the refresh policies" below.


CREATE MATERIALIZED VIEW cagg_regional_power_daily
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket('1 day', bucket)   AS day,
       region_name,
       SUM(region_power_kw * readings)          / NULLIF(SUM(readings), 0) AS region_power_kw,
       SUM(region_expected_power_kw * readings) / NULLIF(SUM(readings), 0) AS region_expected_power_kw,
       SUM(avg_turbine_power_kw * readings)     / NULLIF(SUM(readings), 0) AS avg_turbine_power_kw,
       MIN(min_turbine_power_kw)                AS min_turbine_power_kw,
       MAX(max_turbine_power_kw)                AS max_turbine_power_kw,
       SUM(avg_wind_ms * readings)              / NULLIF(SUM(readings), 0) AS avg_wind_ms,
       MAX(max_wind_ms)                         AS max_wind_ms,
       SUM(avg_wake_loss_pct * readings)        / NULLIF(SUM(readings), 0) AS avg_wake_loss_pct,
       MAX(turbines_reporting)                  AS turbines_reporting,
       MAX(plants_reporting)                    AS plants_reporting,
       SUM(readings)                            AS readings
  FROM cagg_regional_power_hourly
 GROUP BY time_bucket('1 day', bucket), region_name
WITH NO DATA;

-- Its refresh policy is registered after the initial fill — see
-- "Register the refresh policies" below.


-- ============================================================================
-- ## The weather chain: cagg_wind_hourly and cagg_wind_daily
-- ============================================================================
--
-- Everything above rolls up `power_generation` — what the fleet PRODUCED. These
-- two roll up `wind_measurements` — the weather it produced it in. They are a
-- separate chain rather than more columns on the power aggregates because they
-- answer a different question and have a different natural audience: "what is the
-- wind and temperature resource at this site, by season" is a siting and
-- forecasting question, not a performance one.
--
-- With two years of history this is where the per-region climatology seeded in
-- step 04 becomes visible. A daily rollup over 730 days is 730 rows per turbine,
-- so a two-year seasonal curve is a cheap query instead of a scan over 70,080
-- raw samples.
--
-- THREE measurements are carried, and the pairing matters:
--
--   free_wind_speed_ms   the undisturbed regional wind — the RESOURCE
--   wind_speed_ms        what the nacelle actually saw, after wake losses
--   temperature_c        air temperature, which sets air density and therefore
--                        how much power a given wind speed can deliver
--
-- Keeping free and waked wind side by side is what lets a query separate "the
-- wind dropped" from "I am standing behind another turbine".
--
-- WIND DIRECTION is carried too, but NOT as an angle. A bearing cannot be
-- averaged arithmetically — the mean of 350 and 10 degrees is 0, while AVG()
-- returns 180 — so these aggregates store the SUM of each reading's unit-vector
-- components (`dir_sin_sum`, `dir_cos_sum`), and the read views recover the
-- bearing with ATAN2. Component sums are additive, which is precisely what lets
-- the daily rollup add them and stay correct.
--
-- The same representation yields `dir_consistency` for free: the mean resultant
-- length, 0..1, measuring how steady the direction was inside the bucket. A stored
-- average angle could not give you that at any price. See the read views below,
-- and step 13 for the arithmetic this avoids.
--
-- Note there is no `region_name` here: unlike power_generation, wind_measurements
-- does not denormalize it. Region-level weather comes from the read views below,
-- which join `plants` — safe because a VIEW is evaluated at read time, unlike a
-- continuous aggregate, which must never join a dimension table.

CREATE MATERIALIZED VIEW cagg_wind_hourly
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket('1 hour', time)     AS bucket,
       turbine_id,
       plant_id,
       AVG(free_wind_speed_ms)         AS avg_free_wind_ms,
       MIN(free_wind_speed_ms)         AS min_free_wind_ms,
       MAX(free_wind_speed_ms)         AS max_free_wind_ms,
       AVG(wind_speed_ms)              AS avg_wind_ms,
       MIN(wind_speed_ms)              AS min_wind_ms,
       MAX(wind_speed_ms)              AS max_wind_ms,
       AVG(temperature_c)              AS avg_temp_c,
       MIN(temperature_c)              AS min_temp_c,
       MAX(temperature_c)              AS max_temp_c,
       -- WIND DIRECTION, stored as the SUM of its unit-vector components.
       --
       -- A bearing cannot be averaged arithmetically: the mean of 350 and 10
       -- degrees is 0, but AVG() returns 180. The fix is not to give up on
       -- direction — it is to stop storing an ANGLE. Project each reading onto the
       -- unit circle, keep the two component sums, and recover the bearing at read
       -- time with ATAN2.
       --
       -- SUMS, not averages, and that is the load-bearing detail. Sums are
       -- ADDITIVE, so the daily rollup below simply adds them and is correct for
       -- the whole day — the property an average of averages does not have. Same
       -- reason `readings` is carried alongside every mean in this file.
       SUM(SIN(RADIANS(wind_direction_deg))) AS dir_sin_sum,
       SUM(COS(RADIANS(wind_direction_deg))) AS dir_cos_sum,
       COUNT(*)                        AS readings
  FROM wind_measurements
 GROUP BY bucket, turbine_id, plant_id
WITH NO DATA;

-- Its refresh policy is registered after the initial fill — see
-- "Register the refresh policies" below.

-- Refreshed below, incrementally.


-- Daily, hierarchical on the hourly aggregate — never on the raw table.
--
-- Every mean is READING-COUNT WEIGHTED. `AVG(avg_temp_c)` would weight a partial
-- hour the same as a full one; over a 730-day window those edge buckets are the
-- difference between a seasonal curve you can trust and one that is quietly wrong
-- at both ends. MIN/MAX just nest, since the minimum of minima IS the minimum.
--
-- GROUP BY the time_bucket EXPRESSION, not the alias: PostgreSQL resolves a bare
-- `bucket` in GROUP BY against the CHILD aggregate's input column first, which
-- silently groups by the hourly bucket and fails with "continuous aggregate view
-- must include a valid time bucket function".

CREATE MATERIALIZED VIEW cagg_wind_daily
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket('1 day', bucket)    AS day,
       turbine_id,
       plant_id,
       SUM(avg_free_wind_ms * readings) / NULLIF(SUM(readings), 0) AS avg_free_wind_ms,
       MIN(min_free_wind_ms)           AS min_free_wind_ms,
       MAX(max_free_wind_ms)           AS max_free_wind_ms,
       SUM(avg_wind_ms * readings)     / NULLIF(SUM(readings), 0)  AS avg_wind_ms,
       MIN(min_wind_ms)                AS min_wind_ms,
       MAX(max_wind_ms)                AS max_wind_ms,
       SUM(avg_temp_c * readings)      / NULLIF(SUM(readings), 0)  AS avg_temp_c,
       MIN(min_temp_c)                 AS min_temp_c,
       MAX(max_temp_c)                 AS max_temp_c,
       -- A plain SUM of the hourly component sums. No weighting to get wrong:
       -- summing vectors across 24 hourly buckets is identical to summing them
       -- across the day's 96 raw readings. That is what "additive" buys, and it is
       -- why the components are stored instead of the angle — an angle would need
       -- the circular-mean machinery again at every level, and a mean of means
       -- would be wrong at every level.
       SUM(dir_sin_sum)                AS dir_sin_sum,
       SUM(dir_cos_sum)                AS dir_cos_sum,
       SUM(readings)                   AS readings
  FROM cagg_wind_hourly
 GROUP BY time_bucket('1 day', bucket), turbine_id, plant_id
WITH NO DATA;

-- Its refresh policy is registered after the initial fill — see
-- "Register the refresh policies" below.

-- Refreshed below, incrementally, AFTER its parent.


-- Read views. The join to plants/regions happens HERE, at read time, which is
-- exactly what a continuous aggregate may not do — a cagg that joined `plants`
-- would never invalidate when a plant was edited.

CREATE OR REPLACE VIEW v_wind_hourly AS
SELECT w.bucket,
       w.turbine_id,
       t.name          AS turbine_name,
       w.plant_id,
       p.plant_name,
       p.region_name,
       r.is_offshore,
       w.avg_free_wind_ms, w.min_free_wind_ms, w.max_free_wind_ms,
       w.avg_wind_ms,      w.min_wind_ms,      w.max_wind_ms,
       w.avg_temp_c,       w.min_temp_c,       w.max_temp_c,
       -- The circular mean, recovered from the stored components. ATAN2 covers
       -- every quadrant; +360 and MOD normalise into [0, 360).
       --
       -- The guard is not decoration. When a bucket's readings point in opposing
       -- directions the vectors cancel and the resultant collapses toward zero, at
       -- which point there IS no meaningful mean bearing — and ATAN2(0, 0) returns
       -- 0 in PostgreSQL, which would silently report a northerly. Below a
       -- resultant of 1% of the readings, return NULL rather than invent one.
       CASE
         WHEN SQRT(w.dir_sin_sum^2 + w.dir_cos_sum^2) < 0.01 * w.readings THEN NULL
         ELSE MOD((DEGREES(ATAN2(w.dir_sin_sum, w.dir_cos_sum)) + 360.0)::numeric,
                  360.0)::DOUBLE PRECISION
       END                                                        AS wind_direction_deg,
       -- Mean resultant length, 0..1 — a real wind-industry measure that falls out
       -- of this representation for free. 1.0 means every reading in the bucket
       -- pointed the same way; near 0 means the wind boxed the compass. It is the
       -- directional-steadiness half of a wind rose, and it cannot be computed at
       -- all from a stored average angle.
       SQRT(w.dir_sin_sum^2 + w.dir_cos_sum^2) / NULLIF(w.readings, 0)
                                                                  AS dir_consistency,
       -- How much of the resource this machine lost to its neighbours, as a
       -- percentage of the undisturbed wind.
       100.0 * (1 - w.avg_wind_ms / NULLIF(w.avg_free_wind_ms, 0)) AS wind_shadow_pct,
       w.readings
  FROM cagg_wind_hourly w
  JOIN turbines t ON t.turbine_id = w.turbine_id
  JOIN plants   p ON p.plant_id   = w.plant_id
  JOIN regions  r ON r.region_name = p.region_name;

CREATE OR REPLACE VIEW v_wind_daily AS
SELECT w.day,
       w.turbine_id,
       t.name          AS turbine_name,
       w.plant_id,
       p.plant_name,
       p.region_name,
       r.is_offshore,
       -- The region's own climatology, alongside what was actually measured, so a
       -- query can compare the two directly.
       r.wind_base_ms      AS region_wind_base_ms,
       r.wind_peak_doy     AS region_wind_peak_doy,
       r.temp_mean_c       AS region_temp_mean_c,
       r.temp_peak_doy     AS region_temp_peak_doy,
       w.avg_free_wind_ms, w.min_free_wind_ms, w.max_free_wind_ms,
       w.avg_wind_ms,      w.min_wind_ms,      w.max_wind_ms,
       w.avg_temp_c,       w.min_temp_c,       w.max_temp_c,
       -- The circular mean, recovered from the stored components. ATAN2 covers
       -- every quadrant; +360 and MOD normalise into [0, 360).
       --
       -- The guard is not decoration. When a bucket's readings point in opposing
       -- directions the vectors cancel and the resultant collapses toward zero, at
       -- which point there IS no meaningful mean bearing — and ATAN2(0, 0) returns
       -- 0 in PostgreSQL, which would silently report a northerly. Below a
       -- resultant of 1% of the readings, return NULL rather than invent one.
       CASE
         WHEN SQRT(w.dir_sin_sum^2 + w.dir_cos_sum^2) < 0.01 * w.readings THEN NULL
         ELSE MOD((DEGREES(ATAN2(w.dir_sin_sum, w.dir_cos_sum)) + 360.0)::numeric,
                  360.0)::DOUBLE PRECISION
       END                                                        AS wind_direction_deg,
       -- Mean resultant length, 0..1 — a real wind-industry measure that falls out
       -- of this representation for free. 1.0 means every reading in the bucket
       -- pointed the same way; near 0 means the wind boxed the compass. It is the
       -- directional-steadiness half of a wind rose, and it cannot be computed at
       -- all from a stored average angle.
       SQRT(w.dir_sin_sum^2 + w.dir_cos_sum^2) / NULLIF(w.readings, 0)
                                                                  AS dir_consistency,
       100.0 * (1 - w.avg_wind_ms / NULLIF(w.avg_free_wind_ms, 0)) AS wind_shadow_pct,
       w.readings
  FROM cagg_wind_daily w
  JOIN turbines t ON t.turbine_id = w.turbine_id
  JOIN plants   p ON p.plant_id   = w.plant_id
  JOIN regions  r ON r.region_name = p.region_name;


-- Does the daily rollup reproduce the seeded climatology? This is the check that
-- the whole 2-year change exists for.

\echo ''
\echo '--- measured vs seeded: annual mean wind and temperature by region ---'

SELECT region_name,
       MAX(region_wind_base_ms)                     AS seeded_wind,
       ROUND(AVG(avg_free_wind_ms)::numeric, 2)     AS measured_wind,
       MAX(region_temp_mean_c)                      AS seeded_temp,
       ROUND(AVG(avg_temp_c)::numeric, 1)           AS measured_temp,
       ROUND(MIN(min_temp_c)::numeric, 1)           AS coldest,
       ROUND(MAX(max_temp_c)::numeric, 1)           AS hottest
  FROM v_wind_daily
 GROUP BY region_name
 ORDER BY measured_wind DESC;

-- Expected — measured within a few tenths of seeded, and six genuinely different
-- temperature ranges. The offshore region reads slightly above its seeded mean
-- because of the open-water gustiness bonus in step 06:
--
--       region_name        | seeded_wind | measured_wind | seeded_temp | measured_temp | coldest | hottest
--  ------------------------+-------------+---------------+-------------+---------------+---------+---------
--   North Sea              |         9.5 |          9.91 |        10.5 |          10.5 |     2.5 |    18.6
--   Southern Great Plains  |           7 |          6.97 |          15 |          15.0 |    -0.9 |    35.0
--   Iberian Meseta         |         6.8 |          6.79 |          14 |          14.0 |    -4.2 |    31.6
--   North German Plain     |         6.6 |          6.59 |         9.5 |           9.5 |    -6.5 |    23.9
--   Inner Mongolian Plateau|         6.4 |          6.43 |           6 |           6.0 |   -22.0 |    31.4
--   Deccan Plateau         |         5.2 |          5.34 |          26 |          26.0 |    14.6 |    36.5


-- ============================================================================
-- ## Filling them: one call each, and let TimescaleDB batch it
-- ============================================================================
--
-- Every aggregate above was created WITH NO DATA, so nothing is materialised yet.
-- One call per aggregate over the whole history is all this needs:
--
--   CALL refresh_continuous_aggregate('cagg_wind_hourly', <from>, <to>);
--
-- That is a recent luxury, and the history is worth knowing because the obvious
-- shapes used to fail hard. On TimescaleDB before 2.28 a single refresh over two
-- years of data was ONE operation over the whole range, and on 6.8 million source
-- rows it wanted more memory than a 7.7 GB machine had:
--
--   LOG:  server process (PID 191) was terminated by signal 9: Killed
--   DETAIL: Failed process was running:
--           CALL refresh_continuous_aggregate('cagg_wind_hourly', NULL, NULL);
--
-- Signal 9 is the OOM killer, not a TimescaleDB fault — and note the blast radius:
-- the whole instance restarts and every other connection is dropped into recovery.
-- Windowing the refresh a month at a time fixed the peak, but memory also
-- accumulated ACROSS calls in one session, so the monthly version died too, on the
-- 24th of 25 calls for the first aggregate. That needed a `\c` reconnect between
-- aggregates to release what the previous backend had accumulated.
--
-- SINCE 2.28.0 NONE OF THAT SCAFFOLDING IS NEEDED, because the engine now does the
-- windowing itself. One `CALL refresh_continuous_aggregate(...)` no longer means one
-- giant operation: it is INCREMENTAL by default, and three defaults describe it.
--
--   buckets_per_batch        10      batch size, in BUCKETS — not chunks, not rows.
--                                    The batch's time range is bucket width x this,
--                                    so 10 hours for an hourly aggregate and 10 days
--                                    for a daily one. Each batch is a separate
--                                    refresh over its own slice of the range.
--   refresh_newest_first     true    batches run from the newest slice backwards, so
--                                    dashboards light up with recent data first.
--   max_batches_per_execution 0      no cap; keep going until the range is done.
--
-- The batches are SEQUENTIAL, not parallel — one call is still one backend doing one
-- thing at a time. What each batch gets is its OWN TRANSACTION, and that is the whole
-- benefit: locks are released between batches, memory is reclaimed between batches,
-- and each batch's rows become visible as it commits. That is exactly the bound the
-- hand-written monthly windowing above was buying, minus the hand-writing.
--
-- You can watch it happen. Count committed transactions across one refresh:
--
--   SELECT xact_commit FROM pg_stat_database WHERE datname = current_database();
--   CALL refresh_continuous_aggregate('cagg_wind_hourly', NULL, NULL);
--   SELECT xact_commit FROM pg_stat_database WHERE datname = current_database();
--
-- The counter moves by hundreds. Now set `options => '{"buckets_per_batch": 0}'` and
-- it moves by one — that is the pre-2.28 single-transaction behaviour, and it is how
-- you would reproduce the OOM above on purpose.
--
-- Measured on this workshop at the volume that used to die (12 plants x 8 turbines
-- x 730 days = 6.73M rows per hypertable, 8 GiB / 4 CPU), all eight aggregates
-- force-refreshed:
--
--   monthly windows + reconnect per aggregate   37 s   2.25 GiB peak
--   one call per aggregate, fresh connection     30 s   2.24 GiB peak
--   one call per aggregate, ONE session          33 s   2.27 GiB peak
--
-- Same memory to within noise, no OOM in any variant, and the simple version is the
-- fastest. So the file just calls each aggregate once, below.
--
-- A GUC WORTH KNOWING ABOUT, AND WHY IT DOES NOTHING HERE. The docs offer
-- `timescaledb.enable_merge_on_cagg_refresh` (2.17+, PG15+, off by default), which
-- makes a refresh MERGE into the materialization instead of deleting the old rows and
-- re-inserting. Measured on a 115k-row source, refreshing a range that was already
-- materialised: 8462 kB of WAL with it off, 454 kB with it on — 18x less. Real, and
-- irrelevant to this file twice over:
--
--   * It only applies to aggregates WITHOUT columnstore enabled, and step 09 enables
--     columnstore on all eight. Measured on a columnstore-enabled aggregate: 8447 kB
--     off vs 8511 kB on. No effect, no warning, no error — it is silently ignored.
--     The gate is `compression_enabled` on the AGGREGATE, not whether the chunk being
--     written is actually compressed yet.
--   * Even before step 09 runs, the fill below is COLD — nothing is materialised, so
--     there is nothing to delete-and-reinsert and nothing for MERGE to improve on.
--     Measured cold: 7227 kB either way.
--
-- Where it would pay is a repeatedly-refreshed rowstore-only aggregate over a wide
-- `start_offset`. That is a real shape; it just is not this one.
--
-- Careful with `psql -c`: `psql -c "SET ...; CALL refresh..."` puts both statements in
-- a single implicit transaction, and refresh_continuous_aggregate cannot run inside
-- one — every refresh fails. Use PGOPTIONS for the setting, or a separate invocation.
-- Same reason these are eight top-level statements rather than a loop: the call
-- manages its own transactions, so it cannot live in a DO block or a procedure.
-- Attempting it raises "cannot run inside a transaction block", and forcing the issue
-- with nested procedure calls crashed the backend outright while this file was
-- being written.
--
-- ORDER MATTERS, and it is a correctness constraint rather than a tuning choice.
-- These aggregates form a chain:
--
--   power_generation  -> turbine_hourly -> plant_hourly -> regional_hourly -> regional_daily
--                                       \-> turbine_daily  \-> plant_daily
--   wind_measurements -> wind_hourly    -> wind_daily
--
-- A hierarchical aggregate reads its parent, so refreshing a child first materialises
-- a rollup of data that is not there yet — and it does so SILENTLY, leaving an empty
-- child rather than raising. The order below is that order. Do not sort these names
-- alphabetically: cagg_plant_power_daily sorts before cagg_plant_power_hourly, which
-- is exactly backwards.
--
-- THE UPPER BOUND IS A DELIBERATE CHOICE, not just tidiness. Refreshing to an instant
-- INSIDE an open bucket materialises that whole bucket and moves the aggregate's
-- watermark to the bucket's END — leaving the watermark ahead of the wall clock. Since
-- real-time aggregation only unions raw rows ABOVE the watermark, every row that lands
-- in that bucket afterwards becomes invisible: not materialised, and not unioned. Even
-- `force => true` will not recover it, because a refresh's upper bound snaps DOWN to a
-- bucket boundary and so never revisits the offending bucket. Step 12 hit exactly this.
--
-- Ending on an hour boundary keeps the watermark BEHIND now(), so the current partial
-- bucket stays unmaterialised and real-time aggregation serves it live — which is what
-- you want during a workshop that keeps writing. \gset puts the window in two psql
-- variables so each CALL below stays a plain, readable statement.
SELECT (date_trunc('hour', now()) - make_interval(days => cfg_int('backfill_days')))::text AS fill_from,
       date_trunc('hour', now())::text AS fill_to
\gset

\echo '--- filling eight aggregates, one call each, parents before children ---'

-- Level 1 — read the raw hypertables.
CALL refresh_continuous_aggregate('cagg_turbine_power_hourly',  :'fill_from', :'fill_to');
CALL refresh_continuous_aggregate('cagg_wind_hourly',           :'fill_from', :'fill_to');

-- Level 2 — read cagg_turbine_power_hourly / cagg_wind_hourly.
CALL refresh_continuous_aggregate('cagg_turbine_power_daily',   :'fill_from', :'fill_to');
CALL refresh_continuous_aggregate('cagg_plant_power_hourly',    :'fill_from', :'fill_to');
CALL refresh_continuous_aggregate('cagg_wind_daily',            :'fill_from', :'fill_to');

-- Level 3 — read cagg_plant_power_hourly.
CALL refresh_continuous_aggregate('cagg_plant_power_daily',     :'fill_from', :'fill_to');
CALL refresh_continuous_aggregate('cagg_regional_power_hourly', :'fill_from', :'fill_to');

-- Level 4 — reads cagg_regional_power_hourly.
CALL refresh_continuous_aggregate('cagg_regional_power_daily',  :'fill_from', :'fill_to');


-- ============================================================================
-- ## Register the refresh policies
-- ============================================================================
--
-- Registered HERE, after the fill, and the ordering is not cosmetic.
--
-- add_continuous_aggregate_policy() hands a background worker a job it may start
-- within seconds, and that worker refreshes the same aggregate the fill above is
-- still working through. The two collide:
--
--   ERROR:  could not refresh continuous aggregate "cagg_plant_power_hourly"
--           due to a concurrent refresh
--   DETAIL: A concurrent refresh on window
--           [2026-07-31 00:00:00+00, 2026-07-31 10:00:00+00) is already in progress.
--
-- It shows up most reliably on SMALL fleets, which is counter-intuitive until you
-- see why: a one-turbine fill finishes so fast that it is still running when the
-- scheduler first fires, whereas a 48-turbine fill has usually moved past the
-- window the policy wants. A race you only hit on small inputs is exactly the kind
-- that survives testing.
--
-- Fill first, then hand the aggregate to its policy. Step 09 registers the
-- COLUMNSTORE policies the same way, for the same reason.
--
-- The offsets are the part worth understanding:
--
--   start_offset   how far back each run looks for invalidated buckets. Must cover
--                  the window in which data can still arrive or be corrected.
--                  Keep it SHORTER than any retention policy on the source —
--                  refreshing a bucket whose raw rows were already dropped
--                  rewrites it as EMPTY, silently destroying rolled-up history.
--
--   end_offset     leave the current bucket alone. It is incomplete and still
--                  receiving writes, so its aggregate would be stale within
--                  seconds. Real-time aggregation covers it instead — that
--                  division of labour is what these two settings are for.
--
-- The daily aggregates use a wider start_offset (10 days) and a slower schedule
-- than the hourly ones, because a day-grain bucket is not worth revisiting every
-- half hour.

SELECT add_continuous_aggregate_policy('cagg_turbine_power_hourly',
  start_offset      => INTERVAL '7 days',
  end_offset        => INTERVAL '1 hour',
  schedule_interval => INTERVAL '30 minutes');

SELECT add_continuous_aggregate_policy('cagg_turbine_power_daily',
  start_offset      => INTERVAL '10 days',
  end_offset        => INTERVAL '1 day',
  schedule_interval => INTERVAL '1 hour');

SELECT add_continuous_aggregate_policy('cagg_plant_power_hourly',
  start_offset      => INTERVAL '7 days',
  end_offset        => INTERVAL '1 hour',
  schedule_interval => INTERVAL '30 minutes');

SELECT add_continuous_aggregate_policy('cagg_regional_power_hourly',
  start_offset      => INTERVAL '7 days',
  end_offset        => INTERVAL '1 hour',
  schedule_interval => INTERVAL '30 minutes');

SELECT add_continuous_aggregate_policy('cagg_plant_power_daily',
  start_offset      => INTERVAL '10 days',
  end_offset        => INTERVAL '1 day',
  schedule_interval => INTERVAL '1 hour');

SELECT add_continuous_aggregate_policy('cagg_regional_power_daily',
  start_offset      => INTERVAL '10 days',
  end_offset        => INTERVAL '1 day',
  schedule_interval => INTERVAL '1 hour');

SELECT add_continuous_aggregate_policy('cagg_wind_hourly',
  start_offset      => INTERVAL '7 days',
  end_offset        => INTERVAL '1 hour',
  schedule_interval => INTERVAL '30 minutes');

SELECT add_continuous_aggregate_policy('cagg_wind_daily',
  start_offset      => INTERVAL '10 days',
  end_offset        => INTERVAL '1 day',
  schedule_interval => INTERVAL '1 hour');

-- Verify all six are registered. Note the join column: for a REFRESH policy,
-- jobs.hypertable_name is the USER-FACING VIEW NAME — the opposite of a
-- compression policy on an aggregate, where it is the materialization hypertable.
SELECT ca.view_name,
       j.config ->> 'start_offset' AS start_offset,
       j.config ->> 'end_offset'   AS end_offset,
       j.schedule_interval
  FROM timescaledb_information.continuous_aggregates ca
  LEFT JOIN timescaledb_information.jobs j
         ON j.proc_name        = 'policy_refresh_continuous_aggregate'
        AND j.hypertable_schema = ca.view_schema
        AND j.hypertable_name   = ca.view_name
 ORDER BY ca.view_name;

-- Expected: six rows, none with a NULL start_offset.


-- ============================================================================
-- ## Stand the refresh policies down until this workshop stops writing
-- ============================================================================
--
-- Registered and correct — and now paused until step 13, exactly as step 09 does
-- with the columnstore policies.
--
-- The reason is the same collision in a different guise. Steps 10 and 12 call
-- refresh_continuous_aggregate() explicitly, and a policy refresh running at the
-- same moment on the same aggregate is refused outright:
--
--   ERROR:  could not refresh continuous aggregate "cagg_regional_power_hourly"
--           due to a concurrent refresh
--
-- Nothing goes stale in the meantime. Every aggregate here has
-- materialized_only = false, so real-time aggregation blends materialized buckets
-- with live raw rows and queries stay correct whether a policy has run or not. The
-- policies exist to move that work off the query path, which only matters once the
-- workshop stops bulk-loading.

SELECT ca.view_name,
       alter_job(j.job_id, scheduled => false) IS NOT NULL AS paused
  FROM timescaledb_information.continuous_aggregates ca
  JOIN timescaledb_information.jobs j
    ON j.proc_name         = 'policy_refresh_continuous_aggregate'
   AND j.hypertable_schema = ca.view_schema
   AND j.hypertable_name   = ca.view_name
 ORDER BY ca.view_name;


-- ============================================================================
-- ## Capacity factor: the one thing the chain cannot carry
-- ============================================================================
-- Capacity factor is output divided by RATED capacity, and rated capacity lives on
-- `plants` — a plain table an aggregate must not join. So the aggregates store
-- power, and capacity factor is divided out at read time by these thin views.
--
-- That split is the right one. Rated capacity is dimension data: it changes when a
-- machine is repowered, and if it were baked into a materialized aggregate the
-- historical rows would keep the old denominator with no way to notice. Dividing at
-- read time means a corrected nameplate immediately fixes every figure, past
-- included.
--
-- These three views are what the dashboard actually queries — one per drill-down
-- tier.

CREATE OR REPLACE VIEW v_region_hourly AS
SELECT c.bucket,
       c.region_name,
       c.plants_reporting,
       c.turbines_reporting,
       c.region_power_kw,
       r.rated_kw                                        AS region_rated_kw,
       100.0 * c.region_power_kw / NULLIF(r.rated_kw, 0)  AS capacity_factor_pct,
       c.region_expected_power_kw,
       -- PERFORMANCE RATIO: actual over what the measured wind should have
       -- produced. 100% = every machine healthy. This is the number that finds
       -- degradation, and capacity factor cannot substitute for it — a low CF in
       -- light wind is fine, a low performance ratio never is.
       100.0 * c.region_power_kw / NULLIF(c.region_expected_power_kw, 0)
                                                          AS performance_ratio_pct,
       c.region_expected_power_kw - c.region_power_kw      AS lost_kw,
       c.avg_wake_loss_pct,
       c.avg_wind_ms,
       c.max_wind_ms
  FROM cagg_regional_power_hourly c
  JOIN (
    SELECT region_name, SUM(turbine_count * rated_capacity_kw) AS rated_kw
      FROM plants GROUP BY region_name
  ) r USING (region_name);

CREATE OR REPLACE VIEW v_plant_hourly AS
SELECT c.bucket,
       c.plant_id,
       p.plant_name,
       p.site_name,
       c.region_name,
       p.operator,
       p.model,
       c.turbines_reporting,
       c.plant_power_kw,
       p.turbine_count * p.rated_capacity_kw             AS plant_rated_kw,
       100.0 * c.plant_power_kw
             / NULLIF(p.turbine_count * p.rated_capacity_kw, 0) AS capacity_factor_pct,
       c.plant_expected_power_kw,
       100.0 * c.plant_power_kw / NULLIF(c.plant_expected_power_kw, 0)
                                                          AS performance_ratio_pct,
       c.plant_expected_power_kw - c.plant_power_kw        AS lost_kw,
       c.avg_wake_loss_pct,
       c.avg_wind_ms,
       c.max_wind_ms
  FROM cagg_plant_power_hourly c
  JOIN plants p USING (plant_id);

CREATE OR REPLACE VIEW v_turbine_hourly AS
SELECT c.bucket,
       c.turbine_id,
       t.name AS turbine_name,
       t.grid_row,
       t.grid_col,
       c.plant_id,
       p.plant_name,
       c.region_name,
       c.avg_power_kw,
       c.avg_expected_power_kw,
       p.rated_capacity_kw,
       100.0 * c.avg_power_kw / NULLIF(p.rated_capacity_kw, 0) AS capacity_factor_pct,
       100.0 * c.avg_power_kw / NULLIF(c.avg_expected_power_kw, 0)
                                                          AS performance_ratio_pct,
       c.avg_expected_power_kw - c.avg_power_kw            AS lost_kw,
       c.avg_wake_loss_pct,
       c.avg_wind_ms
  FROM cagg_turbine_power_hourly c
  JOIN turbines t USING (turbine_id)
  JOIN plants   p ON p.plant_id = c.plant_id;


-- ============================================================================
-- ## Verify: the chain is wired as intended
-- ============================================================================

SELECT ca.view_name,
       ca.materialized_only,
       CASE WHEN ca.view_definition LIKE '%power_generation%'
              THEN 'power_generation (raw)'
            WHEN ca.view_definition LIKE '%cagg_plant_power_hourly%'
              THEN 'cagg_plant_power_hourly'
            WHEN ca.view_definition LIKE '%cagg_turbine_power_hourly%'
              THEN 'cagg_turbine_power_hourly'
       END                           AS reads_from,
       (j.config ->> 'start_offset') AS refresh_start_offset
  FROM timescaledb_information.continuous_aggregates ca
  LEFT JOIN timescaledb_information.jobs j
         ON j.proc_name         = 'policy_refresh_continuous_aggregate'
        AND j.hypertable_schema = ca.view_schema
        AND j.hypertable_name   = ca.view_name
 WHERE ca.view_name LIKE 'cagg_%power%'
 ORDER BY ca.view_name;

--          view_name          | materialized_only |        reads_from         | refresh_start_offset
-- ---------------------------+-------------------+---------------------------+----------------------
--  cagg_plant_power_hourly    | f                 | cagg_turbine_power_hourly | 7 days
--  cagg_regional_power_hourly | f                 | cagg_plant_power_hourly   | 7 days
--  cagg_turbine_power_daily   | f                 | cagg_turbine_power_hourly | 10 days
--  cagg_turbine_power_hourly  | f                 | power_generation (raw)    | 7 days
-- (4 rows)
--
-- materialized_only = f on ALL FOUR. In a hierarchy this matters more than usual:
-- one `true` anywhere in the chain stops real-time aggregation recursing past it,
-- and every level above silently goes stale between refreshes.

-- Every aggregate must have a refresh policy. Note the join key: for a refresh
-- policy jobs.hypertable_name holds the USER-FACING VIEW NAME, not the internal
-- materialization hypertable. Joining on materialization_hypertable_name looks
-- more correct and reports every aggregate as unpolicied.
SELECT ca.view_name AS aggregate_without_refresh_policy
  FROM timescaledb_information.continuous_aggregates ca
 WHERE NOT EXISTS (
         SELECT 1 FROM timescaledb_information.jobs j
          WHERE j.proc_name         = 'policy_refresh_continuous_aggregate'
            AND j.hypertable_schema = ca.view_schema
            AND j.hypertable_name   = ca.view_name);

-- Expected: (0 rows)


-- ============================================================================
-- ## Verify: every level agrees with the raw data
-- ============================================================================
-- A rollup chain is only worth having if it is arithmetically sound. Mean turbine
-- output computed at each level must match the raw table.

WITH raw AS (
  SELECT AVG(power_kw) AS avg_kw FROM power_generation
),
turb AS (
  SELECT SUM(avg_power_kw * readings) / SUM(readings) AS avg_kw
    FROM cagg_turbine_power_hourly
),
plant AS (
  SELECT SUM(avg_turbine_power_kw * readings) / SUM(readings) AS avg_kw
    FROM cagg_plant_power_hourly
),
region AS (
  SELECT SUM(avg_turbine_power_kw * readings) / SUM(readings) AS avg_kw
    FROM cagg_regional_power_hourly
)
SELECT ROUND(raw.avg_kw::numeric, 3)    AS raw_avg_turbine_kw,
       ROUND(turb.avg_kw::numeric, 3)   AS from_turbine_cagg,
       ROUND(plant.avg_kw::numeric, 3)  AS from_plant_cagg,
       ROUND(region.avg_kw::numeric, 3) AS from_region_cagg,
       ABS(raw.avg_kw - turb.avg_kw)   < 0.01 AS turbine_agrees,
       ABS(raw.avg_kw - plant.avg_kw)  < 0.01 AS plant_agrees,
       ABS(raw.avg_kw - region.avg_kw) < 0.01 AS region_agrees
  FROM raw, turb, plant, region;

-- All three *_agrees columns must be true. A false one means a weighted average
-- somewhere in the chain lost its weight.

-- And the property that SUM(power_kw) would have destroyed: plant output summed
-- across a region must equal the region figure computed directly.
SELECT p.bucket,
       p.region_name,
       ROUND(SUM(p.plant_power_kw)::numeric, 2)  AS summed_from_plants,
       ROUND(MAX(r.region_power_kw)::numeric, 2) AS from_region_cagg,
       ABS(SUM(p.plant_power_kw) - MAX(r.region_power_kw)) < 0.01 AS agrees
  FROM cagg_plant_power_hourly p
  JOIN cagg_regional_power_hourly r
    ON r.bucket = p.bucket AND r.region_name = p.region_name
 GROUP BY p.bucket, p.region_name
 ORDER BY p.bucket DESC
 LIMIT 3;


-- ============================================================================
-- ## Try it: the three dashboard tiers
-- ============================================================================
-- Tier 1 — FLEET OVERVIEW. Six rows an hour, whatever the fleet size.

SELECT bucket,
       region_name,
       ROUND((region_power_kw / 1000)::numeric, 2) AS output_mw,
       ROUND(capacity_factor_pct::numeric, 1)      AS cf_pct,
       ROUND(avg_wake_loss_pct::numeric, 1)        AS wake_pct,
       plants_reporting,
       turbines_reporting
  FROM v_region_hourly
 WHERE bucket >= now() - INTERVAL '4 hours'
 ORDER BY bucket DESC, region_name
 LIMIT 12;

-- Tier 2 — DRILL INTO A REGION. Plants within it, same shape of query.

SELECT bucket,
       plant_name,
       site_name,
       ROUND((plant_power_kw / 1000)::numeric, 2) AS output_mw,
       ROUND(capacity_factor_pct::numeric, 1)     AS cf_pct,
       ROUND(avg_wake_loss_pct::numeric, 1)       AS wake_pct
  FROM v_plant_hourly
 WHERE region_name = 'North Sea'
   AND bucket >= now() - INTERVAL '4 hours'
 ORDER BY bucket DESC, plant_name
 LIMIT 12;

-- Tier 3 — DRILL INTO A PLANT. Individual turbines with grid position, which is
-- where wake losses become legible.

SELECT bucket,
       turbine_name,
       grid_row,
       grid_col,
       ROUND(avg_power_kw::numeric, 0)        AS power_kw,
       ROUND(capacity_factor_pct::numeric, 1) AS cf_pct,
       ROUND(avg_wake_loss_pct::numeric, 1)   AS wake_pct
  FROM v_turbine_hourly
 WHERE plant_name = (SELECT plant_name FROM plants
                      WHERE region_name = 'North Sea' ORDER BY plant_name LIMIT 1)
   AND bucket >= now() - INTERVAL '1 hour'
 ORDER BY bucket DESC, grid_row, grid_col;
