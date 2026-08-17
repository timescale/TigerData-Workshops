-- ============================================================================
-- # Wind Energy — Step 14: Scattered Tiering to Object Storage
-- ============================================================================
-- The last stage of the data lifecycle. Steps 09 and 13 covered the first two:
--
--   rowstore      the hot window, where 15-minute inserts land cheapest
--   columnstore   after 7 days, ~90% smaller, still on block storage
--   OBJECT STORE  this file — after months, moved off block storage entirely
--   dropped       after 3 years, retention
--
-- "Scattered" tiering means each object gets its OWN threshold rather than one
-- blanket rule for the database, and the thresholds are derived from HOW THE
-- DASHBOARDS ACTUALLY READ each object. That is the whole idea of this file, and
-- it produces a result that looks backwards until you see why:
--
--   OBJECT                        SIZE     TIERS AFTER   WHY
--   ---------------------------------------------------------------------------
--   wind_measurements             ~280 MB  26 weeks      biggest, narrowest reads
--   power_generation              ~240 MB  26 weeks      same
--   cagg_turbine_power_hourly     ~170 MB  52 weeks      the workhorse
--   cagg_wind_hourly              ~165 MB  52 weeks      the workhorse
--   cagg_plant_power_hourly        ~20 MB  52 weeks
--   cagg_regional_power_hourly     ~10 MB  52 weeks
--   cagg_turbine_power_daily       ~10 MB  104 weeks     smallest, widest reads
--   cagg_wind_daily                ~10 MB  104 weeks     same
--
-- THE SMALLEST OBJECTS GET THE LONGEST LOCAL RESIDENCY. That is not a mistake.
-- Tiering decisions follow read patterns, not size — and it happens to be nearly
-- free here, because the two daily aggregates that stay local longest are 20 MB
-- between them, while the 520 MB of raw telemetry tiers first.
--
-- ## Prerequisites
--   Steps 01–13, AND tiered storage enabled on the service (Console >
--   your service > Explorer > Data tiering > Enable tiered storage).
--
--   Tiering is a Tiger Cloud feature and a per-service toggle, so it is NOT a
--   workshop prerequisite. This file detects whether it is available and skips
--   cleanly if not — the rest of the workshop does not depend on it.
--
-- ## What You'll Learn
--   - Deriving a tiering threshold from a dashboard's read pattern
--   - Why `timescaledb.enable_tiered_reads` defaults to FALSE, and the silent
--     data loss that causes
--   - That a continuous aggregate is a hypertable and can be tiered too
--   - Ordering the three lifecycle policies so they cannot fight
--
-- ============================================================================


-- ============================================================================
-- ## Opt in, because this one costs money and is not trivially reversible
-- ============================================================================
--
-- Every other file in this workshop only touches your own database. This one
-- ships data to an object store, and that is different in two ways worth being
-- explicit about:
--
--   * it is billable — object storage is cheap, not free
--   * removing the POLICY is easy (`remove_tiering_policy`), but chunks already
--     uploaded STAY tiered. Bringing them back is a per-chunk `untier_chunk()`
--
-- At the two-year default a 26-week threshold makes roughly eighteen months of
-- raw telemetry eligible immediately, which is most of it. So this file does
-- NOTHING unless you ask for it:
--
--   UPDATE workshop_config SET value = 'true' WHERE key = 'enable_tiering';
--
-- or, from the top:
--
--   ./reset_demo.sh --tiering
--
-- Run it without that and it reports exactly what it WOULD do and stops. That is
-- the useful mode for reading the file anyway.

\echo ''
\echo '--- what this step would do ---'

WITH plan AS (
  SELECT * FROM (VALUES
    ('wind_measurements',          'raw',    182, 'raw tier of the turbine view: windows under ~7 days'),
    ('power_generation',           'raw',    182, 'same — recent failure forensics only'),
    ('cagg_turbine_power_hourly',  'hourly', 364, 'plant view now-metrics, turbine view 30d-1y'),
    ('cagg_wind_hourly',           'hourly', 364, 'turbine wind/temperature at 30d-1y'),
    ('cagg_plant_power_hourly',    'hourly', 364, 'region view: plant timelines'),
    ('cagg_regional_power_hourly', 'hourly', 364, 'global view: fleet production timeline'),
    ('cagg_turbine_power_daily',   'daily',  728, 'turbine view at multi-year zoom'),
    ('cagg_plant_power_daily',     'daily',  728, 'region view timelines at coarse zoom'),
    ('cagg_regional_power_daily',  'daily',  728, 'global view timelines at coarse zoom'),
    ('cagg_wind_daily',            'daily',  728, 'global view: 2-year seasonality panels')
  ) AS t(object_name, tier, move_after_days, read_pattern)
)
SELECT p.object_name,
       p.tier,
       (p.move_after_days / 7) || ' weeks' AS tiers_after,
       -- How much of the CURRENT history would become eligible straight away.
       GREATEST(0, cfg_int('backfill_days') - p.move_after_days) || ' days' AS eligible_now,
       p.read_pattern
  FROM plan p
 ORDER BY p.move_after_days, p.object_name;

-- At backfill_days = 730 the raw tables have ~548 days eligible, the hourly
-- aggregates ~366, and the daily aggregates 2 — which is the shape you want:
-- the bulk moves, the long-window aggregates stay.


-- ============================================================================
-- ## Is tiering even available here?
-- ============================================================================
-- Three things have to be true, and they fail differently:
--
--   1. This is Tiger Cloud, not self-hosted TimescaleDB. Self-hosted has no
--      object storage tier at all and no `add_tiering_policy` function.
--   2. Tiered storage is enabled for THIS service, in the Console. Without it
--      the function may exist but the OSM machinery is not installed.
--   3. `timescaledb.enable_tiered_reads` is on, or tiered data is invisible —
--      see the next section, which is the important one.

\echo ''
\echo '--- availability ---'

SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'add_tiering_policy')
         AS has_tiering_api,
       EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'timescaledb_osm')
         AS osm_installed,
       COALESCE(current_setting('timescaledb.enable_tiered_reads', true), 'unset')
         AS enable_tiered_reads,
       COALESCE(cfg('enable_tiering'), 'false') AS opted_in;

-- On a self-hosted instance: has_tiering_api = false, and this file stops here.
-- On Tiger Cloud with tiering enabled: both true.


-- ============================================================================
-- ## The setting that silently deletes your dashboards
-- ============================================================================
--
-- `timescaledb.enable_tiered_reads` DEFAULTS TO FALSE. Read that again in the
-- context of what this file does.
--
-- With it off, a query against a hypertable that has tiered chunks returns only
-- the chunks still on block storage. No error. No warning. No hint in the plan
-- that anything was excluded. A `SELECT count(*)` simply gets smaller, and a
-- dashboard panel silently loses its older history — which, for the global view's
-- two-year seasonality panels, means the entire point of loading two years
-- quietly disappears the moment the daily aggregates tier.
--
-- This is the single most dangerous interaction in the whole lifecycle, because
-- every other mistake in this workshop announces itself with an ERROR.
--
-- Set it at the DATABASE level, not the session level. Grafana opens its own
-- connections and would not inherit a session setting, so a session-scoped
-- `SET` fixes your psql window and leaves every dashboard truncated — the worst
-- of both worlds, because now it looks correct when you check it by hand.
--
--   ALTER DATABASE tsdb SET timescaledb.enable_tiered_reads = true;
--
-- It takes effect for connections opened AFTER the statement, so restart Grafana
-- (or just wait for it to reconnect) before trusting a panel.
--
-- The block below sets it if tiering is available and you have opted in. It is a
-- DO block because ALTER DATABASE cannot take the database name from a variable
-- and we want it to be a no-op elsewhere.

DO $$
DECLARE
  v_available BOOLEAN;
  v_opted_in  BOOLEAN;
BEGIN
  v_available := EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'add_tiering_policy')
             AND EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'timescaledb_osm');
  v_opted_in  := COALESCE(cfg('enable_tiering'), 'false') = 'true';

  IF NOT v_available THEN
    RAISE NOTICE 'Tiering is not available here — nothing to do. The rest of the '
                 'workshop is unaffected.';
    RETURN;
  END IF;

  IF NOT v_opted_in THEN
    RAISE NOTICE 'Tiering IS available but you have not opted in. To apply the '
                 'policies above:';
    RAISE NOTICE '    UPDATE workshop_config SET value = ''true'' WHERE key = ''enable_tiering'';';
    RAISE NOTICE '    \\i sql/14_tiered_storage.sql';
    RETURN;
  END IF;

  EXECUTE format('ALTER DATABASE %I SET timescaledb.enable_tiered_reads = true',
                 current_database());
  RAISE NOTICE 'enable_tiered_reads set ON for database % (applies to NEW '
               'connections — restart Grafana).', current_database();
END $$;


-- ============================================================================
-- ## Check the ordering before touching anything
-- ============================================================================
-- Three policies now act on the same chunks, and they only make sense in one
-- order:
--
--   columnstore  7 days     compress in place, still local
--   tiering      182-728 d  move to object storage
--   retention    3 years    delete
--
-- Each threshold must exceed the one before it. Tier before compressing and you
-- ship uncompressed data to object storage — paying for storage you did not need
-- and losing the columnar layout that makes tiered reads tolerable. Set retention
-- shorter than tiering and you delete chunks on their way out, or drop tiered
-- chunks you are still paying to store.

DO $$
DECLARE
  v_columnstore_days INTEGER := cfg_int('columnstore_after_days');
  v_max_tier_days    INTEGER := 728;
  v_retention_days   INTEGER;
BEGIN
  -- EXTRACT(EPOCH ...) / 86400, NOT EXTRACT(DAY ...).
  --
  -- EXTRACT(DAY FROM ...) returns the DAY COMPONENT of an interval, not its total
  -- length. The retention policy is `INTERVAL '3 years'`, whose day component is
  -- ZERO — so the obvious version of this check reported "retention (0 days)" and
  -- refused to proceed. EPOCH is the only extraction that totals an interval.
  SELECT (EXTRACT(EPOCH FROM (j.config ->> 'drop_after')::INTERVAL) / 86400)::INTEGER
    INTO v_retention_days
    FROM timescaledb_information.jobs j
   WHERE j.proc_name = 'policy_retention'
     AND j.hypertable_name = 'power_generation';

  IF v_columnstore_days >= 182 THEN
    RAISE EXCEPTION 'columnstore_after_days (%) must be well below the 182-day '
                    'raw tiering threshold, or chunks tier uncompressed',
                    v_columnstore_days;
  END IF;

  IF v_retention_days IS NOT NULL AND v_retention_days <= v_max_tier_days THEN
    RAISE EXCEPTION 'retention (% days) must exceed the longest tiering threshold '
                    '(% days), or chunks are dropped on their way to object storage',
                    v_retention_days, v_max_tier_days;
  END IF;

  RAISE NOTICE 'Lifecycle ordering OK: columnstore % d < tiering 182-728 d < retention % d',
    v_columnstore_days, COALESCE(v_retention_days::TEXT, 'none');
END $$;


-- ============================================================================
-- ## The policies
-- ============================================================================
--
-- One `add_tiering_policy` per object. `if_not_exists => true` keeps this file
-- re-runnable, which matters because reset_demo.sh runs every step in order.
--
-- Wrapped in a DO block only so the whole set is skipped when tiering is absent
-- or you have not opted in. On a service with tiering enabled, each of these is
-- a one-line top-level statement in real use:
--
--   SELECT add_tiering_policy('wind_measurements', INTERVAL '26 weeks');
--
-- Note the interval units. The thresholds are expressed in WEEKS because that is
-- how the reasoning runs — "about six months of forensic depth", "a year of
-- interactive history", "two years of seasonal comparison" — and weeks keep that
-- legible where 182/364/728 days does not.

DO $$
DECLARE
  v_target  TEXT;
  v_after   INTERVAL;
  v_applied INTEGER := 0;
BEGIN
  IF NOT (EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'add_tiering_policy')
      AND EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'timescaledb_osm')
      AND COALESCE(cfg('enable_tiering'), 'false') = 'true') THEN
    RAISE NOTICE 'Skipping tiering policies (unavailable or not opted in).';
    RETURN;
  END IF;

  -- FOREACH over an array, not FOR ... IN SELECT. add_tiering_policy is a
  -- function rather than a transaction-managing procedure so this is less
  -- hazardous than the columnstore case in step 09, but the same habit applies:
  -- do not hold a portal open across catalog-modifying calls.
  FOREACH v_target IN ARRAY ARRAY[
      -- RAW — 26 weeks.
      -- Read by exactly one thing: the turbine dashboard's raw tier, which is
      -- selected only when $__interval_ms is under an hour, i.e. windows of
      -- roughly a week or less. In practice that is someone investigating a
      -- failure that happened recently. Six months of that depth is generous;
      -- beyond it, raw telemetry is forensic and a slower read is the right
      -- trade for 520 MB of block storage.
      'wind_measurements',
      'power_generation',
      -- HOURLY AGGREGATES — 52 weeks.
      -- The workhorses. Every "now" metric on the global, region and plant views
      -- reads an hourly aggregate, and the turbine view uses hourly for
      -- everything from a month to a year. A year of local residency covers the
      -- interactive range; past that you are doing year-on-year comparison, where
      -- a slower read is acceptable.
      'cagg_turbine_power_hourly',
      'cagg_wind_hourly',
      'cagg_plant_power_hourly',
      'cagg_regional_power_hourly',
      -- DAILY AGGREGATES — 104 weeks.
      -- The longest local residency for the smallest objects, because these are
      -- read across the WIDEST windows: the global view's seasonality panels plot
      -- two full years from cagg_wind_daily on every page load, and the turbine
      -- view's daily tier serves multi-year zooms. Tiering these at a year would
      -- put the most-viewed panels on the dashboard permanently in object storage
      -- to save 20 MB. Not worth it.
      'cagg_turbine_power_daily',
      'cagg_plant_power_daily',
      'cagg_regional_power_daily',
      'cagg_wind_daily'
    ] LOOP

    v_after := CASE
                 WHEN v_target LIKE '%_daily'  THEN INTERVAL '104 weeks'
                 WHEN v_target LIKE 'cagg_%'   THEN INTERVAL '52 weeks'
                 ELSE                               INTERVAL '26 weeks'
               END;

    BEGIN
      EXECUTE format('SELECT add_tiering_policy(%L, %L::INTERVAL, if_not_exists => true)',
                     v_target, v_after);
      v_applied := v_applied + 1;
      RAISE NOTICE '  % -> tiers after %', v_target, v_after;
    EXCEPTION WHEN OTHERS THEN
      -- Most likely cause: tiered storage is not actually enabled for the
      -- service even though the API is present. Report and carry on rather than
      -- failing the whole workshop over an optional feature.
      RAISE NOTICE '  % -> SKIPPED (%)', v_target, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'tiering: % policy/policies in place', v_applied;
END $$;


-- ============================================================================
-- ## Verify
-- ============================================================================
-- Tiering is ASYNCHRONOUS. add_tiering_policy freezes eligible chunks and queues
-- them; a background worker does the upload, and the policy job itself runs
-- hourly by default. So immediately after this file runs you should expect to see
-- policies registered and chunks QUEUED, not chunks tiered.

\echo ''
\echo '--- tiering policies registered ---'

-- Note BOTH names here, because neither is what you would guess and a wrong
-- guess silently returns zero rows rather than erroring:
--
--   proc_name    is 'policy_movechunk_to_s3', NOT anything containing "tier".
--                A filter of `proc_name LIKE '%tier%'` matches nothing.
--   config key   is 'move_after', NOT 'tier_after', matching the argument name
--                of add_tiering_policy(hypertable, move_after).
--
-- Verified by registering a policy on a scratch hypertable and reading the jobs
-- view back.
SELECT j.hypertable_name,
       j.config ->> 'move_after' AS move_after,
       j.schedule_interval,
       j.scheduled
  FROM timescaledb_information.jobs j
 WHERE j.proc_name = 'policy_movechunk_to_s3'
 ORDER BY j.hypertable_name;

-- If that returns nothing, either you did not opt in or tiering is unavailable —
-- both are reported above.

\echo ''
\echo '--- queued and tiered chunks (may be empty for a few minutes) ---'

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'timescaledb_osm') THEN
    -- These views only exist once the OSM extension is installed, so they cannot
    -- be referenced unguarded — a plain SELECT would fail to parse on a
    -- self-hosted instance and take the file down with it.
    RAISE NOTICE 'queued for tiering: %',
      (SELECT COUNT(*) FROM timescaledb_osm.chunks_queued_for_tiering);
    RAISE NOTICE 'already tiered:     %',
      (SELECT COUNT(*) FROM timescaledb_osm.tiered_chunks);
  ELSE
    RAISE NOTICE 'timescaledb_osm is not installed — no tiering views to read.';
  END IF;
END $$;

-- Watch it progress with:
--
--   SELECT COUNT(*) FROM timescaledb_osm.tiered_chunks;
--
-- and confirm the dashboards still see everything with tiered reads ON:
--
--   SET timescaledb.enable_tiered_reads = true;
--   SELECT COUNT(*), MIN(time)::date FROM power_generation;
--   SET timescaledb.enable_tiered_reads = false;
--   SELECT COUNT(*), MIN(time)::date FROM power_generation;   -- SMALLER, silently
--
-- That second pair is worth running once. It is the clearest demonstration in the
-- workshop of a correct-looking query returning incomplete data.


-- ============================================================================
-- ## Undoing it, and the re-runnability trap
-- ============================================================================
--
-- Removing the policies is one call each:
--
--   SELECT remove_tiering_policy('wind_measurements', if_exists => true);
--
-- but that only stops FUTURE tiering. Chunks already uploaded stay in object
-- storage until you bring them back individually:
--
--   SELECT untier_chunk(c) FROM show_chunks('power_generation') c;   -- expensive
--
-- The trap worth knowing about before you run this file: once a hypertable has
-- tiered chunks, SCHEMA CHANGES ON IT ARE RESTRICTED. Renaming, adding a column
-- without a default, and adding indexes are allowed; much else is not. That
-- collides directly with how this workshop is built — `02_schema.sql` opens with
-- `DROP TABLE ... CASCADE` and reset_demo.sh runs it on every reset.
--
-- Dropping the table does work, but the object-storage catalog entries want
-- clearing too, so the honest reset sequence with tiering in play is:
--
--   SELECT remove_tiering_policy('wind_measurements', if_exists => true);
--   SELECT remove_tiering_policy('power_generation',  if_exists => true);
--   SELECT disable_tiering('wind_measurements');   -- drops OSM catalog entries
--   SELECT disable_tiering('power_generation');
--   -- ...then the usual reset
--
-- This is the real reason tiering is opt-in here rather than on by default: it is
-- the one policy in the workshop that makes the environment harder to throw away,
-- and a workshop you cannot reset cleanly is worse than one without tiering.

\echo ''
\echo 'Step 14 complete.'
