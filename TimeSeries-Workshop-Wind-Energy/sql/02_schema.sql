-- ============================================================================
-- # Wind Energy — Step 02: Relational Schema
-- ============================================================================
-- The static, relational half of the model. Four tables, and the hierarchy
-- matters because it mirrors how the industry is actually organised:
--
--   regions            named geographic areas with POLYGON boundaries, for
--                      portfolio reporting and map overlays
--   plants             a wind farm — the unit that gets financed, permitted,
--                      connected to the grid, and reported on
--   turbines           individual machines, laid out in a GRID around their
--                      plant's centre
--   turbine_neighbors  precomputed pairwise geometry inside each plant, so the
--                      generator can work out wake losses cheaply
--
-- Nobody operates loose turbines. They are built in plants of 5 to 200 machines
-- sharing one substation, one grid connection, one maintenance crew and one
-- power purchase agreement. Modelling that hierarchy is not decoration: plant is
-- the level at which almost every real question is asked.
--
-- This is still the "fixed location" pattern. A turbine's coordinates are set
-- when the foundation is poured, which means location belongs on the dimension
-- tables, a single GiST index serves every spatial query, and both region
-- membership and wake geometry can be computed ONCE at seed time. the Fleet Tracking workshop inverts
-- all of that.
-- ============================================================================


-- ============================================================================
-- ## Setup: Drop Existing Objects
-- ============================================================================
-- (highlight and run this block to reset this workshop of the workshop)

DROP MATERIALIZED VIEW IF EXISTS cagg_regional_power_hourly CASCADE;
DROP MATERIALIZED VIEW IF EXISTS cagg_plant_power_hourly    CASCADE;
DROP MATERIALIZED VIEW IF EXISTS cagg_turbine_power_daily   CASCADE;
DROP MATERIALIZED VIEW IF EXISTS cagg_turbine_power_hourly  CASCADE;
DROP TABLE IF EXISTS power_generation  CASCADE;
DROP TABLE IF EXISTS wind_measurements CASCADE;
DROP TABLE IF EXISTS turbine_faults    CASCADE;
DROP TABLE IF EXISTS turbine_neighbors CASCADE;
DROP TABLE IF EXISTS turbines          CASCADE;
DROP TABLE IF EXISTS plants            CASCADE;
DROP TABLE IF EXISTS regions           CASCADE;


-- ============================================================================
-- ## Regions
-- ============================================================================
-- Real geographic areas, named the way an atlas would name them, each with a
-- polygon boundary. Three jobs:
--
--   1. Portfolio reporting — group plants the way a fleet owner thinks about
--      them, with labels a human recognises.
--   2. Map overlay — the polygon is exported to GeoJSON in step 04 so the
--      Grafana geomap can draw region outlines under the turbine markers.
--   3. Point-in-polygon assignment — the spatial join that turns raw
--      coordinates into a business dimension.
--
-- `prevailing_wind_deg` is a genuine physical property of a region, not an
-- attribute we invented for convenience. It drives two things: the wind model's
-- direction output, and — much more interestingly — the ORIENTATION OF EVERY
-- TURBINE GRID. Real developers rotate their rows so the wide spacing runs along
-- the prevailing wind and the tight spacing runs across it.

-- The climate columns are the region's OWN seasonality, and they exist because
-- latitude alone gets this badly wrong. Two regions can sit at the same latitude
-- and have opposite annual cycles: the Southern Great Plains peak in spring, the
-- Inner Mongolian Plateau in spring too but with a temperature range three times
-- wider, and the Deccan Plateau — far to the south — peaks in the middle of the
-- monsoon while northern regions are at their calmest.
--
-- Storing them per region rather than deriving them from `lat` means the model
-- takes real climatology as INPUT instead of pretending to derive it, and it is
-- what makes a 2-year history show six genuinely different annual cycles rather
-- than one curve scaled six ways. Every one is a number you could look up.

CREATE TABLE regions (
  region_name         TEXT                    PRIMARY KEY,
  country             TEXT                    NOT NULL,
  boundary            GEOMETRY(Polygon, 4326) NOT NULL,
  prevailing_wind_deg DOUBLE PRECISION        NOT NULL,   -- degrees, wind comes FROM
  is_offshore         BOOLEAN                 NOT NULL DEFAULT false,

  -- Wind climatology at hub height.
  wind_base_ms        DOUBLE PRECISION        NOT NULL,   -- m/s, annual mean, undisturbed
  wind_seasonal_ms    DOUBLE PRECISION        NOT NULL,   -- m/s, +/- swing over the year
  wind_peak_doy       INTEGER                 NOT NULL,   -- day of year of the windiest season

  -- Temperature climatology. Separating the seasonal and diurnal amplitudes
  -- matters: a maritime region has a small annual swing AND a tiny daily one,
  -- while a dry continental plateau can have a moderate annual swing and a
  -- daily swing nearly as large.
  temp_mean_c         DOUBLE PRECISION        NOT NULL,   -- degC, annual mean
  temp_seasonal_amp_c DOUBLE PRECISION        NOT NULL,   -- degC, +/- summer vs winter
  temp_peak_doy       INTEGER                 NOT NULL,   -- day of year of the warmest
  temp_diurnal_amp_c  DOUBLE PRECISION        NOT NULL,   -- degC, +/- afternoon vs dawn

  CONSTRAINT regions_boundary_valid  CHECK (ST_IsValid(boundary)),
  CONSTRAINT regions_wind_dir_range  CHECK (prevailing_wind_deg >= 0 AND prevailing_wind_deg < 360),
  -- A seasonal swing wider than the mean would drive the annual minimum below
  -- zero, which is not a wind speed. Catch it here rather than clamping later.
  CONSTRAINT regions_wind_swing_sane  CHECK (wind_seasonal_ms >= 0
                                         AND wind_seasonal_ms < wind_base_ms),
  CONSTRAINT regions_wind_peak_doy    CHECK (wind_peak_doy BETWEEN 1 AND 366),
  CONSTRAINT regions_temp_peak_doy    CHECK (temp_peak_doy BETWEEN 1 AND 366),
  CONSTRAINT regions_temp_amps_sane   CHECK (temp_seasonal_amp_c >= 0
                                         AND temp_diurnal_amp_c  >= 0)
);

CREATE INDEX idx_regions_boundary ON regions USING GIST (boundary);


-- ============================================================================
-- ## Plants
-- ============================================================================
-- A wind farm. The turbine SPECIFICATION lives here rather than on individual
-- turbines, because a plant is procured as a single order — every machine in it
-- is the same model. Denormalising the model onto each turbine would just be 8
-- identical copies waiting to drift apart.
--
-- `center_location` is the site centroid. Step 04 lays the turbines out around
-- it on a grid using ST_Project, which walks a real geodesic distance along a
-- bearing rather than doing arithmetic on degrees.
--
-- `grid_bearing_deg` is the axis along which rows are spaced at the WIDE
-- (downwind) interval — set to the region's prevailing wind direction, which is
-- exactly what a developer would do.

CREATE TABLE plants (
  plant_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_name            TEXT NOT NULL UNIQUE,          -- e.g. 'Sweetwater_0101'
  site_name             TEXT NOT NULL,                 -- nearest town or feature
  operator              TEXT NOT NULL,
  region_name           TEXT NOT NULL REFERENCES regions (region_name),
  center_location       GEOGRAPHY(Point, 4326) NOT NULL,
  grid_bearing_deg      DOUBLE PRECISION NOT NULL,     -- downwind axis of the layout
  turbine_count         INTEGER NOT NULL,
  -- Turbine specification, shared by every machine on site.
  model                 TEXT NOT NULL,
  hub_height_m          DOUBLE PRECISION NOT NULL,
  rotor_diameter_m      DOUBLE PRECISION NOT NULL,
  rated_capacity_kw     DOUBLE PRECISION NOT NULL,
  cut_in_ms             DOUBLE PRECISION NOT NULL,
  cut_out_ms            DOUBLE PRECISION NOT NULL,
  -- Layout spacing, in metres, derived from rotor diameter at seed time.
  spacing_crosswind_m   DOUBLE PRECISION NOT NULL,
  spacing_downwind_m    DOUBLE PRECISION NOT NULL,
  is_offshore           BOOLEAN NOT NULL DEFAULT false,
  commissioned_at       DATE NOT NULL,
  CONSTRAINT plants_cutout_above_cutin CHECK (cut_out_ms > cut_in_ms),
  CONSTRAINT plants_turbine_count_pos  CHECK (turbine_count > 0)
);

CREATE INDEX idx_plants_center ON plants USING GIST (center_location);
CREATE INDEX idx_plants_region ON plants (region_name);

-- Plant nameplate capacity, the number that appears in press releases.
CREATE OR REPLACE VIEW v_plant_capacity AS
SELECT p.plant_id,
       p.plant_name,
       p.region_name,
       p.operator,
       p.model,
       p.turbine_count,
       ROUND((p.turbine_count * p.rated_capacity_kw / 1000.0)::numeric, 1) AS nameplate_mw,
       p.commissioned_at
  FROM plants p;


-- ============================================================================
-- ## Turbines
-- ============================================================================
-- Individual machines. Note how little is here now: identity, grid position,
-- location. Everything else is a property of the plant.
--
-- `grid_row` and `grid_col` are worth storing rather than recomputing. They make
-- the layout queryable ("which turbines are on the downwind edge?"), and they
-- are how you correlate a performance anomaly with a physical position — which
-- is exactly how wake losses show up in real production data.
--
-- Naming follows SCADA convention: PLANT-Tnn. An operator reading an alarm for
-- `Sweetwater_0101-T06` knows the site, and knows it is the sixth machine.

CREATE TABLE turbines (
  turbine_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id     UUID NOT NULL REFERENCES plants (plant_id) ON DELETE CASCADE,
  name         TEXT NOT NULL UNIQUE,                 -- e.g. 'Sweetwater_0101-T06'
  turbine_no   INTEGER NOT NULL,
  grid_row     INTEGER NOT NULL,
  grid_col     INTEGER NOT NULL,
  location     GEOGRAPHY(Point, 4326) NOT NULL,
  installed_at DATE NOT NULL,
  CONSTRAINT turbines_position_unique UNIQUE (plant_id, turbine_no)
);

CREATE INDEX idx_turbines_location ON turbines USING GIST (location);
CREATE INDEX idx_turbines_plant    ON turbines (plant_id);


-- ============================================================================
-- ## Turbine neighbours — precomputed wake geometry
-- ============================================================================
-- The most interesting table in this workshop, and the reason grouping turbines into
-- plants changes the physics rather than just the labelling.
--
-- A turbine extracts energy from the air, so it leaves behind a slower, more
-- turbulent wake. Any machine standing in that wake sees less wind and produces
-- less power. This is a real, large, expensive effect: whole-plant wake losses
-- typically run 5-15%, and for a badly-sited turbine on the downwind edge of a
-- dense array it can exceed 30%. It is the single biggest reason wind farm
-- layout is a specialist engineering discipline.
--
-- Whether turbine A wakes turbine B depends on:
--   * the geometry between them  — FIXED, so compute it once, here
--   * the current wind direction — DYNAMIC, so evaluate it per reading
--
-- Splitting it that way is the whole engineering point. The expensive part
-- (pairwise spatial maths over every turbine in a plant) happens once at seed
-- time; the generator then only has to compare an angle.
--
-- Columns, all derived in step 04:
--
--   bearing_deg          azimuth FROM this turbine TO the neighbour. A turbine
--                        is waked when the wind blows FROM the neighbour's
--                        direction — i.e. when the meteorological wind direction
--                        matches this bearing.
--   rotor_diameters      separation in rotor diameters, the unit the industry
--                        actually uses. "7D spacing" is meaningful; "1,050 m" is
--                        not, until you know the rotor.
--   jensen_deficit       fractional velocity deficit from the Jensen (Park)
--                        model — the standard first-order wake model.
--   wake_half_angle_deg  how far off-axis the neighbour can be and still shade
--                        this turbine. The wake spreads as it travels, so this
--                        widens with distance.

CREATE TABLE turbine_neighbors (
  turbine_id          UUID NOT NULL REFERENCES turbines (turbine_id) ON DELETE CASCADE,
  neighbor_id         UUID NOT NULL REFERENCES turbines (turbine_id) ON DELETE CASCADE,
  plant_id            UUID NOT NULL REFERENCES plants (plant_id) ON DELETE CASCADE,
  distance_m          DOUBLE PRECISION NOT NULL,
  bearing_deg         DOUBLE PRECISION NOT NULL,
  rotor_diameters     DOUBLE PRECISION NOT NULL,
  jensen_deficit      DOUBLE PRECISION NOT NULL,
  wake_half_angle_deg DOUBLE PRECISION NOT NULL,
  PRIMARY KEY (turbine_id, neighbor_id),
  CONSTRAINT turbine_neighbors_not_self CHECK (turbine_id <> neighbor_id)
);

-- The generator's hot path: "give me every neighbour that could be waking this
-- turbine right now". Ordered so the index covers the lookup entirely.
CREATE INDEX idx_turbine_neighbors_lookup
  ON turbine_neighbors (turbine_id, bearing_deg);



-- ============================================================================
-- ## Turbine faults — the ground truth behind underperformance
-- ============================================================================
-- Real turbines degrade. Blades soil and erode, pitch and yaw drift out of
-- alignment, gearboxes wear, anemometers drift, and grid operators curtail
-- output. The machine keeps reporting happily the whole time — it just makes
-- less power than the wind it is standing in should produce.
--
-- That gap is the single most valuable thing a wind operator can measure, and it
-- is invisible in raw output alone: a turbine making 800 kW might be healthy in
-- light wind or badly faulted in a gale. You can only see it by comparing actual
-- output against what the power curve says the measured wind SHOULD have
-- produced.
--
-- So the generator writes both numbers (step 03), and this table is the ANSWER
-- KEY. Nothing in the telemetry references it. The detection queries in step 11
-- find underperformers statistically, and then you check them against this table
-- to see whether the detector actually worked — which is exactly the position a
-- real analytics team is in, except they never get to see the answer key.
--
-- `detected_at` deliberately lags `started_at`. In the field a gradual fault runs
-- for weeks before anyone notices, and closing that gap is what the monitoring is
-- for. Some rows here have detected_at NULL: still undiagnosed.
--
-- `ramp_days` distinguishes the two shapes a fault takes:
--   0    step change — a pitch fault or a curtailment order, on in one reading
--   > 0  gradual ramp — soiling, erosion, wear, creeping in over weeks
-- Gradual faults are far harder to spot, because no single reading looks wrong.

CREATE TABLE turbine_faults (
  fault_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  turbine_id  UUID NOT NULL REFERENCES turbines (turbine_id) ON DELETE CASCADE,
  fault_type  TEXT NOT NULL,
  severity    DOUBLE PRECISION NOT NULL,   -- fractional power loss at full effect
  ramp_days   DOUBLE PRECISION NOT NULL DEFAULT 0,
  started_at  TIMESTAMPTZ NOT NULL,
  resolved_at TIMESTAMPTZ,                 -- NULL = still active
  detected_at TIMESTAMPTZ,                 -- NULL = nobody has noticed yet
  notes       TEXT,
  CONSTRAINT turbine_faults_severity_range CHECK (severity > 0 AND severity <= 1),
  CONSTRAINT turbine_faults_type_valid CHECK (fault_type IN (
    'blade_soiling',        -- dirt and insect build-up, gradual, 3-8%
    'blade_erosion',        -- leading-edge wear, very gradual, 4-10%
    'pitch_misalignment',   -- blade angle off by a degree or two, step, 5-12%
    'yaw_misalignment',     -- nacelle not facing the wind, step, 4-10%
    'gearbox_degradation',  -- mechanical losses rising, gradual, 8-15%
    'generator_derate',     -- thermal derate, step
    'grid_curtailment',     -- told to reduce output; not a fault at all
    'icing'                 -- seasonal, severe
  ))
);

CREATE INDEX idx_turbine_faults_turbine ON turbine_faults (turbine_id, started_at DESC);
-- Partial index for "what is broken right now", the dashboard's hot query.
CREATE INDEX idx_turbine_faults_active  ON turbine_faults (turbine_id)
  WHERE resolved_at IS NULL;


-- ============================================================================
-- ## turbine_health() — the fault model applied at a moment in time
-- ============================================================================
-- Returns the fraction of healthy output a turbine is capable of: 1.0 when
-- nothing is wrong, 0.88 when a gearbox is costing it 12%.
--
-- Concurrent faults are SUMMED and capped rather than multiplied. Multiplying is
-- arguably more physical, but summing is what wind-industry loss accounting does
-- (losses are budgeted additively against a gross energy estimate) and it keeps
-- the arithmetic legible when you are reconciling a number on a dashboard.
--
-- The ramp is what makes gradual faults realistic:
--   effective severity = severity x min(1, days_since_start / ramp_days)
-- so soiling with severity 0.06 and ramp_days 40 costs 1.5% after ten days and
-- the full 6% after forty.
--
-- STABLE, not IMMUTABLE — it reads a table. That is why the wake and fault steps
-- both sit OUTSIDE the immutable wind model.

CREATE OR REPLACE FUNCTION turbine_health(
  p_turbine_id UUID,
  p_time       TIMESTAMPTZ
) RETURNS DOUBLE PRECISION
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
  SELECT GREATEST(0.05, 1.0 - LEAST(0.90, COALESCE(SUM(
           f.severity
           * CASE WHEN f.ramp_days <= 0 THEN 1.0
                  ELSE LEAST(1.0,
                       EXTRACT(EPOCH FROM (p_time - f.started_at))
                       / (f.ramp_days * 86400.0))
             END), 0.0)))
    FROM turbine_faults f
   WHERE f.turbine_id = p_turbine_id
     AND f.started_at <= p_time
     AND (f.resolved_at IS NULL OR f.resolved_at > p_time);
$$;

COMMENT ON FUNCTION turbine_health IS
  'Fraction of healthy output a turbine can produce at a given instant, given its '
  'active faults. 1.0 = no derate.';


-- ============================================================================
-- ## Angular difference helper
-- ============================================================================
-- Comparing compass bearings needs wrap-around arithmetic: the difference
-- between 350 and 10 degrees is 20, not 340. Used by the wake check in step 06
-- and by several queries in step 11.
--
-- IMMUTABLE, so it can appear in index expressions and continuous aggregates.
-- Note the ::numeric detour — mod() has no double-precision overload in
-- PostgreSQL, only integer and numeric.

CREATE OR REPLACE FUNCTION angular_diff_deg(p_a DOUBLE PRECISION, p_b DOUBLE PRECISION)
RETURNS DOUBLE PRECISION
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT 180.0 - ABS(ABS(MOD((p_a - p_b)::numeric, 360.0))::DOUBLE PRECISION - 180.0);
$$;

COMMENT ON FUNCTION angular_diff_deg IS
  'Smallest absolute difference between two compass bearings, in degrees (0-180).';

-- Sanity check the wrap-around:
SELECT angular_diff_deg(350, 10)  AS should_be_20,
       angular_diff_deg(10, 350)  AS also_20,
       angular_diff_deg(270, 90)  AS should_be_180,
       angular_diff_deg(45, 45)   AS should_be_0;

--  should_be_20 | also_20 | should_be_180 | should_be_0
-- --------------+---------+---------------+-------------
--            20 |      20 |           180 |           0
-- (1 row)


-- ============================================================================
-- ## Verify
-- ============================================================================

SELECT table_name,
       COUNT(*) AS columns
  FROM information_schema.columns
 WHERE table_schema = 'public'
   AND table_name IN ('regions', 'plants', 'turbines', 'turbine_neighbors',
                      'turbine_faults')
 GROUP BY table_name
 ORDER BY table_name;

--     table_name     | columns
-- ------------------+---------
--  plants            |      19
--  regions           |       5
--  turbine_neighbors |       8
--  turbines          |       8
-- (4 rows)

-- The geography columns should report udt_name = 'geography'. If any says
-- 'bytea', PostGIS is not installed — go back to step 01.
SELECT table_name, column_name, udt_name
  FROM information_schema.columns
 WHERE table_schema = 'public'
   AND udt_name IN ('geography', 'geometry')
 ORDER BY table_name, column_name;
