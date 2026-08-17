-- ============================================================================
-- # Wind Energy — Step 09: Columnstore and Retention
-- ============================================================================
-- Automated data lifecycle. Two policies per hypertable:
--
--   columnstore   after 7 days, convert chunks to columnar storage
--   retention     after 3 years, drop chunks entirely (must exceed the 2-year
--                 initial load — see the note on the retention policy below)
--
-- Both intervals are knobs, not laws. What matters is understanding what each
-- one trades away.
-- ============================================================================


-- ============================================================================
-- ## Columnstore policies
-- ============================================================================
-- Declaring tsdb.segmentby and tsdb.orderby back in step 03 ALREADY created a
-- default columnstore policy. Calling add_columnstore_policy now would fail:
--
--   ERROR:  42710: policy already exists for hypertable "wind_measurements"
--
-- So the pattern throughout this repo is remove-then-add. It is idempotent,
-- which also makes this file safe to re-run.

CALL remove_columnstore_policy('wind_measurements', if_exists => true);
CALL remove_columnstore_policy('power_generation',  if_exists => true);

-- Why 7 days?
--
-- Recent data is queried constantly by dashboards, and lives in the rowstore
-- where writes are cheapest and single-row lookups are fastest. Older data is
-- read in bulk by analytical queries, which is exactly what columnar storage is
-- good at: only the columns in the query are read, and similar values sit
-- adjacent so they compress hard.
--
-- Seven days covers "this week" interactively while converting everything
-- older. Shorten it to compress more aggressively; lengthen it if you regularly
-- update recent history.
--
-- Note that a columnstore chunk is NOT read-only. Hypercore accepts inserts,
-- updates, deletes and upserts against compressed chunks transparently. This
-- matters enormously for the Fleet Tracking workshop, which has data arriving up to 7 days late —
-- and it contradicts a lot of older advice that still circulates.

-- The policies for BOTH the raw tables and the aggregates are registered together
-- lower down, once the aggregates have had columnstore enabled on them.


-- ============================================================================
-- ## Nothing to convert by hand — and why
-- ============================================================================
--
-- The usual pattern here is a loop that converts the already-cold chunks so the
-- compression benefit is visible during the workshop instead of whenever the
-- policy next runs. This file does not do that, for two reasons.
--
-- FIRST, it is unnecessary for the raw tables. backfill_wind() writes every batch
-- older than `columnstore_after_days` DIRECTLY into the columnstore
-- (timescaledb.enable_direct_compress_insert), aligned so that one batch fills one
-- chunk. So by the time this file runs, the cold raw chunks are already columnar —
-- there is nothing for a conversion pass to do. Confirm it below.
--
-- SECOND, and more importantly, driving the conversion from plpgsql is not safe at
-- this scale. convert_to_columnstore is a PROCEDURE that commits internally, and
-- looping it over ~105 chunks from inside a plpgsql block reliably took the whole
-- backend down on TimescaleDB 2.29:
--
--   psql: error: connection to server was lost
--   FATAL: the database system is in recovery mode
--
-- That happened with a `FOR ... IN SELECT` loop (which holds a portal open across
-- the commits), and it still happened after switching to FOREACH over an array.
-- Wrapping the call in an exception handler made it worse, because a plpgsql
-- EXCEPTION block is a subtransaction and a procedure that manages its own
-- transactions cannot commit inside one.
--
-- The conclusion is worth carrying to your own code: let the POLICY do this. It is
-- a background worker built for exactly this job, it converts chunks a few at a
-- time without holding anything open, and it is already registered below. If you
-- want a specific chunk converted right now, do it as a bare top-level statement
-- with nothing wrapped around it:
--
--   CALL convert_to_columnstore('_timescaledb_internal._hyper_2_7_chunk');
--
-- To watch the policy work through the backlog:
--
--   SELECT hypertable_name, total_chunks, number_compressed_chunks
--     FROM hypertable_columnstore_stats('power_generation');
--
--   SELECT job_id, last_run_status, last_successful_finish, total_successes
--     FROM timescaledb_information.job_stats
--    WHERE proc_name = 'policy_compression';


-- ============================================================================
-- ## The aggregates need compressing too
-- ============================================================================
--
-- This section exists because of a measurement that was genuinely surprising.
-- With two years of history loaded and the raw tables compressed ~90%, the
-- largest object in the database was not raw telemetry — it was the hourly
-- turbine aggregate, at three times the size of its own source:
--
--   cagg_turbine_power_hourly   777 MB   <-- UNCOMPRESSED
--   wind_measurements           289 MB   (compressed)
--   power_generation            243 MB   (compressed)
--
-- That is less strange than it first looks. An hourly aggregate over 15-minute
-- data cuts the row count only 4x, it stores thirteen columns where the raw table
-- stores eight, and it carries group indexes the raw table does not. Compress the
-- source and leave the aggregate alone, and the aggregate wins on size.
--
-- A continuous aggregate is itself a hypertable, so it compresses the same way —
-- with two differences from a raw table.
--
--   1. Columnstore is NOT on by default, and `add_columnstore_policy` refuses
--      until it is:
--        ERROR: columnstore not enabled on continuous aggregate "..."
--        HINT:  Enable columnstore before adding a columnstore policy.
--      It also cannot be set in the CREATE MATERIALIZED VIEW WITH clause —
--      TimescaleDB rejects that with the same hint — so ALTER is the only route,
--      and that is why these settings live here rather than in step 08.
--
--   2. `after` must EXCEED every refresh policy's `start_offset`, or the refresh
--      job keeps rewriting buckets that were just compressed and pays
--      decompress-then-recompress on every run. Our start_offsets are 7 days
--      (hourly) and 10 days (daily); `cagg_columnstore_after_days` is 30.
--
-- `segmentby` is the drill-down key at each tier, matching how the dashboards
-- filter. Note the time column differs — `bucket` on the hourly aggregates,
-- `day` on the daily one.

ALTER MATERIALIZED VIEW cagg_turbine_power_hourly
  SET (timescaledb.enable_columnstore = true,
       timescaledb.segmentby = 'turbine_id',
       timescaledb.orderby   = 'bucket DESC');

ALTER MATERIALIZED VIEW cagg_turbine_power_daily
  SET (timescaledb.enable_columnstore = true,
       timescaledb.segmentby = 'turbine_id',
       timescaledb.orderby   = 'day DESC');

ALTER MATERIALIZED VIEW cagg_plant_power_hourly
  SET (timescaledb.enable_columnstore = true,
       timescaledb.segmentby = 'plant_id',
       timescaledb.orderby   = 'bucket DESC');

ALTER MATERIALIZED VIEW cagg_regional_power_hourly
  SET (timescaledb.enable_columnstore = true,
       timescaledb.segmentby = 'region_name',
       timescaledb.orderby   = 'bucket DESC');

ALTER MATERIALIZED VIEW cagg_plant_power_daily
  SET (timescaledb.enable_columnstore = true,
       timescaledb.segmentby = 'plant_id',
       timescaledb.orderby   = 'day DESC');

ALTER MATERIALIZED VIEW cagg_regional_power_daily
  SET (timescaledb.enable_columnstore = true,
       timescaledb.segmentby = 'region_name',
       timescaledb.orderby   = 'day DESC');

-- The weather chain, same treatment. segmentby turbine_id because that is how
-- the turbine dashboard filters them.
ALTER MATERIALIZED VIEW cagg_wind_hourly
  SET (timescaledb.enable_columnstore = true,
       timescaledb.segmentby = 'turbine_id',
       timescaledb.orderby   = 'bucket DESC');

ALTER MATERIALIZED VIEW cagg_wind_daily
  SET (timescaledb.enable_columnstore = true,
       timescaledb.segmentby = 'turbine_id',
       timescaledb.orderby   = 'day DESC');

-- Their policies are registered in the next section, with the raw tables'.


-- ============================================================================
-- ## Register the policies
-- ============================================================================
-- Eight policies: two raw hypertables and six continuous aggregates. From here
-- the background workers own the lifecycle — they pick up the aggregate chunks
-- that are already cold within a minute or two, and everything that goes cold
-- later on its own schedule.

CALL add_columnstore_policy('wind_measurements',
       after => make_interval(days => cfg_int('columnstore_after_days')),
       if_not_exists => true);
CALL add_columnstore_policy('power_generation',
       after => make_interval(days => cfg_int('columnstore_after_days')),
       if_not_exists => true);

-- Drive this from the CATALOG, not from a hand-written list. An earlier version
-- enumerated the aggregates literally, and when cagg_plant_power_daily and
-- cagg_regional_power_daily were added the ALTER block above was updated but this
-- array was not. The result was silent and durable: both views had
-- `enable_columnstore = true` with segmentby and orderby set, so they LOOKED
-- configured, but with no policy nothing ever converted them. They would have grown
-- uncompressed forever. Enumerating the catalog cannot drift.
DO $$
DECLARE
  v_cagg  TEXT;
  v_after INTERVAL := make_interval(days => cfg_int('cagg_columnstore_after_days'));
  v_count INT := 0;
BEGIN
  FOR v_cagg IN
    SELECT view_name
      FROM timescaledb_information.continuous_aggregates
     WHERE view_schema = 'public'
       AND compression_enabled          -- only those we just enabled columnstore on
     ORDER BY view_name
  LOOP
    BEGIN
      CALL add_columnstore_policy(v_cagg, after => v_after, if_not_exists => true);
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT ILIKE '%already exists%' THEN RAISE; END IF;
    END;
  END LOOP;
  RAISE NOTICE 'columnstore policy present on % continuous aggregate(s), after => %',
               v_count, v_after;
END $$;

-- Assert it: every columnstore-enabled aggregate must have a policy acting on it.
-- `jobs.hypertable_name` holds the USER-FACING VIEW NAME for these policies, not the
-- materialization hypertable — see TIGER_PLATFORM.md.
DO $$
DECLARE v_missing TEXT;
BEGIN
  SELECT string_agg(ca.view_name, ', ' ORDER BY ca.view_name) INTO v_missing
    FROM timescaledb_information.continuous_aggregates ca
   WHERE ca.view_schema = 'public'
     AND ca.compression_enabled
     AND NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs j
                      WHERE j.proc_name = 'policy_compression'
                        AND j.hypertable_name = ca.view_name);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'columnstore enabled but no policy on: %', v_missing;
  END IF;
  RAISE NOTICE 'verified: every columnstore-enabled aggregate has a policy';
END $$;


-- ============================================================================
-- ## Measure the compression
-- ============================================================================

-- hypertable_columnstore_stats() is the current name (hypertable_compression_stats
-- still works as an alias). Note it does NOT return the hypertable's name, so
-- the label has to be supplied as a literal.

SELECT 'wind_measurements'                            AS hypertable,
       total_chunks,
       number_compressed_chunks                       AS columnar_chunks,
       pg_size_pretty(before_compression_total_bytes)  AS before,
       pg_size_pretty(after_compression_total_bytes)   AS after,
       ROUND(
         100.0 * (1 - after_compression_total_bytes::numeric
                     / NULLIF(before_compression_total_bytes, 0)), 1
       )                                              AS saved_pct
  FROM hypertable_columnstore_stats('wind_measurements')
 UNION ALL
SELECT 'power_generation',
       total_chunks,
       number_compressed_chunks,
       pg_size_pretty(before_compression_total_bytes),
       pg_size_pretty(after_compression_total_bytes),
       ROUND(
         100.0 * (1 - after_compression_total_bytes::numeric
                     / NULLIF(before_compression_total_bytes, 0)), 1
       )
  FROM hypertable_columnstore_stats('power_generation');

--     hypertable     | total_chunks | columnar_chunks | before  | after  | saved_pct
-- ------------------+--------------+-----------------+---------+--------+-----------
--  wind_measurements |            5 |               3 | 2936 kB | 672 kB |      77.1
--  power_generation  |            5 |               3 | 3176 kB | 568 kB |      82.1
-- (2 rows)

-- At workshop scale (roughly 29,000 rows per table) the ratio is modest —
-- there is per-chunk overhead to amortise and not much data to find patterns
-- in. On production volumes these same settings routinely reach 90-95%,
-- because segmenting by turbine_id groups each machine's readings together and
-- ordering by time DESC puts numerically similar values side by side. Both are
-- what make the columnar encoding effective; a poorly chosen segmentby can
-- halve the ratio.


-- ============================================================================
-- ## Retention policies
-- ============================================================================
-- Retention DROPS CHUNKS. The data is gone. Choose the interval deliberately.
--
-- One year of raw 15-minute readings for 40 turbines is around 1.4 million rows
-- per table — comfortable. The reason to expire raw data at all is that the
-- continuous aggregates already hold the shape of the history at a fraction of
-- the size, so beyond a year the raw rows earn their storage only if you expect
-- to recompute derived metrics from them.
--
-- THE INTERACTION THAT BITES: a retention policy and a continuous aggregate
-- refresh policy can fight each other. If an aggregate's start_offset reaches
-- further back than retention keeps raw data, a refresh will recompute buckets
-- whose source rows have been dropped and rewrite them as EMPTY — silently
-- destroying rolled-up history.
--
-- Our numbers: retention 3 years, aggregate start_offsets 7 and 10 days. No
-- overlap, so no conflict. Always check this explicitly when you change either.

-- THREE years, not one, and the reason is worth pausing on: the initial load is
-- TWO years (`backfill_days` = 730). A one-year retention policy would delete
-- half the history the workshop just generated — not immediately, but whenever
-- the retention job next ran, which is the worst version of this mistake. The
-- dashboards would look right, then quietly lose their older year mid-session,
-- and the daily aggregate tier would have nothing left to show.
--
-- The rule: RETENTION MUST EXCEED THE HISTORY YOU INTEND TO KEEP. If you raise
-- `backfill_days` past 1,095, raise this too.
SELECT add_retention_policy('wind_measurements', INTERVAL '3 years', if_not_exists => true);
SELECT add_retention_policy('power_generation',  INTERVAL '3 years', if_not_exists => true);

-- Tiered storage is the other half of this story on Tiger Cloud: instead of
-- dropping old chunks, move them to object storage where they stay queryable at
-- much lower cost. It needs to be enabled on the service, so it is commented
-- out here rather than failing on a free/dev service.
--
-- SELECT add_tiering_policy('wind_measurements', INTERVAL '90 days');
-- SELECT add_tiering_policy('power_generation',  INTERVAL '90 days');


-- ============================================================================
-- ## Verify: every hypertable has both policies
-- ============================================================================
-- Note again that for policy jobs, jobs.hypertable_name is the name you
-- recognise — the same trap as the refresh-policy check in step 08.

SELECT h.hypertable_name,
       MAX(CASE WHEN j.proc_name = 'policy_compression' THEN j.config ->> 'compress_after' END)
         AS columnstore_after,
       MAX(CASE WHEN j.proc_name = 'policy_retention'   THEN j.config ->> 'drop_after' END)
         AS retention_after
  FROM timescaledb_information.hypertables h
  LEFT JOIN timescaledb_information.jobs j
         ON j.hypertable_schema = h.hypertable_schema
        AND j.hypertable_name   = h.hypertable_name
        AND j.proc_name IN ('policy_compression', 'policy_retention')
 WHERE h.hypertable_name IN ('wind_measurements', 'power_generation')
 GROUP BY h.hypertable_name
 ORDER BY h.hypertable_name;

--  hypertable_name   | columnstore_after | retention_after
-- -------------------+-------------------+-----------------
--  power_generation  | 7 days            | 1 year
--  wind_measurements | 7 days            | 1 year
-- (2 rows)

-- Both columns must be non-null for both tables.


-- ============================================================================
-- ## Chunk-level detail
-- ============================================================================
-- Which chunks are columnar and which are still rowstore.

SELECT hypertable_name,
       chunk_name,
       range_start::date AS chunk_start,
       is_compressed
  FROM timescaledb_information.chunks
 WHERE hypertable_name IN ('wind_measurements', 'power_generation')
 ORDER BY hypertable_name, range_start;

-- Expect the older chunks compressed and the most recent one or two still
-- rowstore — those are inside the 7-day window and still taking writes from
-- 10_advance_simulation.sql.


-- ============================================================================
-- ## Stand the compression policies down until the data has settled
-- ============================================================================
--
-- The policies are registered and correct. They are now PAUSED, and they stay
-- paused until the last step of this workshop turns them back on.
--
-- This is not squeamishness. Registering a policy hands a background worker a
-- backlog — every aggregate chunk older than `cagg_columnstore_after_days`, which
-- on a two-year history is most of them. That worker takes AccessExclusiveLock on
-- one chunk at a time, and the remaining steps of this workshop do exactly the things
-- that collide with it: step 10 appends and refreshes, step 12 writes 30 days of
-- history into already-compressed chunks and refreshes again. The collision is not
-- a slowdown, it is a hard failure, and it lands on statements that look entirely
-- innocent:
--
--   -- step 10, the "rows before" count
--   SELECT COUNT(*) FROM wind_measurements;
--   ERROR:  deadlock detected
--   DETAIL: Process 207 waits for AccessShareLock on relation 26126;
--           blocked by process 200.
--
-- This is the conversion-versus-concurrent-write contention that the compression
-- notes keep describing, and it is worth seeing that it bites a plain SELECT.
--
-- Pausing here and resuming in step 13 gives the bulk-loading part of the workshop
-- a quiet database, then hands the lifecycle back once nothing else is writing. In
-- production the equivalent is scheduling policies outside your bulk-load window,
-- or pausing them around a backfill — the same trade, on a longer timescale.
--
-- Nothing is lost by waiting: the raw chunks are already columnar (direct compress
-- during the backfill), and the aggregates are only a few hundred MB.

SELECT hypertable_name,
       alter_job(job_id, scheduled => false) IS NOT NULL AS paused
  FROM timescaledb_information.jobs
 WHERE proc_name = 'policy_compression'
 ORDER BY hypertable_name;
