-- ============================================================================
-- # Wind Energy — Step 06: The Wind Model
-- ============================================================================
-- Where the data comes from. Every wind reading in this workshop is produced
-- by one function, wind_at(), which is a PURE FUNCTION of (turbine, timestamp).
--
-- That design choice does a surprising amount of work:
--
--   * Backfill and live generation are the SAME CODE PATH. The only difference
--     between "30 days of history" and "the last 15 minutes" is the window
--     passed to generate_series. There is no second implementation to keep in
--     sync, and no chance of a discontinuity where history meets live data.
--
--   * History is reproducible. Drop the tables, re-run the backfill, and you
--     get byte-identical wind readings. Debugging a dashboard against
--     shifting data is miserable; this makes it deterministic.
--
--   * It is IMMUTABLE, so PostgreSQL will inline it, use it in expressions,
--     and let continuous aggregates depend on it.
--
-- Randomness is added by the CALLER, never inside wind_at(). A function that
-- called random() could not be IMMUTABLE, and marking it IMMUTABLE anyway
-- would be a lie that PostgreSQL punishes in confusing ways (cached plans
-- returning the same "random" value for every row).
-- ============================================================================


-- ============================================================================
-- ## Setup: Drop Existing Objects
-- ============================================================================

DROP FUNCTION IF EXISTS advance_wind(TIMESTAMPTZ)                     CASCADE;
DROP FUNCTION IF EXISTS apply_wake(UUID, DOUBLE PRECISION)             CASCADE;
DROP FUNCTION IF EXISTS backfill_wind(INTEGER)                        CASCADE;
-- Both the old five-argument form and the current climate-aware one, so this
-- file is re-runnable across the change that added per-region climatology.
DROP FUNCTION IF EXISTS wind_at(UUID, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS wind_at(UUID, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN, TIMESTAMPTZ,
                               DOUBLE PRECISION, DOUBLE PRECISION, INTEGER,
                               DOUBLE PRECISION, DOUBLE PRECISION, INTEGER, DOUBLE PRECISION) CASCADE;
DROP TYPE     IF EXISTS wind_sample                                   CASCADE;


-- ============================================================================
-- ## The wind_sample composite type
-- ============================================================================
-- Returning a composite lets wind_at() be used as a table function in a
-- LATERAL join, so one call yields all three correlated values. Wind speed,
-- direction, and temperature are not independent — they share the same weather
-- system — so computing them together is both cheaper and more realistic than
-- three separate functions.

CREATE TYPE wind_sample AS (
  wind_speed_ms      DOUBLE PRECISION,
  wind_direction_deg DOUBLE PRECISION,
  temperature_c      DOUBLE PRECISION
);


-- ============================================================================
-- ## wind_at() — a deterministic climatology
-- ============================================================================
-- Five superimposed effects. The first two are the region's own climatology read
-- from the `regions` table; the rest are physics that applies everywhere.
--
--   1. REGIONAL BASE. Each region's annual mean wind, from
--      `regions.wind_base_ms`. Not derived from latitude — regional wind
--      resource comes from terrain, surface roughness and circulation, and two
--      regions at the same latitude routinely differ by 2 m/s or more.
--
--   2. SEASONAL CYCLE, per region, from `wind_seasonal_ms` and `wind_peak_doy`.
--      Both the size and the TIMING of the annual swing are regional facts:
--      the North Sea peaks in January with the Atlantic storm track, the
--      Southern Great Plains in April with the low-level jet, and the Deccan
--      Plateau in July with the southwest monsoon. The last two are in
--      antiphase with Europe, which is why a single global seasonal term
--      cannot represent this fleet at any amplitude.
--
--   3. DIURNAL CYCLE. Daytime solar heating drives convective mixing, which
--      drags faster air down to hub height. Peaks mid-afternoon in LOCAL solar
--      time, which we derive from longitude — so the wave sweeps around the
--      globe rather than every turbine peaking at once.
--
--   4. SYNOPTIC WEATHER. Passing depressions on roughly 4-day and 1.7-day
--      periods. This is the dominant source of short-term variance and the
--      reason output swings. Its phase is derived from LOCATION, not from
--      turbine identity, so neighbouring turbines share weather and distant
--      ones do not — see the long comment on the phase term below, which is
--      the subtlest part of the whole model.
--
--   5. STORMS. A sharply peaked oscillator that spikes past cut-out a handful
--      of times a year, so the shutdown cliff in the power curve appears.
--
-- Plus a small offshore bonus for the residual gustiness of open water. Most of
-- the offshore advantage is already in `wind_base_ms` — the North Sea's 9.5 m/s
-- against 6.6 on the North German Plain IS the roughness difference, measured
-- rather than modelled.
--
-- Temperature is handled the same way: mean, seasonal amplitude, peak day and
-- diurnal amplitude all come from `regions`. See the temperature expression at
-- the bottom for why all four are needed.

-- The seven climate arguments are the region's own climatology, passed IN rather
-- than looked up. That is deliberate and load-bearing: a function that reads a
-- table cannot be IMMUTABLE, and immutability is what makes backfill and live
-- generation the same code path and makes history reproducible. So the caller
-- joins `regions` and hands the numbers over.
--
-- They are plain scalars rather than a composite or the `regions` row type for a
-- boring but real reason: this function is evaluated once per turbine per sample
-- — nearly seven million times for a two-year backfill — and passing the row
-- type would copy each region's boundary POLYGON on every one of those calls.
CREATE OR REPLACE FUNCTION wind_at(
  p_turbine_id  UUID,
  p_lat         DOUBLE PRECISION,
  p_lon         DOUBLE PRECISION,
  p_is_offshore BOOLEAN,
  p_time        TIMESTAMPTZ,
  -- regions.wind_base_ms / wind_seasonal_ms / wind_peak_doy
  p_wind_base_ms       DOUBLE PRECISION,
  p_wind_seasonal_ms   DOUBLE PRECISION,
  p_wind_peak_doy      INTEGER,
  -- regions.temp_mean_c / temp_seasonal_amp_c / temp_peak_doy / temp_diurnal_amp_c
  p_temp_mean_c        DOUBLE PRECISION,
  p_temp_seasonal_amp_c DOUBLE PRECISION,
  p_temp_peak_doy      INTEGER,
  p_temp_diurnal_amp_c DOUBLE PRECISION
) RETURNS wind_sample
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  WITH t AS (
    SELECT
      -- Hours since the Unix epoch: a continuous clock for the synoptic waves.
      -- EXTRACT(EPOCH ...) is absolute, so it is timezone-independent.
      (EXTRACT(EPOCH FROM p_time) / 3600.0)::DOUBLE PRECISION   AS abs_hours,
      -- Day of year and clock time must be read in a FIXED zone. Extracting
      -- HOUR or DOY straight from a timestamptz uses the session TimeZone
      -- setting, which would make this function's output depend on who is
      -- calling it — it would be STABLE, not IMMUTABLE, and two sessions could
      -- generate different history. Normalising to UTC first fixes that.
      EXTRACT(DOY FROM (p_time AT TIME ZONE 'UTC'))::DOUBLE PRECISION
                                                                AS doy,
      -- Local solar time: UTC hour shifted by 15 degrees of longitude per hour.
      -- NOTE: mod() has no double-precision overload in PostgreSQL — only
      -- integer and numeric. EXTRACT already returns numeric, so we stay in
      -- numeric for the wrap and cast the result back to double precision.
      MOD(EXTRACT(HOUR   FROM (p_time AT TIME ZONE 'UTC'))
          + EXTRACT(MINUTE FROM (p_time AT TIME ZONE 'UTC')) / 60.0
          + (p_lon / 15.0)::numeric + 24.0,
          24.0)::DOUBLE PRECISION                               AS solar_hour,
      -- SPATIAL phase for the weather terms. This is the single most important
      -- line in the model.
      --
      -- The obvious implementation is to hash the turbine id for a per-turbine
      -- phase offset. That is wrong, and wrong in a way that is easy to miss:
      -- turbine ids are random UUIDs, so hashing them gives two turbines 200 m
      -- apart completely unrelated weather. The data looks plausible in a
      -- single-turbine chart and falls apart the moment you compare neighbours.
      --
      -- Weather is SPATIAL. So the phase is a smooth function of position: one
      -- full cycle per 55 degrees of longitude and 140 degrees of latitude,
      -- which is roughly the scale of a real synoptic system. Consequences:
      --   * turbines in the same farm (~0.1 deg apart) are nearly in phase and
      --     differ only by sensor noise, as they should;
      --   * turbines a few hundred km apart partially decorrelate;
      --   * turbines on different continents are independent.
      -- Step 11 measures exactly this and the relationship is visible.
      --
      -- Longitude dominating also gives the model a west-to-east travelling
      -- wave, which is the direction mid-latitude systems actually move.
      --
      -- A small identity-derived jitter (up to 0.2 rad) is added on top so that
      -- co-located turbines are not perfectly identical. md5 is IMMUTABLE and
      -- documented; the ('x' || hex)::bit(n)::int idiom turns 7 hex digits into
      -- a non-negative 28-bit integer.
      2 * pi() * (p_lon / 55.0 + p_lat / 140.0)
        + 0.2 * ((('x' || substr(md5(p_turbine_id::TEXT), 1, 7))::bit(28)::INTEGER
                 )::DOUBLE PRECISION / 268435455.0)             AS phase
  ),
  parts AS (
    SELECT
      t.*,
      -- 1. Regional base: the region's own annual mean, straight from
      -- `regions.wind_base_ms`. This used to be a Gaussian on latitude, which
      -- produced a smooth westerly-belt curve and was wrong in a specific way:
      -- it forced every region at the same latitude to have the same wind, so
      -- the Southern Great Plains and the Inner Mongolian Plateau came out
      -- nearly identical, and offshore vs onshore was the only differentiator
      -- the model had. Real regional means come from terrain, roughness and
      -- circulation, none of which is a function of |lat|.
      p_wind_base_ms                                            AS base_ms,
      -- 2. Seasonal, per region: amplitude and PHASE both read from `regions`.
      -- The phase is what latitude could never capture. cos() peaks at 1 when
      -- doy = wind_peak_doy, so each region's windiest season sits where its own
      -- climatology puts it — January in the North Sea, April on the Great
      -- Plains, July on the Deccan Plateau in the monsoon. Those last two are in
      -- antiphase with Europe, which is exactly the behaviour a single global
      -- seasonal term cannot produce at any amplitude.
      --
      -- No hemisphere factor: the peak day already encodes it. A southern-
      -- hemisphere region gets a December peak by having wind_peak_doy near 350,
      -- not by flipping a sign.
      p_wind_seasonal_ms
        * cos(2 * pi() * (t.doy - p_wind_peak_doy::DOUBLE PRECISION) / 365.0)
                                                                AS seasonal_ms,
      -- 3. Diurnal: +/- 0.9 m/s, peaking near 15:00 local solar time.
      0.9 * sin(2 * pi() * (t.solar_hour - 9.0) / 24.0)          AS diurnal_ms,
      -- 4. Synoptic: two waves, +/- 3.9 m/s combined. The dominant variance.
      2.6 * sin(2 * pi() * t.abs_hours / (24 * 4.0)  + t.phase)
        + 1.3 * sin(2 * pi() * t.abs_hours / (24 * 1.7) + t.phase * 1.7)
                                                                AS synoptic_ms,
      -- 4b. STORMS. Rare, violent, and the whole reason cut_out_ms exists.
      -- A 23-day oscillator raised to the 16th power is near zero almost all
      -- the time and spikes hard for a few hours: named-storm behaviour rather
      -- than a smooth wave. Without this, no generated reading ever reaches
      -- cut-out speed and the most interesting part of the power curve — the
      -- cliff to zero output in a gale — never appears in the data.
      -- The trailing -1.5710 makes this term ZERO-MEAN, and it matters more than
      -- it looks. GREATEST(0, sin(...))^16 is never negative, so without the
      -- correction the storm term adds a permanent positive bias to every
      -- reading — and `regions.wind_base_ms` then stops being the region's annual
      -- mean, which is what it claims to be and what the seeded values were taken
      -- from. The bias is exactly 16 x E[max(0,sin)^16] over a full cycle:
      --
      --   E[max(0,sin x)^16] = (1/2pi) * integral_0^pi sin^16 x dx
      --                      = (1/2) * C(16,8) / 2^16
      --                      = 0.098190
      --   bias               = 16 * 0.098190 = 1.5710 m/s
      --
      -- Subtracting it leaves the calm-weather baseline slightly BELOW the annual
      -- mean, with storms pulling the mean back up. That is not a fudge — it is
      -- the shape of a real wind distribution, which is right-skewed: the median
      -- wind at a site is genuinely lower than the mean.
      16.0 * power(GREATEST(0.0,
              sin(2 * pi() * t.abs_hours / (24 * 23.0) + t.phase * 2.3)), 16)
        - 1.5710                                                AS storm_ms,
      -- Offshore roughness bonus. Small now that `wind_base_ms` already carries
      -- most of the offshore advantage — this is the residual gustiness of open
      -- water, not the whole difference.
      CASE WHEN p_is_offshore THEN 0.4 ELSE 0.0 END              AS offshore_ms
    FROM t
  )
  SELECT ROW(
    -- Wind speed: clamp to a physically sensible band. GREATEST at 0 because
    -- the sum of the waves can go negative; LEAST at 34 because a hub-height
    -- reading above that is a hurricane, not a Tuesday.
    LEAST(34.0, GREATEST(0.0,
      base_ms + seasonal_ms + diurnal_ms + synoptic_ms
        + storm_ms + offshore_ms)),

    -- Direction: prevailing westerly (260 deg) in the mid-latitudes where the
    -- westerlies dominate, prevailing easterly (100 deg) in the trade-wind
    -- belt, with a slow 6-day rotation as systems track past.
    MOD(
      (
        (CASE WHEN ABS(p_lat) > 30 THEN 260.0 ELSE 100.0 END)
          + 45.0 * sin(2 * pi() * abs_hours / (24 * 6.0) + phase)
          + 360.0
      )::numeric,
      360.0)::DOUBLE PRECISION,

    -- Temperature: entirely the region's own climatology now. Three numbers from
    -- `regions`, and the separation between them is what makes the six regions
    -- read as genuinely different places rather than one curve shifted by
    -- latitude:
    --
    --   mean            where the whole curve sits (26 degC Deccan, 6 degC Inner Mongolia)
    --   seasonal_amp    how big the annual swing is (5.5 maritime, 17.0 continental)
    --   peak_doy        WHEN the warmest part of the year falls — mid-July inland,
    --                   but late August over the North Sea, because water lags,
    --                   and late April on the Deccan, because the monsoon then
    --                   cools it through midsummer
    --   diurnal_amp     how far it moves in a single day (1.2 over water,
    --                   8.0 over dry steppe)
    --
    -- The old version derived all of this from |lat| with two fixed constants,
    -- which put every region at the same latitude at the same temperature and
    -- gave all of them their maximum on the same day of the year.
    p_temp_mean_c
      + p_temp_seasonal_amp_c
        * cos(2 * pi() * (doy - p_temp_peak_doy::DOUBLE PRECISION) / 365.0)
      + p_temp_diurnal_amp_c * sin(2 * pi() * (solar_hour - 9.0) / 24.0)
  )::wind_sample
  FROM parts;
$$;

COMMENT ON FUNCTION wind_at IS
  'Deterministic wind/temperature climatology for a turbine at a given instant. '
  'Pure function of its arguments, so backfill and live generation share one code path.';


-- ============================================================================
-- ## Try it
-- ============================================================================
-- Two turbines, same instant, very different weather — offshore North Sea in
-- winter against southern India.

SELECT t.name,
       p.plant_name,
       p.region_name,
       ROUND(w.wind_speed_ms::numeric, 1)      AS wind_ms,
       ROUND(w.wind_direction_deg::numeric, 0) AS dir_deg,
       ROUND(w.temperature_c::numeric, 1)      AS temp_c,
       ROUND(power_from_wind_speed(w.wind_speed_ms, p.cut_in_ms, p.cut_out_ms,
                                   p.rotor_diameter_m, p.rated_capacity_kw)::numeric, 0)
                                               AS power_kw
  FROM turbines t
  JOIN plants p ON p.plant_id = t.plant_id
  JOIN regions r ON r.region_name = p.region_name
 CROSS JOIN LATERAL wind_at(t.turbine_id,
                            ST_Y(t.location::geometry),
                            ST_X(t.location::geometry),
                            p.is_offshore,
                            '2026-01-15 12:00:00+00'::timestamptz,
                            r.wind_base_ms, r.wind_seasonal_ms, r.wind_peak_doy,
                            r.temp_mean_c, r.temp_seasonal_amp_c,
                            r.temp_peak_doy, r.temp_diurnal_amp_c) AS w
 WHERE t.turbine_no = 1
   AND p.region_name IN ('North Sea', 'Deccan Plateau')
 ORDER BY p.region_name, t.name;

-- Run it twice — the numbers are identical, because wind_at() is deterministic.
-- Note ST_Y is latitude and ST_X is longitude. PostGIS stores points as (X, Y),
-- i.e. (longitude, latitude), which trips up nearly everyone at least once.


-- ============================================================================
-- ## apply_wake() — the plant-level physics
-- ============================================================================
-- Returns the fraction of free-stream wind speed a turbine actually sees, given
-- the current wind direction: 1.0 in clean air, less when upwind machines in the
-- same plant are in the way.
--
-- All the expensive work was done once in step 04. This function only has to
-- compare an angle, which is why it is cheap enough to call for every turbine at
-- every timestamp.
--
-- Two pieces of physics worth understanding:
--
-- WHICH neighbours count. A turbine is shaded when the wind blows FROM a
-- neighbour's direction, so the test is that the meteorological wind direction
-- falls within the wake's half-angle of the bearing to that neighbour. The
-- half-angle widens with distance because the wake spreads as it travels — which
-- is why a far-off turbine can still catch you if it is dead upwind, while a
-- close one 90 degrees away never will.
--
-- HOW multiple wakes combine. Not additively — two 20% deficits do not make 40%.
-- The industry standard is root-sum-square:
--
--     total_deficit = sqrt( Σ deficit_i² )
--
-- which reflects that wakes are momentum deficits combining in quadrature. It
-- also conveniently cannot exceed 1 as easily as a naive sum. We clamp at 0.7
-- anyway: a turbine in a genuinely catastrophic multi-wake position still sees
-- some wind, and real superposition models are gentler than this one at the
-- extremes.
--
-- STABLE, not IMMUTABLE: it reads turbine_neighbors, so its result depends on
-- table contents rather than on arguments alone. That is the honest declaration,
-- and it is why the wake step sits OUTSIDE the immutable wind_at() model.

CREATE OR REPLACE FUNCTION apply_wake(
  p_turbine_id        UUID,
  p_wind_direction_deg DOUBLE PRECISION
) RETURNS DOUBLE PRECISION
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
  SELECT GREATEST(0.3,
           1.0 - LEAST(0.7, COALESCE(SQRT(SUM(POWER(n.jensen_deficit, 2))), 0.0)))
    FROM turbine_neighbors n
   WHERE n.turbine_id = p_turbine_id
     -- The wind is coming from where this neighbour stands, within the spreading
     -- wake's half-angle. angular_diff_deg handles the 350/010 wrap-around.
     AND angular_diff_deg(p_wind_direction_deg, n.bearing_deg) <= n.wake_half_angle_deg;
$$;

COMMENT ON FUNCTION apply_wake IS
  'Fraction of free-stream wind a turbine sees after wakes from upwind machines in '
  'its own plant, for a given wind direction. 1.0 = clean air.';


-- ============================================================================
-- ## See the wake model work
-- ============================================================================
-- Sweep the wind through 360 degrees for one turbine and watch which directions
-- cost it output. The dips are its upwind neighbours.

SELECT dir                                                     AS wind_from_deg,
       ROUND(apply_wake(t.turbine_id, dir)::numeric, 3)         AS wake_factor,
       ROUND(((1 - apply_wake(t.turbine_id, dir)) * 100)::numeric, 1)
                                                               AS velocity_loss_pct,
       -- v^3 again: a modest velocity deficit is a large power deficit.
       ROUND(((1 - POWER(apply_wake(t.turbine_id, dir), 3)) * 100)::numeric, 1)
                                                               AS power_loss_pct,
       REPEAT('#', GREATEST(0, ROUND((1 - apply_wake(t.turbine_id, dir)) * 200)::int))
                                                               AS profile
  FROM turbines t
  CROSS JOIN generate_series(0, 350, 10) AS g(dir)
 WHERE t.name = (SELECT name FROM turbines ORDER BY name LIMIT 1)
 ORDER BY dir;

-- A turbine in the middle of the array shows several distinct dips — one per upwind
-- neighbour — separated by clean sectors. A corner turbine has far fewer, which is
-- exactly why the edges of a wind farm out-produce the middle. Step 11 measures that
-- directly.
--
-- NOTE WHERE THE DIPS ARE. The layout is STAGGERED (step 04), so the deepest dips are
-- NOT at the plant's grid bearing — they sit about 17 degrees either side of it, where
-- the diagonal neighbour lines up. Directly down the rows the near wake misses
-- entirely and only the row two back contributes. Measured on a 4x4 plant: 25.8% mean
-- power loss on-axis with an aligned grid, 0.0% once staggered, with 29% spikes at
-- +/-17 degrees instead. That trade — a broad moderate loss for two narrow sharp ones
-- — is the whole reason real wind farms are laid out this way.


-- ============================================================================
-- ## backfill_wind() — generate history
-- ============================================================================
-- One INSERT ... SELECT per target table over a CROSS JOIN of turbines and a
-- 15-minute time series. Still set-based — no row-by-row processing — but wrapped
-- in a loop over CHUNK-ALIGNED windows, one chunk interval per batch. The worker
-- reads that interval from the catalog rather than hardcoding it (7 days by
-- default), so changing it in step 03 changes the batching to match.
--
-- The loop is there because of the default window. 96 turbines x 730 days x 96
-- samples/day is 6.7 million rows in each hypertable, and the MATERIALIZED CTE
-- below has to hold a whole batch at once: run that as a single statement and
-- PostgreSQL either consumes a great deal of memory or spills the CTE to a temp
-- file, and either way the attendee stares at a silent psql prompt for minutes
-- with no idea whether it is working. A chunk at a time bounds the working set to
-- ~65,000 rows at the defaults and lets each batch report itself.
--
-- Aligning the batches to CHUNKS rather than to calendar months is what makes the
-- parallel path possible: two workers on disjoint chunk-aligned windows never touch
-- the same chunk, so they never contend for the ShareUpdateExclusiveLock that chunk
-- creation takes on the parent hypertable and holds until commit.
--
-- The batches tile the window exactly once. generate_series is inclusive at both
-- ends, so each batch stops one step SHORT of the next batch's start; get that
-- wrong and every chunk boundary gets a duplicated timestamp.
--
-- Batching does not change what is generated. wind_at() is a pure function of
-- (turbine, time), so a row's value does not depend on which batch produced it —
-- the whole thing is still one transaction and still reproducible.
--
-- The data-modifying CTE is the interesting part. `sample` is declared
-- MATERIALIZED, which forces PostgreSQL to evaluate it exactly once. That is
-- not a performance tweak — it is REQUIRED FOR CORRECTNESS here, because the
-- CTE calls random_normal(). Without MATERIALIZED, PostgreSQL is free to
-- inline the CTE into both consumers, evaluating the volatile function twice
-- and writing a different wind speed into wind_measurements than the one used
-- to compute power_generation.

-- The WORKER. Fills exactly the window it is handed, batching on chunk
-- boundaries inside it. Several of these can run CONCURRENTLY in separate
-- sessions as long as their windows are chunk-aligned and disjoint, which is what
-- backfill_wind_plan() below guarantees — two workers never touch the same chunk,
-- so they never contend for a chunk lock and never deadlock creating one.
CREATE OR REPLACE FUNCTION backfill_wind_window(p_from TIMESTAMPTZ,
                                               p_to   TIMESTAMPTZ)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
  v_days       INTEGER;
  v_from       TIMESTAMPTZ;
  v_to         TIMESTAMPTZ;
  v_step       INTERVAL;
  v_have       BIGINT;
  v_batch_from TIMESTAMPTZ;
  v_batch_to   TIMESTAMPTZ;
  v_batch_rows BIGINT;
  v_batches    INTEGER := 0;
  v_inserted   BIGINT  := 0;
  v_cold_before TIMESTAMPTZ;
  v_chunk_iv   INTERVAL;
  v_chunk_secs BIGINT;
BEGIN
  v_from := p_from;
  v_to   := p_to;
  IF v_from IS NULL OR v_to IS NULL THEN
    RAISE EXCEPTION 'backfill_wind_window: both bounds are required';
  END IF;
  IF v_from > v_to THEN
    RAISE EXCEPTION 'backfill_wind_window: empty window (% > %)', v_from, v_to;
  END IF;
  v_days := GREATEST(1, (EXTRACT(EPOCH FROM (v_to - v_from)) / 86400)::INTEGER);

  -- The SAME step advance_wind() uses, read from the same config key. This has
  -- to match, or the raw history changes resolution partway along: backfilled
  -- rows at one spacing and live rows at another. Step 13's tier selection
  -- depends on the raw table genuinely being finer-grained than the hourly
  -- aggregate — if backfill wrote hourly rows, zooming in would reveal no
  -- detail the cagg did not already have, and the raw tier would be pointless.
  v_step := make_interval(mins => COALESCE(cfg_int('wind_step_minutes'), 15));

  -- Anything older than this belongs in the columnstore anyway (step 09's policy
  -- uses the same config key), so those batches are written DIRECTLY in columnar
  -- form instead of landing in the rowstore and being converted afterwards.
  -- Measured from now(), NOT from the window end: with the range split across
  -- parallel workers, a worker holding only old chunks must still recognise them
  -- as cold, and the worker holding the newest chunks must still leave the hot
  -- window in the rowstore.
  v_cold_before := date_trunc('hour', now())
                   - make_interval(days => cfg_int('columnstore_after_days'));

  -- Batch size = the hypertable's own CHUNK INTERVAL, and batch boundaries are
  -- aligned to chunk boundaries. Read it rather than assuming: it is 7 days by
  -- default but step 03 could change it, and a hardcoded batch size that no longer
  -- matches would quietly reintroduce the problem this alignment solves.
  SELECT d.time_interval INTO v_chunk_iv
    FROM timescaledb_information.dimensions d
   WHERE d.hypertable_name = 'power_generation'
     AND d.column_name     = 'time';
  v_chunk_iv   := COALESCE(v_chunk_iv, INTERVAL '7 days');
  v_chunk_secs := EXTRACT(EPOCH FROM v_chunk_iv)::BIGINT;

  RAISE NOTICE 'backfill_wind_window: % .. % (% days) at % resolution for % turbines (~% rows per table), % batches of %',
    v_from, v_to, v_days, v_step,
    (SELECT COUNT(*) FROM turbines),
    (SELECT COUNT(*) FROM turbines)
      * (1 + (v_days::BIGINT * 1440) / GREATEST(1, EXTRACT(EPOCH FROM v_step)::BIGINT / 60)),
    CEIL(v_days::numeric / (v_chunk_secs / 86400.0))::INTEGER, v_chunk_iv;

  v_batch_from := v_from;
  WHILE v_batch_from <= v_to LOOP
    -- ALIGN EACH BATCH TO A CHUNK BOUNDARY.
    --
    -- Batching alone bounds memory, but batching on an arbitrary period (this was
    -- 1 month) straddles chunk boundaries: a batch writes the tail of one chunk
    -- and the head of the next, so no batch ever completes a chunk. That matters
    -- because of the direct-compress path below. Writing part of a chunk in
    -- columnar form and then coming back with more rows leaves the chunk PARTIALLY
    -- compressed, which needs compress_chunk(recompress => true) to tidy up and
    -- costs more than compressing it once.
    --
    -- Aligning means one batch fills exactly one chunk, so each chunk is written
    -- and compressed once, in a single pass, and is complete the moment the batch
    -- ends. TimescaleDB places chunk boundaries at multiples of the chunk interval
    -- since the epoch, so the next boundary is found by rounding the batch start
    -- down to a multiple and adding one interval.
    v_batch_to := LEAST(
      to_timestamp(((FLOOR(EXTRACT(EPOCH FROM v_batch_from) / v_chunk_secs) + 1)
                    * v_chunk_secs)::DOUBLE PRECISION) - v_step,
      v_to);

    -- DIRECT COMPRESS: write this batch straight into the columnstore when the
    -- whole batch is already past the hot window. Measured on a 180-day load,
    -- 96 turbines, 15-minute samples:
    --
    --   rowstore insert then convert   44 s   392 MB before conversion
    --   direct compress insert         37 s    47 MB, chunks already columnar
    --
    -- Two reasons it is worth it beyond the 8x disk figure. The load never
    -- materialises an uncompressed copy, so a two-year backfill does not need
    -- ~1.5 GB of transient space it will immediately throw away; and step 09 has
    -- nothing left to convert, so the conversion pass stops being a second full
    -- pass over the data.
    --
    -- The hot window is deliberately excluded. Those chunks stay in the rowstore
    -- because advance_wind() writes into them repeatedly, and 15-minute inserts
    -- land far more cheaply there — which is the same reason step 09's policy
    -- waits `columnstore_after_days` before converting anything.
    --
    -- set_config(..., true) is SET LOCAL: it lasts to the end of this
    -- transaction only, so this never changes the caller's session.
    -- ALREADY FILLED? SKIP IT. Batches are whole chunks, so a batch is either
    -- entirely present or entirely absent — which makes this a safe idempotency
    -- test rather than a partial-data guess. Two things depend on it: re-running
    -- step 07 by hand no longer duplicates history, and step 07 can run AFTER a
    -- parallel fill purely for its verification queries, generating nothing.
    SELECT COUNT(*) INTO v_have
      FROM wind_measurements
     WHERE time >= v_batch_from AND time <= v_batch_to
     LIMIT 1;
    IF v_have > 0 THEN
      RAISE NOTICE '  % .. %  ->  already present, skipped',
        v_batch_from::date, v_batch_to::date;
      v_batch_from := v_batch_to + v_step;
      CONTINUE;
    END IF;

    PERFORM set_config('timescaledb.enable_direct_compress_insert',
                       CASE WHEN v_batch_to < v_cold_before THEN 'on' ELSE 'off' END,
                       true);

  WITH free_stream AS MATERIALIZED (
    SELECT
      g.ts                                                   AS time,
      t.turbine_id,
      t.plant_id,
      p.region_name,
      p.cut_in_ms,
      p.cut_out_ms,
      p.rotor_diameter_m,
      p.rated_capacity_kw,
      -- Sensor imprecision: anemometers are accurate to a few percent, and a
      -- cup anemometer at hub height sees turbulence the climatology does not
      -- model. random_normal() is new in PostgreSQL 16 — no Box-Muller needed.
      GREATEST(0.0, w.wind_speed_ms + random_normal(0.0, 0.45))  AS free_wind_speed_ms,
      MOD((w.wind_direction_deg + random_normal(0.0, 8.0) + 360.0)::numeric, 360.0)
        ::DOUBLE PRECISION                                       AS wind_direction_deg,
      w.temperature_c + random_normal(0.0, 0.6)                  AS temperature_c
    FROM turbines t
    JOIN plants p ON p.plant_id = t.plant_id
    JOIN regions r ON r.region_name = p.region_name
    CROSS JOIN generate_series(v_batch_from, v_batch_to, v_step) AS g(ts)
    CROSS JOIN LATERAL wind_at(t.turbine_id,
                               ST_Y(t.location::geometry),
                               ST_X(t.location::geometry),
                               p.is_offshore,
                               g.ts,
                               r.wind_base_ms, r.wind_seasonal_ms, r.wind_peak_doy,
                               r.temp_mean_c, r.temp_seasonal_amp_c,
                               r.temp_peak_doy, r.temp_diurnal_amp_c) AS w
  ),
  waked AS (
    SELECT f.*,
           apply_wake(f.turbine_id, f.wind_direction_deg) AS wake_factor,
           -- Fault derate. Read from turbine_faults, so the generator applies the
           -- answer key without the telemetry ever referencing it.
           turbine_health(f.turbine_id, f.time)           AS health
      FROM free_stream f
  ),
  ins_measurements AS (
    INSERT INTO wind_measurements
      (time, turbine_id, plant_id, free_wind_speed_ms, wind_speed_ms,
       wind_direction_deg, temperature_c, source)
    SELECT time, turbine_id, plant_id,
           free_wind_speed_ms,
           free_wind_speed_ms * wake_factor,
           wind_direction_deg, temperature_c, 'backfill'
      FROM waked
    RETURNING 1
  )
  INSERT INTO power_generation
    (time, turbine_id, plant_id, region_name, power_kw, expected_power_kw,
     wind_speed_ms, wake_loss_pct)
  SELECT time,
         turbine_id,
         plant_id,
         region_name,
         -- ACTUAL: healthy output scaled by the fault derate.
         power_from_wind_speed(free_wind_speed_ms * wake_factor,
                               cut_in_ms, cut_out_ms,
                               rotor_diameter_m, rated_capacity_kw) * health,
         -- EXPECTED: what the same measured wind should have produced. Note the
         -- wake is NOT removed here — a turbine cannot be blamed for standing
         -- behind another one, so expected output is computed at the wind it
         -- actually saw. Wake loss is accounted separately in wake_loss_pct.
         power_from_wind_speed(free_wind_speed_ms * wake_factor,
                               cut_in_ms, cut_out_ms,
                               rotor_diameter_m, rated_capacity_kw),
         free_wind_speed_ms * wake_factor,
         -- Power lost relative to what this turbine would have made in
         -- undisturbed wind. Computed from the two power values rather than from
         -- the velocity deficit, because clipping at rated capacity and the
         -- cut-in/cut-out thresholds both change the answer: a turbine already
         -- pitch-limited at rated power loses NOTHING to a modest wake.
         CASE
           WHEN power_from_wind_speed(free_wind_speed_ms, cut_in_ms, cut_out_ms,
                                      rotor_diameter_m, rated_capacity_kw) > 0
             THEN 100.0 * (1 - power_from_wind_speed(free_wind_speed_ms * wake_factor,
                                                     cut_in_ms, cut_out_ms,
                                                     rotor_diameter_m, rated_capacity_kw)
                             / power_from_wind_speed(free_wind_speed_ms, cut_in_ms, cut_out_ms,
                                                     rotor_diameter_m, rated_capacity_kw))
           ELSE 0.0
         END
    FROM waked;

    GET DIAGNOSTICS v_batch_rows = ROW_COUNT;
    v_inserted := v_inserted + v_batch_rows;
    v_batches  := v_batches + 1;

    RAISE NOTICE '  % .. %  ->  % rows  %  (running total %)',
      v_batch_from::date, v_batch_to::date, v_batch_rows,
      CASE WHEN v_batch_to < v_cold_before THEN '[columnstore]' ELSE '[rowstore]' END,
      v_inserted;

    v_batch_from := v_batch_to + v_step;
  END LOOP;

  -- Leave the GUC as we found it for the rest of the transaction.
  PERFORM set_config('timescaledb.enable_direct_compress_insert', 'off', true);

  RAISE NOTICE 'backfill_wind_window: % batches (% to %), % rows into each of wind_measurements and power_generation',
    v_batches, v_from, v_to, v_inserted;

  RETURN v_inserted;
END;
$$;


-- ============================================================================
-- ## backfill_wind() — the whole history, serially
-- ============================================================================
-- Unchanged entry point: derive the window from `backfill_days` and hand it to a
-- single worker. This is what step 07 calls, and what an attendee running the
-- files by hand gets. Re-running it is now safe — the worker skips batches that
-- already hold data.
CREATE OR REPLACE FUNCTION backfill_wind(p_days INTEGER DEFAULT NULL)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
  v_days INTEGER := COALESCE(p_days, cfg_int('backfill_days'), 30);
  v_to   TIMESTAMPTZ := date_trunc('hour', now());
BEGIN
  RETURN backfill_wind_window(v_to - make_interval(days => v_days), v_to);
END;
$$;


-- ============================================================================
-- ## precreate_wind_chunks() — the one thing that makes a parallel load scale
-- ============================================================================
-- Creating a chunk takes ShareUpdateExclusiveLock on the PARENT hypertable, and
-- PostgreSQL holds a lock until the transaction commits. So a worker that creates
-- a chunk on its first insert holds that lock for its ENTIRE transaction, and
-- because SUE self-conflicts, every other worker queues behind it. The load
-- serialises completely even though the workers write disjoint chunks.
--
-- Measured, 20 turbines x 730 days (1.4M rows/hypertable) on 4 CPU:
--
--   chunks created by the workers   34.3 s serial -> 31.2 s at 4 jobs   1.09x
--   chunks PRE-CREATED here         34.3 s serial ->  9.3 s at 4 jobs   3.67x
--
-- With the chunks already in place the workers never take SUE at all: sampled
-- mid-run, all four backends were RUNNING with zero wait events and container
-- CPU sat at 384% of a 400% ceiling.
--
-- create_chunk() does this directly and is the documented way to do it:
--   https://www.tigerdata.com/docs/reference/timescaledb/hypertables/create_chunk
-- One cheap serial pass — 105 calls per hypertable for a two-year history — and it
-- must run BEFORE any worker starts.
--
-- An earlier version forced the chunks into existence by inserting one throwaway
-- row per boundary and deleting it again. That worked but left dead tuples and
-- inferred the boundaries implicitly. create_chunk() states the range explicitly,
-- creates the chunk with ZERO rows and zero dead tuples, and is idempotent —
-- verified on 2.29.0: a chunk that already exists comes back `created => false`
-- rather than raising, so no exception handling is needed.
--
-- Note this is NOT a read-side problem. The generator reads turbines, plants,
-- regions, turbine_neighbors and turbine_faults on every row, and all of those
-- take AccessShareLock, which is shared: all four workers held all five tables
-- simultaneously, all granted. Only the write side ever contended.
CREATE OR REPLACE FUNCTION precreate_wind_chunks(p_days INTEGER DEFAULT NULL)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_days  INTEGER     := COALESCE(p_days, cfg_int('backfill_days'), 30);
  v_to    TIMESTAMPTZ := date_trunc('hour', now());
  v_from  TIMESTAMPTZ;
  v_secs  BIGINT;
  v_edge  TIMESTAMPTZ;
  v_ht    TEXT;
  v_made  INTEGER := 0;
  v_exist INTEGER := 0;
  v_new   BOOLEAN;
BEGIN
  v_from := v_to - make_interval(days => v_days);

  -- Read the interval rather than assuming 7 days: step 03 could change it, and a
  -- boundary that disagrees with the hypertable's own is worse than no
  -- pre-creation at all — it would leave the workers creating chunks anyway.
  SELECT EXTRACT(EPOCH FROM d.time_interval)::BIGINT INTO v_secs
    FROM timescaledb_information.dimensions d
   WHERE d.hypertable_name = 'power_generation' AND d.column_name = 'time';
  v_secs := COALESCE(v_secs, EXTRACT(EPOCH FROM INTERVAL '7 days')::BIGINT);

  FOREACH v_ht IN ARRAY ARRAY['wind_measurements', 'power_generation'] LOOP
    -- TimescaleDB places boundaries at multiples of the interval SINCE THE EPOCH,
    -- so round the window start down to one. Handing create_chunk() a range that
    -- is not on a real boundary would create a chunk the inserts then do not use.
    v_edge := to_timestamp((FLOOR(EXTRACT(EPOCH FROM v_from) / v_secs) * v_secs)::DOUBLE PRECISION);

    WHILE v_edge < v_to LOOP
      -- Bounds as epoch MICROSECONDS, which is what the `slices` argument takes
      -- for a timestamp dimension. ISO strings are also accepted, but integers
      -- avoid any question of how the string's timezone is interpreted.
      SELECT (_timescaledb_functions.create_chunk(
                v_ht::regclass,
                jsonb_build_object(
                  'time',
                  jsonb_build_array(
                    (EXTRACT(EPOCH FROM v_edge) * 1000000)::BIGINT,
                    (EXTRACT(EPOCH FROM v_edge + make_interval(secs => v_secs)) * 1000000)::BIGINT
                  )))).created
        INTO v_new;

      -- create_chunk() is idempotent: an existing chunk returns created => false
      -- rather than raising, so re-running this is free and needs no exception
      -- handler. Verified on 2.29.0.
      IF v_new THEN v_made := v_made + 1; ELSE v_exist := v_exist + 1; END IF;

      v_edge := v_edge + make_interval(secs => v_secs);
    END LOOP;
  END LOOP;

  RAISE NOTICE 'precreate_wind_chunks: % chunk(s) created, % already present, across both hypertables',
    v_made, v_exist;
  RETURN v_made;
END;
$$;


-- ============================================================================
-- ## backfill_wind_plan() — split the history into parallel-safe windows
-- ============================================================================
-- Returns one row per worker: a CHUNK-ALIGNED, disjoint, contiguous window.
-- reset_demo.sh reads this and runs one psql session per row, concurrently.
--
-- Why the split has to live here rather than in the shell: the boundaries must
-- match the hypertable's real chunk interval, which is a property of the
-- database (step 03 can change it), and getting them wrong is not a visible
-- error — misaligned windows mean two workers writing into ONE chunk, which
-- reintroduces exactly the partial-compression and lock contention that
-- chunk-aligned batching exists to avoid. The shell only orchestrates: it runs
-- the windows this function hands it and never computes a timestamp itself.
--
-- TimescaleDB places chunk boundaries at multiples of the chunk interval since
-- the epoch, so every boundary here is derived that way and never by dividing
-- the requested range into equal spans.
CREATE OR REPLACE FUNCTION backfill_wind_plan(p_days    INTEGER DEFAULT NULL,
                                              p_workers INTEGER DEFAULT 1)
RETURNS TABLE (worker INTEGER, win_from TIMESTAMPTZ, win_to TIMESTAMPTZ)
LANGUAGE plpgsql
AS $$
DECLARE
  v_days       INTEGER := COALESCE(p_days, cfg_int('backfill_days'), 30);
  v_workers    INTEGER := GREATEST(1, COALESCE(p_workers, 1));
  v_to         TIMESTAMPTZ := date_trunc('hour', now());
  v_from       TIMESTAMPTZ;
  v_step       INTERVAL;
  v_chunk_secs BIGINT;
  v_first_edge TIMESTAMPTZ;
  v_edges      TIMESTAMPTZ[] := '{}';
  v_e          TIMESTAMPTZ;
  v_n          INTEGER;
  v_per        INTEGER;
  v_i          INTEGER;
  v_lo         INTEGER;
  v_hi         INTEGER;
BEGIN
  v_from := v_to - make_interval(days => v_days);
  v_step := make_interval(mins => COALESCE(cfg_int('wind_step_minutes'), 15));

  SELECT EXTRACT(EPOCH FROM d.time_interval)::BIGINT INTO v_chunk_secs
    FROM timescaledb_information.dimensions d
   WHERE d.hypertable_name = 'power_generation' AND d.column_name = 'time';
  v_chunk_secs := COALESCE(v_chunk_secs, EXTRACT(EPOCH FROM INTERVAL '7 days')::BIGINT);

  -- Every chunk boundary strictly inside the range, found the same way the
  -- worker finds its batch ends.
  v_first_edge := to_timestamp(((FLOOR(EXTRACT(EPOCH FROM v_from) / v_chunk_secs) + 1)
                                * v_chunk_secs)::DOUBLE PRECISION);
  v_e := v_first_edge;
  WHILE v_e <= v_to LOOP
    v_edges := v_edges || v_e;
    v_e := v_e + make_interval(secs => v_chunk_secs);
  END LOOP;

  -- Chunks in the range = interior boundaries + 1. Never hand out more workers
  -- than there are chunks, or a worker gets an empty window.
  v_n := array_length(v_edges, 1);
  v_n := COALESCE(v_n, 0) + 1;
  v_workers := LEAST(v_workers, v_n);
  v_per     := CEIL(v_n::numeric / v_workers)::INTEGER;

  FOR v_i IN 1 .. v_workers LOOP
    v_lo := (v_i - 1) * v_per;            -- 0-based index of this worker's first chunk
    v_hi := LEAST(v_i * v_per, v_n) - 1;  -- ... and its last
    EXIT WHEN v_lo > v_hi;
    worker   := v_i;
    win_from := CASE WHEN v_lo = 0 THEN v_from ELSE v_edges[v_lo] END;
    -- End one step short of the next boundary so the windows do not overlap on
    -- the boundary timestamp itself, which would put one row in two workers.
    win_to   := CASE WHEN v_hi = v_n - 1 THEN v_to ELSE v_edges[v_hi + 1] - v_step END;
    RETURN NEXT;
  END LOOP;
END;
$$;


-- ============================================================================
-- ## advance_wind() — generate the next slice, on demand
-- ============================================================================
-- This is what you re-run during the workshop to make new data appear.
--
-- Idempotency comes from deriving the window from MAX(time) already present,
-- NOT from ON CONFLICT. Run it twice in a row and the second call finds nothing
-- left to generate and inserts zero rows.
--
-- Why not a unique constraint plus upsert? Two reasons. A unique index on a
-- hypertable must include the partitioning column, and upserts against
-- columnstore chunks add complexity for no benefit. Deriving the window is
-- simpler and cannot produce a duplicate in the first place.

CREATE OR REPLACE FUNCTION advance_wind(p_until TIMESTAMPTZ DEFAULT now())
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
  v_step     INTERVAL;
  v_last     TIMESTAMPTZ;
  v_from     TIMESTAMPTZ;
  v_inserted BIGINT;
BEGIN
  v_step := make_interval(mins => COALESCE(cfg_int('wind_step_minutes'), 15));

  -- Resume from the newest reading we already hold. If the table is empty
  -- (backfill not yet run), generate just the last hour so the dashboards have
  -- something to draw.
  SELECT MAX(time) INTO v_last FROM wind_measurements;
  v_from := COALESCE(v_last, p_until - INTERVAL '1 hour') + v_step;

  IF v_from > p_until THEN
    RAISE NOTICE 'advance_wind: already current (latest reading %), nothing to generate.', v_last;
    RETURN 0;
  END IF;

  WITH free_stream AS MATERIALIZED (
    SELECT
      g.ts                                                   AS time,
      t.turbine_id,
      t.plant_id,
      p.region_name,
      p.cut_in_ms,
      p.cut_out_ms,
      p.rotor_diameter_m,
      p.rated_capacity_kw,
      GREATEST(0.0, w.wind_speed_ms + random_normal(0.0, 0.45))  AS free_wind_speed_ms,
      MOD((w.wind_direction_deg + random_normal(0.0, 8.0) + 360.0)::numeric, 360.0)
        ::DOUBLE PRECISION                                       AS wind_direction_deg,
      w.temperature_c + random_normal(0.0, 0.6)                  AS temperature_c
    FROM turbines t
    JOIN plants p ON p.plant_id = t.plant_id
    JOIN regions r ON r.region_name = p.region_name
    CROSS JOIN generate_series(v_from, p_until, v_step) AS g(ts)
    CROSS JOIN LATERAL wind_at(t.turbine_id,
                               ST_Y(t.location::geometry),
                               ST_X(t.location::geometry),
                               p.is_offshore,
                               g.ts,
                               r.wind_base_ms, r.wind_seasonal_ms, r.wind_peak_doy,
                               r.temp_mean_c, r.temp_seasonal_amp_c,
                               r.temp_peak_doy, r.temp_diurnal_amp_c) AS w
  ),
  waked AS (
    SELECT f.*,
           apply_wake(f.turbine_id, f.wind_direction_deg) AS wake_factor,
           turbine_health(f.turbine_id, f.time)           AS health
      FROM free_stream f
  ),
  ins_measurements AS (
    INSERT INTO wind_measurements
      (time, turbine_id, plant_id, free_wind_speed_ms, wind_speed_ms,
       wind_direction_deg, temperature_c, source)
    SELECT time, turbine_id, plant_id,
           free_wind_speed_ms,
           free_wind_speed_ms * wake_factor,
           wind_direction_deg, temperature_c, 'model_live'
      FROM waked
    RETURNING 1
  )
  INSERT INTO power_generation
    (time, turbine_id, plant_id, region_name, power_kw, expected_power_kw,
     wind_speed_ms, wake_loss_pct)
  SELECT time,
         turbine_id,
         plant_id,
         region_name,
         power_from_wind_speed(free_wind_speed_ms * wake_factor, cut_in_ms, cut_out_ms,
                               rotor_diameter_m, rated_capacity_kw) * health,
         power_from_wind_speed(free_wind_speed_ms * wake_factor, cut_in_ms, cut_out_ms,
                               rotor_diameter_m, rated_capacity_kw),
         free_wind_speed_ms * wake_factor,
         CASE
           WHEN power_from_wind_speed(free_wind_speed_ms, cut_in_ms, cut_out_ms,
                                      rotor_diameter_m, rated_capacity_kw) > 0
             THEN 100.0 * (1 - power_from_wind_speed(free_wind_speed_ms * wake_factor,
                                                     cut_in_ms, cut_out_ms,
                                                     rotor_diameter_m, rated_capacity_kw)
                             / power_from_wind_speed(free_wind_speed_ms, cut_in_ms, cut_out_ms,
                                                     rotor_diameter_m, rated_capacity_kw))
           ELSE 0.0
         END
    FROM waked;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  RAISE NOTICE 'advance_wind: % to %, % rows into each hypertable.', v_from, p_until, v_inserted;

  RETURN v_inserted;
END;
$$;

COMMENT ON FUNCTION advance_wind IS
  'Generate wind measurements and derived power from the newest existing reading up to p_until. '
  'Safe to re-run: a second call with no elapsed time inserts nothing.';
