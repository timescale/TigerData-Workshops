-- ============================================================================
-- # Wind Energy — Step 12: ACID Across Assets and Telemetry
-- ============================================================================
-- Everything so far has treated the asset registry and the time series as one
-- database because they are. This file is about why that matters.
--
-- Consider a repowering project: four turbines are added to an existing plant.
-- That single business event touches SIX objects of three different kinds:
--
--   plants              UPDATE turbine_count            relational
--   turbines            INSERT x 4, on a geodesic grid  relational + PostGIS
--   turbine_neighbors   INSERT — and NOT just for the   relational + PostGIS
--                       new machines. Existing turbines
--                       gain new upwind neighbours, so
--                       their wake physics changes too.
--   wind_measurements   INSERT ~4 x 720 rows            HYPERTABLE
--   power_generation    INSERT ~4 x 720 rows            HYPERTABLE
--   4 continuous aggs   invalidated, then refreshed     materialized rollups
--
-- In one PostgreSQL transaction that is a single BEGIN...COMMIT. Either the plant
-- has twelve turbines with complete geometry, complete wake relationships and
-- complete history, or it has eight and nothing changed. There is no third state,
-- and no reconciliation job.
--
-- Split the same system into a relational database plus a separate time-series
-- store and you lose that. The two writes cannot share a transaction, so you get
-- to choose which failure to own:
--
--   * assets committed, telemetry failed  -> turbines that exist with no history,
--                                            and dashboards showing gaps nobody
--                                            can explain
--   * telemetry committed, assets failed  -> orphaned series keyed to turbine ids
--                                            that do not exist; every join drops
--                                            them silently
--   * both "succeeded", one rolled back later, and now the two systems disagree
--     about how many turbines the plant has
--
-- The usual answers are idempotent writers, outbox tables, sagas, nightly
-- reconciliation, and an on-call runbook. All of that is work you do not do here.
-- ============================================================================


-- ============================================================================
-- ## Setup
-- ============================================================================

DROP FUNCTION IF EXISTS expand_plant(TEXT, INTEGER, INTEGER) CASCADE;


-- Which plants this demo operates on is resolved FROM THE DATA, not hardcoded.
-- Plant names are generated from a site catalogue and the fleet shape, so
-- `num_plants` = 6 produces one plant per region and a name like Amarillo_0601
-- may simply not exist. Hardcoding it made this file fail with
-- "no such plant: DodgeCity_0602" the moment the default fleet size changed.
--
-- \gset assigns each selected column to a psql variable named after it. Note the
-- trap: if the query returns NO rows, \gset leaves the variable unset and every
-- later reference expands to the literal text ":demo_plant". Both regions below
-- always have at least one plant, so this is safe here — but check the counts if
-- you have edited the region list.

-- Both queries below are written to return EXACTLY ONE ROW for any fleet shape,
-- including `--plants 1`. That is not defensiveness for its own sake: \gset raises
-- "no rows returned for \gset" and aborts the script if its query is empty, and
-- the obvious version (WHERE region_name = 'Southern Great Plains') is empty as
-- soon as num_plants is small enough that no plant landed in that region.
--
-- So: prefer a plant in the named region, fall back to any plant. The ORDER BY
-- puts the preferred region first rather than filtering to it.

SELECT plant_name AS demo_plant
  FROM plants
 ORDER BY (region_name = 'Southern Great Plains') DESC, plant_name
 LIMIT 1
\gset

-- The rollback demo wants a DIFFERENT plant, so that the expansion it discards is
-- visibly not the one expanded above. With only one plant in the fleet there is no
-- other, and COALESCE falls back to reusing it — harmless, because that expansion
-- is rolled back anyway.
SELECT COALESCE(
         (SELECT plant_name
            FROM plants
           WHERE plant_name <> :'demo_plant'
           ORDER BY (region_name = 'Inner Mongolian Plateau') DESC, plant_name
           LIMIT 1),
         :'demo_plant') AS rollback_plant
\gset

\echo 'Demo plant:     ':demo_plant
\echo 'Rollback plant: ':rollback_plant

-- The columnstore policies are already paused — step 09 stood them down and step
-- 13 brings them back. That matters here: expand_plant() writes 30 days of history
-- into chunks that are already compressed, which leaves them partially compressed,
-- and a compression job reacting to that in the background would deadlock against
-- the queries below. See the note at the end of step 09.


-- ============================================================================
-- ## expand_plant() — the whole business event in one function
-- ============================================================================
-- Adds p_add_turbines machines to an existing plant, extending the existing grid
-- rather than starting a new one, and backfills their history so they are
-- immediately comparable with the incumbents.
--
-- Every statement below is ordinary SQL against ordinary tables. Nothing here is
-- aware that two of those tables are hypertables — which is the point.
--
-- Deliberately NOT in this function: the continuous aggregate refresh. Read the
-- note at the end of the file; that one genuinely cannot go inside a transaction.

CREATE OR REPLACE FUNCTION expand_plant(
  p_plant_name    TEXT,
  p_add_turbines  INTEGER,
  p_backfill_days INTEGER DEFAULT NULL
) RETURNS TABLE (
  step        TEXT,
  rows_change BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_plant     plants;
  v_old_count INTEGER;
  v_new_count INTEGER;
  v_cols      INTEGER;
  v_rows_n    INTEGER;
  v_days      INTEGER;
  v_from      TIMESTAMPTZ;
  v_to        TIMESTAMPTZ;
  v_n         BIGINT;
  v_width     INTEGER;
BEGIN
  SELECT * INTO v_plant FROM plants WHERE plant_name = p_plant_name;
  IF v_plant.plant_id IS NULL THEN
    RAISE EXCEPTION 'no such plant: %', p_plant_name;
  END IF;

  v_old_count := v_plant.turbine_count;
  v_new_count := v_old_count + p_add_turbines;
  v_days      := COALESCE(p_backfill_days, cfg_int('backfill_days'), 30);
  v_to        := date_trunc('hour', now());
  v_from      := v_to - make_interval(days => v_days);

  -- The grid geometry is recomputed for the NEW total, so the added machines
  -- extend the array on the same axes and spacing as the originals.
  -- EXTEND THE EXISTING LATTICE. Do not recompute the column count from the new
  -- total: step 04 laid the plant out on CEIL(SQRT(old_count)) columns, and
  -- CEIL(SQRT(new_count)) is a different number the moment the count crosses a
  -- square. At 16 -> 20 turbines it goes 4 -> 5, which re-pitches AND re-centres
  -- the grid, because dx0 is centred on (cols-1)/2. The new machines then sit half
  -- a spacing off the existing lattice and reuse grid_col values already taken:
  -- row 3 came out as 0,1,1,2,2,3,3,4 — duplicate grid positions at different
  -- coordinates. Read the column count back from the turbines already placed.
  SELECT MAX(t.grid_col) + 1 INTO v_cols
    FROM turbines t WHERE t.plant_id = v_plant.plant_id;
  v_cols := COALESCE(v_cols, CEIL(SQRT(v_new_count::numeric))::INTEGER);

  -- And centre the downwind axis on the ORIGINAL row count, for the same reason:
  -- dy0 is centred on (rows_n-1)/2, so recomputing it from the new total would
  -- shift every new row relative to the machines already in the ground. Rows past
  -- the original extent then simply continue downwind, which is what we want.
  v_rows_n := CEIL(v_old_count::numeric / v_cols)::INTEGER;
  v_width  := GREATEST(2, LENGTH(v_new_count::TEXT));

  -- ---------------------------------------------------------------- 1. plant
  UPDATE plants SET turbine_count = v_new_count WHERE plant_id = v_plant.plant_id;
  RETURN QUERY SELECT 'plants updated'::TEXT, 1::BIGINT;

  -- ------------------------------------------------------------- 2. turbines
  -- Same ST_Project geodesic layout as step 04, INCLUDING its half-spacing row
  -- stagger. Only the new indices are inserted; existing turbines keep their
  -- coordinates.
  WITH ins AS (
    INSERT INTO turbines (plant_id, name, turbine_no, grid_row, grid_col, location, installed_at)
    SELECT v_plant.plant_id,
           v_plant.plant_name || '-T' || LPAD((k.i + 1)::TEXT, v_width, '0'),
           k.i + 1,
           g.grow,
           g.gcol,
           ST_Project(v_plant.center_location, o.dist_m, o.azimuth_rad),
           CURRENT_DATE
      FROM generate_series(v_old_count, v_new_count - 1) AS k(i)
      CROSS JOIN LATERAL (
        SELECT (k.i % v_cols) AS gcol, (k.i / v_cols) AS grow
      ) g
      CROSS JOIN LATERAL (
        -- The half-spacing stagger from step 04 MUST be repeated here, or the
        -- expansion turbines land on an un-staggered grid inside a staggered
        -- plant. That is not cosmetic: step 04's own verification averages the
        -- bearing to the machine two rows back, and mixing the two layouts pushed
        -- it from ~0 to 4.73 degrees — a reading whose stated meaning is "the whole
        -- wake model is aimed in the wrong direction".
        SELECT (g.gcol - (v_cols   - 1) / 2.0
                + CASE WHEN g.grow % 2 = 1 THEN 0.5 ELSE 0.0 END) * v_plant.spacing_crosswind_m AS dx0,
               ((v_rows_n - 1) / 2.0 - g.grow) * v_plant.spacing_downwind_m  AS dy0
      ) d
      CROSS JOIN LATERAL (
        SELECT  d.dx0 * COS(RADIANS(v_plant.grid_bearing_deg))
              + d.dy0 * SIN(RADIANS(v_plant.grid_bearing_deg)) AS dx,
                d.dy0 * COS(RADIANS(v_plant.grid_bearing_deg))
              - d.dx0 * SIN(RADIANS(v_plant.grid_bearing_deg)) AS dy
      ) r
      CROSS JOIN LATERAL (
        SELECT SQRT(r.dx * r.dx + r.dy * r.dy) AS dist_m, ATAN2(r.dx, r.dy) AS azimuth_rad
      ) o
    RETURNING 1)
  SELECT COUNT(*) INTO v_n FROM ins;
  RETURN QUERY SELECT 'turbines inserted'::TEXT, v_n;

  -- ----------------------------------------------------- 3. wake relationships
  -- Rebuild ALL pairs for this plant, not only the new ones. This is the subtle
  -- part of a physical expansion: an existing turbine that used to stand in clean
  -- air may now have a new machine directly upwind of it, so its wake losses
  -- change even though nothing about that turbine was touched.
  DELETE FROM turbine_neighbors WHERE plant_id = v_plant.plant_id;

  WITH ins AS (
    INSERT INTO turbine_neighbors (
      turbine_id, neighbor_id, plant_id, distance_m, bearing_deg,
      rotor_diameters, jensen_deficit, wake_half_angle_deg)
    SELECT a.turbine_id, nb.neighbor_id, a.plant_id, nb.dist_m,
           DEGREES(ST_Azimuth(a.location, nb.location)),
           nb.dist_m / v_plant.rotor_diameter_m,
           0.5528 / POWER(1.0 + 2.0 * k.wake_k * (nb.dist_m / v_plant.rotor_diameter_m), 2),
           DEGREES(ATAN((v_plant.rotor_diameter_m / 2.0 + k.wake_k * nb.dist_m) / nb.dist_m))
      FROM turbines a
      CROSS JOIN LATERAL (
        SELECT CASE WHEN v_plant.is_offshore THEN 0.04
                    ELSE cfg_num('wake_decay_k') END AS wake_k) k
      CROSS JOIN LATERAL (
        SELECT b.turbine_id AS neighbor_id, b.location,
               ST_Distance(a.location, b.location) AS dist_m
          FROM turbines b
         WHERE b.plant_id = a.plant_id
           AND b.turbine_id <> a.turbine_id
           AND ST_DWithin(b.location, a.location, 12.0 * v_plant.rotor_diameter_m)
      ) nb
     WHERE a.plant_id = v_plant.plant_id
       AND nb.dist_m > 1.0
    RETURNING 1)
  SELECT COUNT(*) INTO v_n FROM ins;
  RETURN QUERY SELECT 'wake pairs rebuilt'::TEXT, v_n;

  -- --------------------------------------------- 4 & 5. telemetry backfill
  -- Two HYPERTABLES, written in the same transaction as the relational changes
  -- above by exactly the same kind of INSERT ... SELECT.
  WITH free_stream AS MATERIALIZED (
    SELECT g.ts AS time, t.turbine_id, t.plant_id, v_plant.region_name AS region_name,
           GREATEST(0.0, w.wind_speed_ms + random_normal(0.0, 0.45)) AS free_wind_speed_ms,
           MOD((w.wind_direction_deg + random_normal(0.0, 8.0) + 360.0)::numeric, 360.0)
             ::DOUBLE PRECISION AS wind_direction_deg,
           w.temperature_c + random_normal(0.0, 0.6) AS temperature_c
      FROM turbines t
      JOIN regions r ON r.region_name = v_plant.region_name
      CROSS JOIN generate_series(v_from, v_to, INTERVAL '1 hour') AS g(ts)
      CROSS JOIN LATERAL wind_at(t.turbine_id,
                                 ST_Y(t.location::geometry),
                                 ST_X(t.location::geometry),
                                 v_plant.is_offshore, g.ts,
                                 r.wind_base_ms, r.wind_seasonal_ms, r.wind_peak_doy,
                                 r.temp_mean_c, r.temp_seasonal_amp_c,
                                 r.temp_peak_doy, r.temp_diurnal_amp_c) AS w
     WHERE t.plant_id = v_plant.plant_id
       AND t.turbine_no > v_old_count
  ),
  waked AS (
    SELECT f.*, apply_wake(f.turbine_id, f.wind_direction_deg) AS wake_factor,
           turbine_health(f.turbine_id, f.time)                AS health
      FROM free_stream f
  ),
  ins_m AS (
    INSERT INTO wind_measurements
      (time, turbine_id, plant_id, free_wind_speed_ms, wind_speed_ms,
       wind_direction_deg, temperature_c, source)
    SELECT time, turbine_id, plant_id, free_wind_speed_ms,
           free_wind_speed_ms * wake_factor, wind_direction_deg, temperature_c, 'backfill'
      FROM waked
    RETURNING 1
  )
  INSERT INTO power_generation
    (time, turbine_id, plant_id, region_name, power_kw, expected_power_kw,
     wind_speed_ms, wake_loss_pct)
  SELECT time, turbine_id, plant_id, region_name,
         power_from_wind_speed(free_wind_speed_ms * wake_factor, v_plant.cut_in_ms,
                               v_plant.cut_out_ms, v_plant.rotor_diameter_m,
                               v_plant.rated_capacity_kw) * health,
         power_from_wind_speed(free_wind_speed_ms * wake_factor, v_plant.cut_in_ms,
                               v_plant.cut_out_ms, v_plant.rotor_diameter_m,
                               v_plant.rated_capacity_kw),
         free_wind_speed_ms * wake_factor,
         0.0
    FROM waked;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'telemetry rows per hypertable'::TEXT, v_n;

  RAISE NOTICE 'expand_plant: % went from % to % turbines, % days of history generated.',
    p_plant_name, v_old_count, v_new_count, v_days;
END;
$$;


-- ============================================================================
-- ## Demo 1: a rollback leaves absolutely nothing behind
-- ============================================================================
-- Snapshot every affected object, run the whole expansion, then throw it away.
-- Both the relational tables and the hypertables must come back unchanged.

CREATE TEMPORARY TABLE acid_before AS
SELECT (SELECT turbine_count FROM plants WHERE plant_name = :'demo_plant')       AS plant_count,
       (SELECT COUNT(*) FROM turbines WHERE plant_id =
          (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant'))        AS turbines,
       (SELECT COUNT(*) FROM turbine_neighbors WHERE plant_id =
          (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant'))        AS wake_pairs,
       (SELECT COUNT(*) FROM wind_measurements WHERE plant_id =
          (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant'))        AS wind_rows,
       (SELECT COUNT(*) FROM power_generation WHERE plant_id =
          (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant'))        AS power_rows;

BEGIN;

  -- The third argument is the backfill window for the NEW turbines, in days, and
-- passing it explicitly matters for two reasons.
--
-- Realism first: a turbine commissioned last month has a month of history, not
-- the two years its neighbours have. Left to default it would inherit
-- `backfill_days` and be given a fabricated 730-day past.
--
-- And cost second: the aggregate refresh that follows has to cover whatever range
-- was written. Backfilling 730 days for four turbines invalidates two years of
-- every aggregate, and refreshing that much while the columnstore policies are
-- working the same chunks deadlocks:
--
--   ERROR:  deadlock detected
--
-- Thirty days keeps the refresh to the window that actually changed.

SELECT * FROM expand_plant(:'demo_plant', 4, 30);

  -- Inside the transaction everything is already consistent and queryable.
  SELECT 'inside transaction' AS state,
         (SELECT turbine_count FROM plants WHERE plant_name = :'demo_plant') AS plant_count,
         (SELECT COUNT(*) FROM turbines WHERE plant_id =
            (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant'))  AS turbines,
         (SELECT COUNT(*) FROM turbine_neighbors WHERE plant_id =
            (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant')) AS wake_pairs,
         (SELECT COUNT(*) FROM power_generation WHERE plant_id =
            (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant')) AS power_rows;

ROLLBACK;

-- And afterwards, byte-for-byte the state we started with — including the
-- hypertables. A rollback that spans relational rows, PostGIS geometry and
-- time-series chunks is not a special feature here; it is just a transaction.
SELECT 'before' AS state, * FROM acid_before
UNION ALL
SELECT 'after rollback',
       (SELECT turbine_count FROM plants WHERE plant_name = :'demo_plant'),
       (SELECT COUNT(*) FROM turbines WHERE plant_id =
          (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant')),
       (SELECT COUNT(*) FROM turbine_neighbors WHERE plant_id =
          (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant')),
       (SELECT COUNT(*) FROM wind_measurements WHERE plant_id =
          (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant')),
       (SELECT COUNT(*) FROM power_generation WHERE plant_id =
          (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant'));


-- ============================================================================
-- ## Demo 2: a failure mid-transaction takes the whole thing with it
-- ============================================================================
-- The realistic version of the split-system problem. Here the expansion succeeds,
-- thousands of telemetry rows land, and THEN a later statement violates a
-- constraint. Everything unwinds.

CREATE TEMPORARY TABLE acid_fail_before AS
SELECT (SELECT COUNT(*) FROM turbines)          AS turbines,
       (SELECT COUNT(*) FROM power_generation)  AS power_rows;

DO $$
DECLARE
  v_msg   TEXT;
  v_plant TEXT;
BEGIN
  -- Resolved here in SQL rather than with :'rollback_plant'. psql does NOT
  -- interpolate its variables inside a dollar-quoted body, so the reference would
  -- survive verbatim into the parser and fail with `syntax error at or near ":"`.
  -- Same fallback logic as the \gset above, for the same reason: filtering to one
  -- region returns nothing on a small fleet, and a NULL plant name would make
  -- expand_plant() raise "no such plant: <NULL>" instead of demonstrating the
  -- rollback this block exists to show.
  SELECT plant_name INTO v_plant
    FROM plants
   ORDER BY (region_name = 'Inner Mongolian Plateau') DESC, plant_name
   LIMIT 1;

  -- One atomic unit: expand the plant, then attempt an impossible write.
  PERFORM expand_plant(v_plant, 4, 30);

  -- Telemetry for a turbine that does not exist. There is no FK on the hypertable
  -- (deliberately — see the note below), so this one is caught by a CHECK instead:
  -- an out-of-range wind direction. Either way the whole unit fails.
  INSERT INTO wind_measurements
    (time, turbine_id, plant_id, free_wind_speed_ms, wind_speed_ms,
     wind_direction_deg, temperature_c, source)
  VALUES (now(), gen_random_uuid(), NULL, 8.0, 8.0,
          999,                      -- violates wind_measurements_direction_range
          15.0, 'backfill');

  RAISE EXCEPTION 'should not reach here';
EXCEPTION WHEN check_violation THEN
  GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
  RAISE NOTICE 'Constraint rejected the bad row: %', v_msg;
  RAISE NOTICE 'The plant expansion in the same block is being discarded with it.';
END $$;

-- A DO block is a single transaction, so the failed CHECK discarded the entire
-- expansion — the plants UPDATE, four turbines, their geometry, the rebuilt wake
-- pairs, and every telemetry row.
SELECT 'before' AS state, * FROM acid_fail_before
UNION ALL
SELECT 'after failed expansion',
       (SELECT COUNT(*) FROM turbines),
       (SELECT COUNT(*) FROM power_generation);

-- Counts identical. In a two-system architecture the asset registry would have
-- committed and you would now own an inconsistency, discovered later, by someone
-- else, probably on a dashboard.


-- ============================================================================
-- ## Demo 3: do it for real
-- ============================================================================

SELECT * FROM expand_plant(:'demo_plant', 4, 30);

SELECT p.plant_name,
       p.turbine_count                                   AS declared,
       COUNT(DISTINCT t.turbine_id)                      AS actual_turbines,
       COUNT(DISTINCT n.turbine_id)                      AS turbines_with_wake_pairs,
       ROUND((p.turbine_count * p.rated_capacity_kw / 1000.0)::numeric, 1) AS nameplate_mw
  FROM plants p
  LEFT JOIN turbines t          ON t.plant_id = p.plant_id
  LEFT JOIN turbine_neighbors n ON n.plant_id = p.plant_id
 WHERE p.plant_name = :'demo_plant'
 GROUP BY p.plant_id, p.plant_name, p.turbine_count, p.rated_capacity_kw;

-- declared must equal actual_turbines. That equality is the invariant a split
-- architecture cannot guarantee without extra machinery.

-- Every new turbine has geometry, wake relationships AND history — no partial rows.
SELECT t.name,
       t.grid_row || ',' || t.grid_col          AS grid_pos,
       COUNT(DISTINCT n.neighbor_id)            AS wake_neighbours,
       COUNT(pg.*)                              AS telemetry_rows,
       ROUND(AVG(pg.power_kw)::numeric, 0)      AS avg_power_kw
  FROM turbines t
  LEFT JOIN turbine_neighbors n ON n.turbine_id = t.turbine_id
  LEFT JOIN power_generation pg ON pg.turbine_id = t.turbine_id
 WHERE t.plant_id = (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant')
 GROUP BY t.turbine_id, t.name, t.grid_row, t.grid_col
 ORDER BY t.turbine_no;

-- No orphans in either direction:
SELECT 'turbines with no telemetry' AS orphan_check, COUNT(*) AS n
  FROM turbines t
 WHERE NOT EXISTS (SELECT 1 FROM power_generation p WHERE p.turbine_id = t.turbine_id)
UNION ALL
SELECT 'telemetry for unknown turbines', COUNT(*)
  FROM power_generation p
 WHERE NOT EXISTS (SELECT 1 FROM turbines t WHERE t.turbine_id = p.turbine_id);

-- Both zero.


-- ============================================================================
-- ## The expansion changed the incumbents' physics
-- ============================================================================
-- Worth pausing on, because it is the reason the wake table is rebuilt wholesale
-- rather than appended to. Turbines that existed before the expansion now have
-- new machines around them, so some of them acquired upwind neighbours and their
-- wake losses went up — without anything about those turbines being edited.

SELECT t.name,
       t.turbine_no <= 8                        AS was_here_before,
       t.grid_row || ',' || t.grid_col          AS grid_pos,
       COUNT(n.neighbor_id)                     AS wake_neighbours_now
  FROM turbines t
  LEFT JOIN turbine_neighbors n ON n.turbine_id = t.turbine_id
 WHERE t.plant_id = (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant')
 GROUP BY t.turbine_id, t.name, t.turbine_no, t.grid_row, t.grid_col
 ORDER BY t.turbine_no;

-- An 8-turbine 3x3 array becomes a 12-turbine 4x3 array, so the grid is
-- re-laid-out and the original machines sit in different relative positions. In a
-- system where geometry and telemetry lived apart, keeping those two in step would
-- be an offline batch job with a window of inconsistency.


-- ============================================================================
-- ## The one thing that is NOT in the transaction
-- ============================================================================
-- Continuous aggregate refreshes cannot run inside a transaction block:
--
--   ERROR:  refresh_continuous_aggregate() cannot run inside a transaction block
--
-- So the aggregates are refreshed after the commit. This is not a gap in the
-- guarantee — it is a consequence of the aggregates being derived data with their
-- own invalidation log rather than part of the base state.
--
-- And it does not create a window of wrong answers, because every aggregate in
-- step 08 was created with materialized_only = false. Real-time aggregation blends
-- materialized buckets with live raw rows, so a query against any tier includes the
-- new turbines the instant the transaction commits — before any refresh runs. The
-- refresh below just moves that work from query time to now.

-- REFRESH ONLY THE WINDOW THAT CHANGED, not all of history.
--
-- expand_plant() was given a 30-day backfill, so 31 days back covers every bucket
-- it could have invalidated. `NULL, NULL` here would instead refresh two years of
-- six aggregates to account for a month of new rows, and that is not merely
-- wasteful — it reliably fails. Two ways:
--
--   ERROR:  deadlock detected
--     the refresh has to rewrite compressed aggregate chunks, and the columnstore
--     policies registered in step 09 are working the same chunks
--
--   server process was terminated by signal 9: Killed
--     a full-history refresh over millions of rows exhausts memory on a small
--     instance and takes the whole database down with it
--
-- Order matters: parents before the aggregates that read them.

CALL refresh_continuous_aggregate('cagg_turbine_power_hourly',
       now() - INTERVAL '31 days', now());
CALL refresh_continuous_aggregate('cagg_turbine_power_daily',
       now() - INTERVAL '31 days', now());
CALL refresh_continuous_aggregate('cagg_plant_power_hourly',
       now() - INTERVAL '31 days', now());
CALL refresh_continuous_aggregate('cagg_regional_power_hourly',
       now() - INTERVAL '31 days', now());

-- The weather chain too — expand_plant() wrote wind_measurements as well.
CALL refresh_continuous_aggregate('cagg_wind_hourly',
       now() - INTERVAL '31 days', now());
CALL refresh_continuous_aggregate('cagg_wind_daily',
       now() - INTERVAL '31 days', now());

-- The plant tier now reports the expanded plant, and the region tier above it
-- agrees, because both were rebuilt from the same committed rows.
-- Averaged over 24 hours rather than read off the latest bucket. A single hour is
-- at the mercy of the weather: Amarillo sits in the Southern Great Plains and its
-- most recent hours often have wind below the 3.0 m/s cut-in, so the plant
-- correctly reports 0.00 MW and a verification query reading one bucket looks like
-- a failure when nothing is wrong.

SELECT plant_name,
       MAX(turbines_reporting)                          AS turbines_reporting,
       ROUND((AVG(plant_power_kw) / 1000)::numeric, 2)   AS avg_output_mw_24h,
       ROUND(AVG(capacity_factor_pct)::numeric, 1)       AS cf_pct,
       ROUND((100.0 * SUM(plant_power_kw)
              / NULLIF(SUM(plant_expected_power_kw), 0))::numeric, 1) AS performance_pct
  FROM v_plant_hourly
 WHERE plant_name IN (:'demo_plant', :'rollback_plant')
   AND bucket >= now() - INTERVAL '24 hours'
 GROUP BY plant_name
 ORDER BY plant_name;

-- The demo plant reports 12 turbines. The rollback plant still reports 8, because its
-- expansion was rolled back by demo 2 — which is exactly the outcome that
-- architecture is supposed to deliver.

-- And the new machines are producing in line with the incumbents, which is the
-- real proof the expansion was complete rather than merely committed:
SELECT CASE WHEN t.turbine_no <= 8 THEN 'original 8' ELSE 'added by expansion' END AS cohort,
       COUNT(DISTINCT t.turbine_id)                        AS turbines,
       ROUND(AVG(h.avg_power_kw)::numeric, 0)              AS avg_power_kw,
       ROUND(AVG(h.capacity_factor_pct)::numeric, 1)       AS cf_pct,
       ROUND(AVG(h.performance_ratio_pct)::numeric, 1)     AS performance_pct
  FROM turbines t
  JOIN v_turbine_hourly h ON h.turbine_id = t.turbine_id
 WHERE t.plant_id = (SELECT plant_id FROM plants WHERE plant_name = :'demo_plant')
   AND h.bucket >= now() - INTERVAL '7 days'
 GROUP BY cohort
 ORDER BY cohort;


-- ============================================================================
-- ## A note on foreign keys and hypertables
-- ============================================================================
-- `wind_measurements` and `power_generation` deliberately have NO foreign key to
-- `turbines`, which is why demo 2 used a CHECK constraint to force its failure.
--
-- The reason is throughput. A FK on a table taking thousands of rows a second
-- means an index probe into the parent for every row, plus a row lock held on the
-- parent for the life of the transaction. On a high-ingest hypertable that is a
-- real cost for a guarantee the writer already has: telemetry arrives tagged with
-- ids that came from the asset registry in the first place.
--
-- What you get instead is the orphan check above, run as a periodic assertion. If
-- your ingest path is less trustworthy — third-party feeds, manual imports — add
-- the FK and pay for it. the Fleet Tracking workshop makes the same call for the same reason.
--
-- Note this is a decision about the FK specifically, not about transactions.
-- Atomicity across the asset tables and the hypertables holds either way, which is
-- what this file set out to demonstrate.

-- ============================================================================
-- ## What this demo cost in storage, and why it is left alone
-- ============================================================================
--
-- expand_plant() backfilled a full history for the new turbines, which
-- invalidated every aggregate bucket over that range. The refresh then rewrote
-- those buckets, and any that had already been compressed came back uncompressed.
-- On the two-year default that took cagg_turbine_power_hourly from 172 MB to
-- 910 MB. Nothing is wrong with the data — it is just no longer compact.
--
-- This script does NOT try to fix that, on purpose. The aggregates' own
-- columnstore policies will recompress the affected chunks on their next run, and
-- the attempts to force it earlier turned out to be worse than the problem:
-- convert_to_rowstore/convert_to_columnstore manage their own transactions, and
-- driving them in a loop from plpgsql deadlocked against the policy jobs and then
-- crashed the backend outright. See "Nothing to convert by hand" in step 09.
--
-- If you want the space back immediately, do it as bare top-level statements with
-- nothing else running — no exception handler, no wrapping procedure:
--
--   CALL convert_to_rowstore('_timescaledb_internal._hyper_3_42_chunk');
--   CALL convert_to_columnstore('_timescaledb_internal._hyper_3_42_chunk');
--
-- Check the current size with:
--
--   SELECT pg_size_pretty(hypertable_size(
--            (SELECT format('%I.%I', materialization_hypertable_schema,
--                                    materialization_hypertable_name)::regclass
--               FROM timescaledb_information.continuous_aggregates
--              WHERE view_name = 'cagg_turbine_power_hourly')));
