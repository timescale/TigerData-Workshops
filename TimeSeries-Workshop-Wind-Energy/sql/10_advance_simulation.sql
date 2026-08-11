-- ============================================================================
-- # Wind Energy — Step 10: Advance the Simulation
-- ============================================================================
-- THIS IS THE FILE YOU RE-RUN.
--
-- Every other file in this workshop runs once. This one you run as often as you like,
-- and each time it appends whatever data "arrived" since the last run, then
-- refreshes the aggregates so the dashboards move.
--
-- Why a script you run rather than a scheduled job? Three reasons:
--
--   * Instructor-paced. Data appears when you want to talk about it, not on
--     someone else's timer.
--
--   * Nothing is hidden. The whole data path is three statements you can read.
--     A background job that silently fills tables is harder to reason about
--     when something looks wrong.
--
--   * It works everywhere. pg_cron is listed for Tiger Cloud but requires
--     contacting support to enable, so it cannot be a prerequisite for a
--     workshop where attendees provision their own service minutes before
--     starting. The README shows how to wire this up with pg_cron or with
--     TimescaleDB's add_job() once you are past the workshop.
-- ============================================================================


-- ============================================================================
-- ## Before
-- ============================================================================

SELECT COUNT(*) AS rows_before,
       MAX(time) AS newest_before
  FROM wind_measurements;


-- ============================================================================
-- ## Generate the next slice
-- ============================================================================
-- advance_wind() resumes from MAX(time) in wind_measurements and generates
-- 15-minute steps up to now(). That derivation is what makes this safe to
-- re-run: the window it generates cannot overlap data that already exists, so
-- there is no duplicate to guard against in the first place.
--
-- Run it twice back-to-back and the second call reports "already current" and
-- inserts nothing. Wait a few minutes and run again to get one row per turbine
-- per elapsed 15-minute step.

SELECT advance_wind() AS rows_inserted_per_table;

-- NOTICE:  advance_wind: 2026-08-03 21:15:00+00 to 2026-08-03 22:07:31+00, 120 rows into each hypertable.
--
-- If you have just run the backfill, the newest reading is on the hour, so this
-- generates the handful of 15-minute steps between then and now.


-- ============================================================================
-- ## Refresh the aggregates
-- ============================================================================
-- Strictly speaking this is optional. All three aggregates were created with
-- materialized_only = false, so real-time aggregation already blends the rows
-- we just inserted into any query against them.
--
-- Refreshing explicitly does two things worth having: it moves the new data
-- from the "computed on every read" path into the "already materialized" path,
-- and it lets you see the refresh happen rather than waiting for the policy's
-- schedule_interval.
--
-- NULL, NULL means "every bucket". At workshop scale that is instant; on a
-- large hypertable you would bound it, e.g.
--   CALL refresh_continuous_aggregate('cagg_turbine_power_hourly',
--                                     now() - INTERVAL '2 days', NULL);

CALL refresh_continuous_aggregate('cagg_turbine_power_hourly',  NULL, NULL);
CALL refresh_continuous_aggregate('cagg_plant_power_hourly',    NULL, NULL);
CALL refresh_continuous_aggregate('cagg_regional_power_hourly', NULL, NULL);
CALL refresh_continuous_aggregate('cagg_turbine_power_daily',   NULL, NULL);


-- ============================================================================
-- ## After
-- ============================================================================

SELECT COUNT(*)  AS rows_after,
       MAX(time) AS newest_after,
       COUNT(*) FILTER (WHERE source = 'backfill')   AS from_backfill,
       COUNT(*) FILTER (WHERE source = 'model_live') AS from_live
  FROM wind_measurements;

-- The `source` column is why it is worth distinguishing the two paths even
-- though they run identical model code: you can always tell which rows came
-- from the one-off historical load and which accumulated during the workshop.


-- ============================================================================
-- ## Current fleet state — what the dashboard stat panels show
-- ============================================================================

SELECT COUNT(DISTINCT p.plant_id)                              AS plants,
       COUNT(DISTINCT t.turbine_id)                            AS turbines,
       ROUND(SUM(latest.power_kw)::numeric / 1000, 2)           AS fleet_output_mw,
       ROUND(SUM(p.rated_capacity_kw)::numeric / 1000, 2)       AS fleet_rated_mw,
       ROUND((SUM(latest.power_kw) / SUM(p.rated_capacity_kw) * 100)::numeric, 1)
                                                                AS capacity_factor_pct,
       ROUND(AVG(latest.wake_loss_pct)::numeric, 1)             AS avg_wake_loss_pct,
       COUNT(*) FILTER (WHERE latest.power_kw = 0)              AS not_producing
  FROM turbines t
  JOIN plants p ON p.plant_id = t.plant_id
  CROSS JOIN LATERAL (
         SELECT g.power_kw, g.wake_loss_pct
           FROM power_generation g
          WHERE g.turbine_id = t.turbine_id
          ORDER BY g.time DESC
          LIMIT 1
       ) AS latest;

-- The LATERAL + ORDER BY ... LIMIT 1 pattern is the idiomatic "latest row per
-- entity" query in PostgreSQL, and it is fast here because of the
-- (turbine_id, time DESC) index created in step 03: the planner walks the index
-- backwards and stops after one row per turbine.
--
-- `not_producing` counts turbines at zero output. Some are becalmed below
-- cut-in; others are in storm shutdown above cut-out. Those are very different
-- operational situations that look identical in a power-only view — which is
-- exactly why we kept the raw wind_measurements table:

SELECT t.name,
       p.plant_name,
       p.region_name,
       ROUND(latest.wind_speed_ms::numeric, 1) AS wind_ms,
       p.cut_in_ms,
       p.cut_out_ms,
       CASE
         WHEN latest.wind_speed_ms <  p.cut_in_ms  THEN 'becalmed'
         WHEN latest.wind_speed_ms >= p.cut_out_ms THEN 'STORM SHUTDOWN'
         ELSE 'producing'
       END AS state
  FROM turbines t
  JOIN plants p ON p.plant_id = t.plant_id
  CROSS JOIN LATERAL (
         SELECT wind_speed_ms
           FROM wind_measurements m
          WHERE m.turbine_id = t.turbine_id
          ORDER BY m.time DESC
          LIMIT 1
       ) AS latest
 WHERE latest.wind_speed_ms < p.cut_in_ms
    OR latest.wind_speed_ms >= p.cut_out_ms
 ORDER BY state, t.name;

-- Storm shutdowns are rare (well under 1% of readings), so most runs will show
-- only becalmed turbines here. To force one for demonstration purposes, ask the
-- model about a moment when a storm was passing:
--
--   SELECT m.time, t.name, ROUND(m.wind_speed_ms::numeric,1) AS wind_ms
--     FROM wind_measurements m
--     JOIN turbines t USING (turbine_id)
--     JOIN plants p ON p.plant_id = t.plant_id
--    WHERE m.wind_speed_ms >= p.cut_out_ms
--    ORDER BY m.wind_speed_ms DESC LIMIT 5;
