-- ============================================================================
-- Migration: add the plant- and region-grain DAILY aggregates
-- ============================================================================
-- For a database built before these two existed. The dashboards' zoom-selected
-- timelines reference them, so without them the coarse-zoom branch of every
-- region and plant timeline errors with:
--
--   ERROR:  relation "cagg_regional_power_daily" does not exist
--
-- Purely ADDITIVE: nothing existing is dropped or rewritten. Both roll up from
-- their hourly parents, which are already materialised, so the fill reads a few
-- million pre-aggregated rows rather than the raw hypertable.
--
-- Definitions are lifted verbatim from 08_continuous_aggregates.sql. If you would
-- rather guarantee consistency with that file in full, re-run step 08 instead —
-- it is idempotent, but it drops and refills all eight aggregates.
--
-- IF NOT EXISTS is honoured for continuous aggregates (it prints
-- `continuous aggregate "..." already exists, skipping`), so this whole file is safe
-- to re-run: on a database that already has both, every statement below either skips
-- or reports itself already up to date.
CREATE MATERIALIZED VIEW IF NOT EXISTS cagg_plant_power_daily
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

CREATE MATERIALIZED VIEW IF NOT EXISTS cagg_regional_power_daily
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
-- Columnstore settings, matching step 09.
ALTER MATERIALIZED VIEW cagg_plant_power_daily
  SET (timescaledb.enable_columnstore = true,
       timescaledb.segmentby = 'plant_id',
       timescaledb.orderby   = 'day DESC');

ALTER MATERIALIZED VIEW cagg_regional_power_daily
  SET (timescaledb.enable_columnstore = true,
       timescaledb.segmentby = 'region_name',
       timescaledb.orderby   = 'day DESC');

-- ============================================================================
-- Fill them, then hand them to policies
-- ============================================================================
-- refresh_continuous_aggregate cannot run inside a transaction block, so these are
-- top-level statements rather than a loop in a DO block.
--
-- No manual windowing: since TimescaleDB 2.28.0 the call batches incrementally by
-- itself — `buckets_per_batch` defaults to 10 buckets, so 10 days for these daily
-- aggregates, and each batch commits separately. That is what used to require
-- refreshing a month at a time to avoid an OOM kill on a full-history refresh.
--
-- These two roll up from already-materialised hourly parents, so this is fast either
-- way: a few thousand output rows from a few million pre-aggregated ones.

SELECT (date_trunc('hour', now()) - make_interval(days => cfg_int('backfill_days')))::text AS fill_from,
       date_trunc('hour', now())::text AS fill_to
\gset

CALL refresh_continuous_aggregate('cagg_plant_power_daily',    :'fill_from', :'fill_to');
CALL refresh_continuous_aggregate('cagg_regional_power_daily', :'fill_from', :'fill_to');

SELECT add_continuous_aggregate_policy('cagg_plant_power_daily',
  start_offset => INTERVAL '10 days', end_offset => INTERVAL '1 day',
  schedule_interval => INTERVAL '1 hour', if_not_exists => true);

SELECT add_continuous_aggregate_policy('cagg_regional_power_daily',
  start_offset => INTERVAL '10 days', end_offset => INTERVAL '1 day',
  schedule_interval => INTERVAL '1 hour', if_not_exists => true);

-- Verify: eight aggregates, and the two new ones populated.
SELECT view_name,
       (SELECT COUNT(*) FROM timescaledb_information.jobs j
         WHERE j.proc_name = 'policy_refresh_continuous_aggregate'
           AND j.hypertable_name = ca.view_name) AS refresh_policies
  FROM timescaledb_information.continuous_aggregates ca
 ORDER BY view_name;
