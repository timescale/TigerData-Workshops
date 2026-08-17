-- ============================================================================
-- # Step 13 — One Query, Every Zoom Level: Tier Selection Across Caggs and Raw
-- ============================================================================
--
-- The turbine detail dashboard has a problem the other three dashboards do not.
-- The fleet, region and plant views each read a single tier, because each answers
-- a question at one granularity. The turbine view has to answer "show me this
-- machine" across four orders of magnitude of zoom:
--
--     zoom to 6 hours   -> you want every 15-minute sample; an hourly average
--                          hides the ramp you are trying to see
--     zoom to 30 days   -> 2,880 raw rows is more points than the panel has
--                          pixels, so you are paying to draw invisible detail
--     zoom to 2 years   -> 70,080 raw rows to render ~500 pixels of line, and
--                          the answer is identical to the daily rollup
--
-- Reading raw always is correct but wasteful. Reading the daily rollup always is
-- cheap but loses the detail that makes the panel worth having. What you want is
-- for the SAME query to read a DIFFERENT source depending on how far in the user
-- has zoomed — coarse data when zoomed out, raw samples when zoomed in.
--
-- The mechanism is a three-branch UNION ALL where each branch is gated on
-- Grafana's `$__interval_ms` — the width of one plotted point in milliseconds,
-- computed from the time range. Zooming out makes it grow, so those three
-- comparisons ARE the zoom level, expressed in SQL:
--
--     ... FROM cagg_turbine_power_daily  WHERE ... AND $__interval_ms >= 86400000
--     UNION ALL
--     ... FROM cagg_turbine_power_hourly WHERE ... AND $__interval_ms >= 3600000
--                                          AND $__interval_ms <  86400000
--     UNION ALL
--     ... FROM power_generation          WHERE ... AND $__interval_ms <  3600000
--
-- **This step creates nothing.** The union lives directly in each Grafana panel,
-- where you can read and edit it in the panel editor — there is no view and no
-- helper function to look up. The dashboard works whether or not you run this
-- file. What this file is for is proving the part you would otherwise have to
-- take on faith: that the two untaken branches are never read.
--
-- ## Prerequisites
--   Steps 01–08. Step 12 is not required.
--
-- ## What You'll Learn
--   - Selecting a data source at query time from a Grafana zoom level
--   - That constant-folding prunes UNION ALL branches out of the plan entirely
--   - Why real-time aggregation still touches the raw hypertable, and why that
--     is correct rather than a leak
--   - Which measurements can be pre-aggregated and which genuinely cannot
--
-- ============================================================================

-- (highlight and run this block if you followed an earlier version of this
--  workshop, which put the union behind a view and a helper function; the
--  dashboard no longer references either)
DROP VIEW     IF EXISTS v_turbine_history_tiers CASCADE;
DROP FUNCTION IF EXISTS history_tier(BIGINT) CASCADE;


-- ============================================================================
-- ## The tier rule
-- ============================================================================
--
-- The rule is one line of judgement: never read a source finer than the bucket
-- you are going to draw. If each pixel-bucket spans a day or more, the daily
-- rollup already has the answer. If it spans an hour or more, the hourly cagg
-- does. Below that, only the raw 15-minute samples carry new information.
--
-- The thresholds are the bucket widths of the tiers themselves, which is what
-- makes the rule self-evident rather than tuned:
--
--     >= 86,400,000 ms  (1 day)   -> cagg_turbine_power_daily
--     >=  3,600,000 ms  (1 hour)  -> cagg_turbine_power_hourly
--     <   3,600,000 ms            -> power_generation (raw, 15-minute)
--
-- The dashboard pins `maxDataPoints: 100` on every tier-driven panel, so
-- interval_ms = range_ms / 100. That is a design choice worth stating twice over.
--
-- Left unset, Grafana derives the interval from the panel's PIXEL WIDTH (~1,100
-- for a full-width panel), which at a 30-day range gives 39 minutes and therefore
-- the RAW tier — 2,880 points drawn into 1,100 pixels, most of them invisible. It
-- also means a narrow panel and a wide one disagree about which tier to use at the
-- same zoom, which is indefensible.
--
-- Asking for 100 points is a deliberate ceiling: a hundred points across a panel is
-- plenty for a trend line.
--
-- IMPORTANT — maxDataPoints does NOT change the tier thresholds. The gates below
-- are 3,600,000 ms and 86,400,000 ms because those are the tiers' own BUCKET
-- WIDTHS, one hour and one day, and they stay fixed whatever the panel asks for.
-- What maxDataPoints changes is the arithmetic that produces interval_ms in the
-- first place:
--
--     interval_ms = time_range_ms / maxDataPoints
--
-- so the same fixed thresholds are crossed at a different WINDOW SIZE. At 100
-- points a one-hour bucket is reached by a ~4.2-day window (100 x 1 hour) and a
-- one-day bucket by a 100-day window (100 x 1 day); at 400 points the same
-- thresholds needed a 16.7-day and a 400-day window respectively. Fewer requested
-- points means coarser buckets for a given window, which means a cheaper tier
-- sooner — with no change to the rule itself.
--
-- That is why the numbers in the table below moved and the gates did not.

SELECT range_label,
       interval_ms,
       CASE WHEN interval_ms >= 86400000 THEN 'daily'
            WHEN interval_ms >=  3600000 THEN 'hourly'
            ELSE                              'raw'
       END AS serves_from
  FROM (VALUES
          ('6 hours',       216000::BIGINT),
          ('24 hours',      864000),
          ('4 days',       3456000),
          ('7 days',       6048000),
          ('30 days',     25920000),
          ('90 days',     77760000),
          ('1 year',     315360000),
          ('5 years',   1576800000)
       ) AS z(range_label, interval_ms);

-- Expected:
--   range_label | interval_ms | serves_from
--  -------------+-------------+-------------
--   6 hours     |      216000 | raw
--   24 hours    |      864000 | raw
--   4 days      |     3456000 | raw
--   7 days      |     6048000 | hourly
--   30 days     |    25920000 | hourly
--   90 days     |    77760000 | hourly
--   1 year      |   315360000 | daily
--   5 years     |  1576800000 | daily
--
-- Note where the boundaries land: the default 30-day dashboard window is served by
-- the hourly cagg, you have to zoom inside four days to reach raw data, and
-- anything past three months is on the daily rollup. The tier an attendee sees
-- first is a cagg, and reaching raw takes deliberate zooming — the opposite of
-- what a naive dashboard does.


-- ============================================================================
-- ## The query, exactly as the dashboard sends it
-- ============================================================================
--
-- Below is the generation panel's query with Grafana's macros filled in by hand:
-- `$__interval_ms` becomes 25920000 (a 30-day window at 100 points), and
-- `$__timeFilter(col)` becomes a BETWEEN on that column. Everything else is
-- verbatim what you will find in the panel editor.
--
-- Three details in it are deliberate and worth pointing out:
--
--   * Each branch filters on ITS OWN time column — `day`, `bucket`, `time`.
--     That is what lets TimescaleDB exclude chunks per branch. A single outer
--     WHERE on the union's output column cannot do that.
--
--   * At the raw tier there is one sample per row, so min = max = the sample and
--     `readings` is 1. That is not a fudge; it is what the aggregate of a single
--     reading is.
--
--   * `NULLIF('$turbine','')::uuid` rather than `'$turbine'::uuid`. Before the
--     dashboard variable resolves, that string is empty, and casting '' to uuid
--     is an ERROR while NULL simply matches nothing. It also stays a constant,
--     so the index on turbine_id is still usable — unlike the `turbine_id::text
--     LIKE '$turbine'` form used on the plant dashboard, which cannot use it.

WITH tiers AS (
  -- A point spans a day or more, so the daily rollup already has the answer.
  SELECT day                      AS time,
         avg_power_kw             AS power_kw,
         avg_expected_power_kw    AS expected_kw,
         readings::BIGINT         AS readings
    FROM cagg_turbine_power_daily
   WHERE turbine_id = (SELECT turbine_id FROM turbines ORDER BY name LIMIT 1)
     AND day BETWEEN now() - INTERVAL '30 days' AND now()
     AND 25920000 >= 86400000
  UNION ALL
  -- An hour or more per point: the hourly rollup is as fine as the chart can show.
  SELECT bucket                   AS time,
         avg_power_kw             AS power_kw,
         avg_expected_power_kw    AS expected_kw,
         readings::BIGINT         AS readings
    FROM cagg_turbine_power_hourly
   WHERE turbine_id = (SELECT turbine_id FROM turbines ORDER BY name LIMIT 1)
     AND bucket BETWEEN now() - INTERVAL '30 days' AND now()
     AND 25920000 >= 3600000
     AND 25920000 <  86400000
  UNION ALL
  -- Finer than an hour — only the raw 15-minute samples carry new information.
  SELECT time                     AS time,
         power_kw,
         expected_power_kw        AS expected_kw,
         1::BIGINT                AS readings
    FROM power_generation
   WHERE turbine_id = (SELECT turbine_id FROM turbines ORDER BY name LIMIT 1)
     AND time BETWEEN now() - INTERVAL '30 days' AND now()
     AND 25920000 <  3600000
)
SELECT date_trunc('day', t.time)                       AS day,
       COUNT(*)                                        AS points,
       SUM(t.readings)                                 AS readings_behind_them,
       ROUND(AVG(t.power_kw)::numeric, 1)              AS avg_kw
  FROM tiers t
 GROUP BY 1
 ORDER BY 1
 LIMIT 5;

-- Expected: 24 points per day, each backed by 4 readings — i.e. the hourly tier.
--    day                    | points | readings_behind_them | avg_kw
--   ------------------------+--------+----------------------+--------
--    2026-07-05 00:00:00+00 |      3 |                   12 | 2037.0
--    2026-07-06 00:00:00+00 |     24 |                   96 | 1349.3
--    2026-07-07 00:00:00+00 |     24 |                   96 |  621.2
--    ...
--
-- Only the ratio matters: 4 readings per point is the hourly tier. The first row
-- is short because the window opens mid-day, and how short depends on the hour
-- you run this. The kW figures are weather and will differ from the above.
--
-- Now change 25920000 to 216000 in all five places and re-run. You get 96 points
-- per day, each backed by ONE reading, because the same query is now reading the
-- raw hypertable. Change it to 1576800000 and you get one point per day backed by
-- 96. Nothing else about the query is touched.


-- ============================================================================
-- ## The tiers must agree, and they do — on an aligned window
-- ============================================================================
--
-- A rollup is only trustworthy if reading it gives the same answer as reading
-- what it summarises. This is worth checking: the most common way to get a cagg
-- hierarchy wrong is AVG(AVG(...)), which silently weights a 4-reading bucket
-- the same as a 96-reading one.
--
-- The window MUST be day-aligned for the comparison to be meaningful. Compare
-- over `now() - 30 days` instead and the tiers disagree by a percent or two for
-- an uninteresting reason: the daily tier's first bucket starts at a midnight
-- that the raw window clipped mid-day, so the three are not summarising the same
-- rows. That is a property of the question, not a defect in the data.

\echo ''
\echo '--- same 14 whole days, read from each tier in turn ---'

WITH t   AS (SELECT turbine_id FROM turbines ORDER BY name LIMIT 1),
     win AS (SELECT date_trunc('day', now()) - INTERVAL '14 days' AS lo,
                    date_trunc('day', now())                     AS hi),
     all_tiers AS (
       SELECT 'daily'  AS tier, d.avg_power_kw AS power_kw, d.readings::BIGINT AS readings
         FROM cagg_turbine_power_daily d, t, win
        WHERE d.turbine_id = t.turbine_id AND d.day    >= win.lo AND d.day    < win.hi
       UNION ALL
       SELECT 'hourly', h.avg_power_kw, h.readings::BIGINT
         FROM cagg_turbine_power_hourly h, t, win
        WHERE h.turbine_id = t.turbine_id AND h.bucket >= win.lo AND h.bucket < win.hi
       UNION ALL
       SELECT 'raw', g.power_kw, 1::BIGINT
         FROM power_generation g, t, win
        WHERE g.turbine_id = t.turbine_id AND g.time   >= win.lo AND g.time   < win.hi
     )
SELECT tier,
       COUNT(*)                                                          AS buckets,
       SUM(readings)                                                     AS total_readings,
       ROUND(AVG(power_kw)::numeric, 3)                                  AS unweighted_avg_kw,
       ROUND((SUM(power_kw * readings) / SUM(readings))::numeric, 3)      AS weighted_avg_kw
  FROM all_tiers
 GROUP BY tier
 ORDER BY buckets;

-- Expected — the four value columns must MATCH ACROSS ALL THREE ROWS. The kW
-- figure itself is weather and will differ from the example below; that the three
-- tiers agree on it to three decimal places is the point.
--    tier  | buckets | total_readings | unweighted_avg_kw | weighted_avg_kw
--   -------+---------+----------------+-------------------+-----------------
--    daily |      14 |           1344 |          1036.127 |        1036.127
--    hourly|     336 |           1344 |          1036.127 |        1036.127
--    raw   |    1344 |           1344 |          1036.127 |        1036.127
--
-- Three things this proves at once:
--   * 1344 = 14 x 96, so no readings were lost or double-counted on the way up.
--   * weighted = unweighted here only because every bucket is full. The
--     weighting still matters — it is what keeps the numbers right at the edges
--     of the window, where a bucket is partial.
--   * The rollups carry `readings`, which is what makes the weighting possible
--     at all. A cagg that stores only AVG() cannot be correctly re-aggregated.


-- ============================================================================
-- ## Proof that the untaken branches are never read
-- ============================================================================
--
-- This is the part worth running interactively. The same query at three zoom
-- levels, and each plan touches exactly one tier. Look at the relation names:
-- `_materialized_hypertable_<n>` is a cagg's storage, `power_generation` is raw.
--
-- Reading three plans by hand gets old, so the block below does it for you: it
-- captures each plan, extracts the hypertables it touched, names them, and
-- ASSERTS that no tier reads another tier's materialization. If a future edit
-- makes the gates non-constant, this raises instead of quietly getting slower.

\echo ''
\echo '--- sources each tier actually touches ---'

DO $$
DECLARE
  v_turbine  UUID;
  v_label    TEXT;
  v_window   TEXT;
  v_ms       BIGINT;
  v_tier     TEXT;
  v_line     TEXT;
  v_ids      INTEGER[];
  v_sources  TEXT;
  v_unwanted TEXT;
  v_sql      TEXT;
BEGIN
  SELECT turbine_id INTO v_turbine FROM turbines ORDER BY name LIMIT 1;

  FOR v_label, v_window, v_ms IN
    SELECT * FROM (VALUES ('zoomed in ', '6 hours', 216000::BIGINT),
                          ('default   ', '30 days', 25920000::BIGINT),
                          ('zoomed out', '5 years', 1576800000::BIGINT)) v(a, b, c)
  LOOP
    v_tier := CASE WHEN v_ms >= 86400000 THEN 'daily'
                   WHEN v_ms >=  3600000 THEN 'hourly'
                   ELSE                       'raw' END;
    v_ids  := '{}';

    -- The same three-branch union the panels carry, with the macros filled in.
    v_sql := format($q$
      WITH tiers AS (
        SELECT day AS time, avg_power_kw FROM cagg_turbine_power_daily
         WHERE turbine_id = %1$L AND day    >= now() - INTERVAL %2$L
           AND %3$s >= 86400000
        UNION ALL
        SELECT bucket, avg_power_kw FROM cagg_turbine_power_hourly
         WHERE turbine_id = %1$L AND bucket >= now() - INTERVAL %2$L
           AND %3$s >= 3600000 AND %3$s < 86400000
        UNION ALL
        SELECT time, power_kw FROM power_generation
         WHERE turbine_id = %1$L AND time   >= now() - INTERVAL %2$L
           AND %3$s < 3600000
      )
      SELECT t.time, t.avg_power_kw FROM tiers t ORDER BY t.time$q$,
      v_turbine, v_window, v_ms);

    FOR v_line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || v_sql LOOP
      -- Chunk relations are named _hyper_<hypertable_id>_<chunk_id>_chunk.
      IF v_line ~ '_hyper_[0-9]+_' THEN
        v_ids := v_ids || ((regexp_match(v_line, '_hyper_([0-9]+)_'))[1])::INTEGER;
      END IF;
    END LOOP;

    -- Resolve ids to something a human recognises: a cagg's view name where the
    -- hypertable is a materialization, otherwise the raw table's own name.
    SELECT string_agg(DISTINCT COALESCE(ca.view_name, h.table_name), ', '
                      ORDER BY COALESCE(ca.view_name, h.table_name))
      INTO v_sources
      FROM unnest(v_ids) AS u(id)
      JOIN _timescaledb_catalog.hypertable h ON h.id = u.id
      LEFT JOIN timescaledb_information.continuous_aggregates ca
             ON ca.materialization_hypertable_name = h.table_name;

    RAISE NOTICE '% (% window) -> tier=%  reads: %', v_label, v_window, v_tier, v_sources;

    SELECT string_agg(DISTINCT ca.view_name, ', ')
      INTO v_unwanted
      FROM unnest(v_ids) AS u(id)
      JOIN _timescaledb_catalog.hypertable h ON h.id = u.id
      JOIN timescaledb_information.continuous_aggregates ca
             ON ca.materialization_hypertable_name = h.table_name
     WHERE ca.view_name <> 'cagg_turbine_power_' || v_tier;

    IF v_unwanted IS NOT NULL THEN
      RAISE EXCEPTION 'tier % should not read %  -- branch pruning is not happening',
        v_tier, v_unwanted;
    END IF;
  END LOOP;

  RAISE NOTICE 'OK: each tier reads only its own source (plus raw, for the '
               'real-time aggregation tail — see the note below).';
END $$;

-- Expected:
--   NOTICE:  zoomed in  (6 hours window) -> tier=raw     reads: power_generation
--   NOTICE:  default    (30 days window) -> tier=hourly  reads: cagg_turbine_power_hourly, power_generation
--   NOTICE:  zoomed out (5 years window) -> tier=daily   reads: cagg_turbine_power_daily, power_generation
--   NOTICE:  OK: each tier reads only its own source ...
--
-- Two things to understand about that output.
--
-- 1. The pruning is total, not a filter. The discarded branches do not appear as
--    a scan with a false condition — they are absent from the Append node.
--    PostgreSQL folded `25920000 >= 86400000` to `false` at plan time, proved the
--    branch could return nothing, and deleted it. Nothing about the unused tiers
--    is opened, locked, or read. This is also why the gates must compare against
--    CONSTANTS: the whole design rests on the comparison being decidable before
--    execution. Wrap the threshold in a volatile expression, or hide the rule
--    behind a function that is not marked IMMUTABLE, and all three branches get
--    scanned — silently, and slower than reading raw would have been.
--
-- 2. At the two cagg tiers you ALSO see power_generation, and that is correct
--    rather than a leak. The caggs are declared `materialized_only = false`, so
--    each is itself a union of materialised buckets plus a live aggregate over
--    rows too recent to be materialised. The daily tier reaches raw through two
--    hops of this, because it is hierarchical on the hourly cagg. That is the
--    cost of always-fresh aggregates; the alternative is `materialized_only =
--    true` and a dashboard that lags its refresh interval.


-- ============================================================================
-- ## The measurement that needs a different combination rule
-- ============================================================================
--
-- Worth running, because it is the clearest demonstration in the workshop of a
-- pre-aggregation that would be silently, confidently wrong — and of the fix.

\echo ''
\echo '--- what AVG() does to a bearing that crosses north ---'

-- Explicit samples rather than table data, because the failure has to be shown to
-- be believed and it depends entirely on WHERE the samples sit. `naive` is what a
-- cagg storing AVG(wind_direction_deg) would hold; `circular` is the vector mean.
SELECT c.case_name,
       c.bearings,
       ROUND(v.naive::numeric, 1)    AS naive_deg,
       ROUND(v.circular::numeric, 1) AS circular_deg,
       ROUND(LEAST(ABS(v.naive - v.circular),
                   360 - ABS(v.naive - v.circular))::numeric, 1) AS error_deg
  FROM (VALUES
          ('straddles north', ARRAY[350.0, 355.0, 5.0, 10.0]),
          ('due north',       ARRAY[359.0, 1.0]),
          ('south-westerly',  ARRAY[230.0, 240.0, 250.0, 260.0]),
          ('due south',       ARRAY[179.0, 181.0])
       ) AS c(case_name, bearings)
  CROSS JOIN LATERAL (
    SELECT AVG(b)                                            AS naive,
           MOD((DEGREES(ATAN2(AVG(SIN(RADIANS(b))),
                              AVG(COS(RADIANS(b))))) + 360.0)::numeric, 360.0)
                                                             AS circular
      FROM unnest(c.bearings) AS b
  ) v
 ORDER BY error_deg DESC;

-- Expected:
--    case_name       |        bearings         | naive_deg | circular_deg | error_deg
--   -----------------+-------------------------+-----------+--------------+-----------
--    straddles north | {350,355,5,10}          |     180.0 |          0.0 |     180.0
--    due north       | {359,1}                 |     180.0 |          0.0 |     180.0
--    south-westerly  | {230,240,250,260}       |     245.0 |        245.0 |       0.0
--    due south       | {179,181}               |     180.0 |        180.0 |       0.0
--
-- A wind blowing steadily from the north averages, arithmetically, to a wind from
-- the SOUTH — off by the maximum possible amount, on a value that looks entirely
-- reasonable in a table. The two south-facing cases are exactly right, which is
-- what makes the bug easy to ship: it is invisible until your data moves.


-- ============================================================================
-- ## So how DO you put a bearing in a continuous aggregate?
-- ============================================================================
--
-- The wrong conclusion from the above is "direction cannot be aggregated, read it
-- from raw". That was this workshop's first answer and it was lazy. The right
-- conclusion is narrower: an ANGLE cannot be averaged. Store something else.
--
-- Decompose each reading into its unit-vector components and keep the SUMS:
--
--     SUM(SIN(RADIANS(wind_direction_deg))) AS dir_sin_sum,
--     SUM(COS(RADIANS(wind_direction_deg))) AS dir_cos_sum,
--     COUNT(*)                              AS readings
--
-- then recover the bearing at read time:
--
--     MOD((DEGREES(ATAN2(dir_sin_sum, dir_cos_sum)) + 360.0)::numeric, 360.0)
--
-- Why this works where an average does not, in three parts:
--
--   1. SIN/COS/RADIANS/SUM are all IMMUTABLE and parallel-safe, so they are legal
--      in a continuous aggregate. SUM also has a combine function, so it partial-
--      aggregates properly.
--
--   2. SUMS ARE ADDITIVE. The daily aggregate just adds the 24 hourly component
--      sums — no weighting, nothing to get wrong — and lands on exactly the value
--      it would have got from the day's 96 raw readings. An angle would need the
--      circular machinery again at every level, and a mean of means would be wrong
--      at every level. (Store AVG of sin/cos instead of SUM and you are back to
--      needing reading-count weights; sums avoid the question entirely.)
--
--   3. It carries MORE information than an angle, not less. The resultant's
--      LENGTH divided by the reading count is the mean resultant length, 0..1: a
--      direct measure of how steady the direction was. That is the concentration
--      half of a wind rose, and it is unrecoverable from a stored average.
--
-- Step 08 does exactly this, so `v_wind_hourly` and `v_wind_daily` both expose
-- `wind_direction_deg` and `dir_consistency`, and the turbine dashboard's direction
-- panel is tier-selected like every other panel.
--
-- One guard matters. When a bucket's readings oppose each other the vectors cancel
-- and the resultant collapses to ~0 — at which point there IS no mean direction,
-- and ATAN2(0, 0) returns 0 in PostgreSQL, i.e. a confident northerly. The views
-- return NULL below a resultant of 1% of the readings.

\echo ''
\echo '--- the aggregate reproduces the raw circular mean exactly ---'

WITH t AS (SELECT turbine_id FROM turbines ORDER BY name LIMIT 1),
raw AS (
  SELECT date_trunc('day', m.time) AS d,
         MOD((DEGREES(ATAN2(SUM(SIN(RADIANS(m.wind_direction_deg))),
                            SUM(COS(RADIANS(m.wind_direction_deg))))) + 360.0)::numeric,
             360.0) AS raw_circular_deg,
         COUNT(*)   AS raw_readings
    FROM wind_measurements m, t
   WHERE m.turbine_id = t.turbine_id
     AND m.time >= date_trunc('day', now()) - INTERVAL '5 days'
     AND m.time <  date_trunc('day', now())
   GROUP BY 1)
SELECT r.d::date                                        AS day,
       r.raw_readings,
       v.readings                                       AS cagg_readings,
       ROUND(r.raw_circular_deg, 6)                     AS from_raw,
       ROUND(v.wind_direction_deg::numeric, 6)          AS from_daily_cagg,
       ROUND(ABS(r.raw_circular_deg - v.wind_direction_deg::numeric), 9) AS difference,
       ROUND(v.dir_consistency::numeric, 4)             AS consistency
  FROM raw r
  JOIN t ON true
  JOIN v_wind_daily v ON v.day = r.d AND v.turbine_id = t.turbine_id
 ORDER BY r.d;

-- Expected: `difference` is 0.000000000 on every row, and cagg_readings equals
-- raw_readings. The daily figure came from summing 24 hourly buckets, each of
-- which summed 4 raw readings — and it is bit-identical to computing the circular
-- mean over all 96 at once. That is the additivity claim, tested.
--
-- `consistency` near 1.0 says the wind held its direction all day. Drop it to a
-- northerly site and the naive average would break while this stays correct; the
-- workshop's own regions never cross north, which is why the demonstration above
-- has to use literals.


-- ============================================================================
-- ## Hand the data lifecycle back to its policies
-- ============================================================================
--
-- Two sets of policies were registered and then paused: the continuous-aggregate
-- REFRESH policies at the end of step 08, and the COLUMNSTORE policies at the end
-- of step 09. Both were stood down so that the bulk loading and explicit refreshes
-- in steps 10 through 12 could run without background workers competing for the
-- same chunks — which fails hard, with "deadlock detected" from a compression job
-- or "could not refresh ... due to a concurrent refresh" from a refresh job.
--
-- this workshop has finished writing, so both come back on here.
--
-- They will work through whatever is not yet columnar over the next few minutes —
-- mostly aggregate chunks, since the raw chunks were written straight into the
-- columnstore during the backfill. Watch it happen:
--
--   SELECT hypertable_name, total_chunks, number_compressed_chunks
--     FROM hypertable_columnstore_stats('cagg_turbine_power_hourly');
--
--   SELECT hypertable_name, last_run_status, total_successes, total_failures
--     FROM timescaledb_information.job_stats
--    WHERE proc_name = 'policy_compression'
--    ORDER BY hypertable_name;

SELECT proc_name, hypertable_name,
       alter_job(job_id, scheduled => true) IS NOT NULL AS resumed
  FROM timescaledb_information.jobs
 WHERE proc_name IN ('policy_compression',
                     'policy_refresh_continuous_aggregate')
   AND NOT scheduled
 ORDER BY proc_name, hypertable_name;


\echo ''
\echo 'Step 13 complete — nothing was created; the union lives in the dashboard.'
\echo 'this workshop is done, and the compression policies are running again.'
\echo 'Open wind-4-turbine and change the time range to watch the tier switch.'
