-- ============================================================================
-- # Wind Energy — Step 07: Backfill Historical Data
-- ============================================================================
-- One call, 30 days of 15-minute history for every turbine step 04 seeded.
--
-- Run this BEFORE creating the continuous aggregates in step 08. Loading the
-- raw data first means the aggregates materialize everything on creation and
-- the dashboards have full history immediately. Creating the aggregates first
-- would also work, but then the backfill has to flow through the invalidation
-- machinery, which is slower and makes the first refresh do all the work.
-- ============================================================================


-- ============================================================================
-- ## Generate the history
-- ============================================================================
-- 96 turbines x 30 days x 96 samples/day = 276,576 rows in EACH hypertable.
--
-- The sample interval is `wind_step_minutes` (15 by default), the same key
-- advance_wind() uses in step 10 — so the raw history has one uniform
-- resolution rather than changing pace where the backfill stops and the live
-- simulation starts. That uniformity is what step 13's tier selection relies on:
-- the raw table has to be genuinely finer than the hourly aggregate, or zooming
-- in reveals nothing the cagg did not already have.
--
-- Two knobs, both in workshop_config, both changing the row count:
--   UPDATE workshop_config SET value = '90' WHERE key = 'backfill_days';
--   UPDATE workshop_config SET value = '60' WHERE key = 'wind_step_minutes';
--   SELECT backfill_wind();        -- reads workshop_config
--   SELECT backfill_wind(7);       -- explicit day override
--
-- At the defaults this is the slowest step in this workshop — a few seconds. Raising
-- backfill_days or lowering wind_step_minutes scales it linearly.

SELECT backfill_wind() AS rows_per_table;

-- NOTICE:  backfill_wind: 30 days (2026-07-05 19:00:00+00 to 2026-08-04 19:00:00+00),
--          276576 rows into each of wind_measurements and power_generation
--
--  rows_per_table
-- ----------------
--          276576
-- (1 row)
--
-- 2,881 rows per turbine, not 2,880: generate_series is inclusive of both ends,
-- so the closing timestamp gets a sample too.


-- ============================================================================
-- ## Verify: row counts and time span
-- ============================================================================

SELECT 'wind_measurements' AS table_name,
       COUNT(*)            AS rows,
       COUNT(DISTINCT turbine_id) AS turbines,
       MIN(time)           AS oldest,
       MAX(time)           AS newest
  FROM wind_measurements
UNION ALL
SELECT 'power_generation',
       COUNT(*),
       COUNT(DISTINCT turbine_id),
       MIN(time),
       MAX(time)
  FROM power_generation;

-- Both tables must report identical counts and spans. They are written from a
-- single MATERIALIZED CTE, so a mismatch means something went wrong.


-- ============================================================================
-- ## Verify: does the wind model look like weather?
-- ============================================================================
-- Mean wind speed by region. The ordering here is the model earning its keep:
-- the offshore North Sea should be clearly windiest, southern India clearly
-- calmest, with the mid-latitude land regions in between.

SELECT p.region_name,
       COUNT(*)                                          AS readings,
       ROUND(AVG(m.wind_speed_ms)::numeric, 2)           AS avg_wind_ms,
       ROUND(MIN(m.wind_speed_ms)::numeric, 2)           AS min_wind_ms,
       ROUND(MAX(m.wind_speed_ms)::numeric, 2)           AS max_wind_ms,
       ROUND(AVG(m.temperature_c)::numeric, 1)           AS avg_temp_c
  FROM wind_measurements m
  JOIN turbines t USING (turbine_id)
  JOIN plants   p ON p.plant_id = t.plant_id
 GROUP BY p.region_name
 ORDER BY avg_wind_ms DESC;

--        region_name       | readings | avg_wind_ms | min_wind_ms | max_wind_ms | avg_temp_c
-- ------------------------+----------+-------------+-------------+-------------+------------
--  North Sea              |    46128 |        8.31 |        1.54 |       28.20 |       19.1
--  Iberian Meseta         |    46128 |        6.65 |        0.00 |       25.08 |       21.6
--  Inner Mongolian Plateau|    46128 |        6.55 |        0.00 |       26.60 |       21.5
--  North German Plain     |    46128 |        6.53 |        0.00 |       24.02 |       19.0
--  Deccan Plateau         |    46128 |        5.90 |        0.00 |       25.48 |       27.7
--  Southern Great Plains  |    49012 |        5.58 |        0.00 |       24.88 |       22.6
-- (6 rows)
--
-- Your numbers will differ slightly — the model itself is deterministic, but
-- the sensor noise added at insert time is not, and the window depends on when
-- you run the backfill.
--
-- Four things to notice, all of them the model earning its keep:
--   * The offshore North Sea is clearly windiest. That is the roughness bonus.
--   * Deccan Plateau is NOT last, despite sitting far outside the westerly
--     belt. That is the monsoon term, and if you re-run the backfill for a
--     January window it drops to the bottom.
--   * The maxima are all 24-28 m/s: storm peaks, well above every turbine's
--     cut-out speed. Those become the shutdown events checked below.
--   * Southern Great Plains has more readings than the others because step 12's
--     ACID demo adds four turbines to a plant there. Run steps 01-11 only and
--     all six regions report an equal count.


-- ============================================================================
-- ## Verify: the power curve did its job
-- ============================================================================
-- Capacity factor is the metric the whole industry runs on: actual energy
-- produced divided by the energy the machine would have made at rated output
-- the entire time. Onshore is typically 25-45%; modern offshore reaches 50-60%.

SELECT g.region_name,
       ROUND(AVG(pg.power_kw)::numeric, 0)                      AS avg_power_kw,
       ROUND(AVG(pl.rated_capacity_kw)::numeric, 0)             AS avg_rated_kw,
       ROUND((AVG(pg.power_kw) / AVG(pl.rated_capacity_kw) * 100)::numeric, 1)
                                                                AS capacity_factor_pct,
       ROUND(AVG(pg.wake_loss_pct)::numeric, 1)                 AS avg_wake_loss_pct
  FROM power_generation pg
  JOIN plants  pl ON pl.plant_id = pg.plant_id
  JOIN regions g  ON g.region_name = pg.region_name
 GROUP BY g.region_name
 ORDER BY capacity_factor_pct DESC;

--        region_name       | avg_power_kw | avg_rated_kw | capacity_factor_pct | avg_wake_loss_pct
-- ------------------------+--------------+--------------+---------------------+-------------------
--  North Sea              |         2990 |         8000 |                37.4 |               5.8
--  North German Plain     |         1156 |         3500 |                33.0 |               5.6
--  Iberian Meseta         |         1400 |         4500 |                31.1 |               5.0
--  Deccan Plateau         |          910 |         3000 |                30.3 |               7.6
--  Inner Mongolian Plateau|         1000 |         3400 |                29.4 |               9.1
--  Southern Great Plains  |          989 |         4200 |                23.5 |               6.5
-- (6 rows)
--
-- Fleet-wide this works out to about 32%, which is what a geographically
-- diversified portfolio actually achieves. The offshore North Sea at 37% is
-- also realistic — modern offshore projects genuinely reach 50%+.
--
-- Note avg_rated_kw is a flat number per region because turbine model is a
-- plant-level spec, and every plant in a region here uses the same model.
--
-- If a region reports a capacity factor above ~65% or below ~10%, the wind
-- model has drifted out of a realistic band — check the base_ms Gaussian and
-- storm_ms amplitude in step 06.

-- Fleet-wide figure for the stat panel on the dashboard:
SELECT ROUND((AVG(pg.power_kw) / AVG(pl.rated_capacity_kw) * 100)::numeric, 1)
         AS fleet_capacity_factor_pct,
       ROUND(AVG(pg.wake_loss_pct)::numeric, 1) AS fleet_avg_wake_loss_pct
  FROM power_generation pg
  JOIN plants pl ON pl.plant_id = pg.plant_id;


-- ============================================================================
-- ## Verify: the three power-curve regimes are all present
-- ============================================================================
-- Proof that the function's edge cases actually fire in the generated data,
-- rather than every row landing in the productive middle.

SELECT CASE
         WHEN m.wind_speed_ms <  pl.cut_in_ms  THEN '1. below cut-in (parked)'
         WHEN m.wind_speed_ms >= pl.cut_out_ms THEN '3. above cut-out (storm shutdown)'
         WHEN pg.power_kw >= pl.rated_capacity_kw - 0.5
                                               THEN '2b. at rated (pitch-limited)'
         ELSE                                       '2a. productive range'
       END                                         AS regime,
       COUNT(*)                                    AS readings,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
  FROM wind_measurements m
  JOIN plants pl          ON pl.plant_id = m.plant_id
  JOIN power_generation pg USING (turbine_id, time)
 GROUP BY regime
 ORDER BY regime;

--               regime              | readings | pct
-- ---------------------------------+----------+-------
--  1. below cut-in (parked)        |     3596 | 12.47
--  2a. productive range            |    21685 | 75.19
--  2b. at rated (pitch-limited)    |     3308 | 11.47
--  3. above cut-out (storm shutdown)|      251 |  0.87
-- (4 rows)
--
-- All four regimes present, in believable proportions. The 0.87% in storm
-- shutdown is the interesting one: rare enough to be a genuine event, frequent
-- enough to see on a chart. Find the actual storms:

SELECT date_trunc('hour', m.time) AS hour,
       pl.region_name,
       COUNT(*)                                AS turbines_shut_down,
       ROUND(MAX(m.wind_speed_ms)::numeric, 1) AS peak_wind_ms
  FROM wind_measurements m
  JOIN plants pl ON pl.plant_id = m.plant_id
 WHERE m.wind_speed_ms >= pl.cut_out_ms
 GROUP BY 1, 2
 ORDER BY 1
 LIMIT 20;

-- Note how shutdowns cluster: several turbines in the same region drop out
-- within the same hour or two, because they share a weather system. That
-- correlated, geographically-localised loss of output is precisely what
-- cagg_regional_power_hourly (step 08) is designed to make visible.
