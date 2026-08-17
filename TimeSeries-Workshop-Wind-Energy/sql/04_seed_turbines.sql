-- ============================================================================
-- # Wind Energy — Step 04: Seed Regions, Plants and Turbines
-- ============================================================================
-- Builds the fleet from the top down:
--
--   1. Six real geographic regions with polygon boundaries
--   2. A catalogue of 36 real wind-development sites, named for the nearest town
--   3. `num_plants` plants, handed out round-robin across the regions
--   4. `turbines_per_plant` turbines per plant, on a GEODESIC GRID around the
--      plant centre, rotated to the region's prevailing wind
--   5. Pairwise wake geometry inside each plant
--
-- Everything scales from two config values, so the same script builds a 6-turbine
-- toy or a 400-turbine portfolio:
--
--   UPDATE workshop_config SET value = '24' WHERE key = 'num_plants';
--   UPDATE workshop_config SET value = '12' WHERE key = 'turbines_per_plant';
--
-- Re-runnable throughout: region, plant and turbine names are unique keys and
-- every insert uses ON CONFLICT DO NOTHING.
-- ============================================================================


-- ============================================================================
-- ## 1. Regions
-- ============================================================================
-- Named as an atlas would name them — these are real physiographic and maritime
-- regions, not invented marketing territories. Each is a genuine wind-development
-- heartland.
--
-- ST_MakeEnvelope(xmin, ymin, xmax, ymax, srid) builds an axis-aligned box.
-- Production systems would use administrative or grid-operator boundaries;
-- envelopes stay readable while still exercising a real point-in-polygon join.
-- Note the argument order: X is LONGITUDE. Reversing X and Y is the single most
-- common PostGIS mistake.
--
-- The boxes are deliberately non-overlapping, so every site resolves to exactly
-- one region.
--
-- prevailing_wind_deg is the direction wind comes FROM, and it is real physics:
-- the mid-latitude westerly belt dominates Europe and the American plains
-- (roughly 250-270 degrees), while the Deccan sits in the southwest monsoon
-- flow (around 225 degrees in season).

-- The climate figures are representative annual values for each area, not
-- measurements from a specific met station. They are the model's INPUT, so the
-- comment on each row is the reasoning you would otherwise have to reverse
-- engineer out of the numbers.
--
-- `wind_peak_doy` is the one worth reading carefully: these six regions do NOT
-- share an annual cycle, and that is the point of storing it per region.
--   doy  15 = mid-January     doy 100 = mid-April
--   doy 120 = end of April    doy 200 = mid-July
--
INSERT INTO regions (region_name, country, boundary, prevailing_wind_deg, is_offshore,
                     wind_base_ms, wind_seasonal_ms, wind_peak_doy,
                     temp_mean_c, temp_seasonal_amp_c, temp_peak_doy, temp_diurnal_amp_c) VALUES

  -- Texas/Oklahoma panhandle. Wind peaks in SPRING, not winter — the plains
  -- low-level jet is strongest in March-April and slackest in midsummer, which
  -- is the opposite of the European pattern and the single clearest reason this
  -- cannot be a function of latitude. Continental temperature: hot summers, cold
  -- winters, and a wide daily swing over dry ground.
  ('Southern Great Plains',     'United States',
   ST_MakeEnvelope(-104.0, 30.0,  -94.0, 44.0, 4326), 190.0, false,
   7.0, 1.5,  95,    15.0, 12.0, 200, 6.5),

  -- Offshore, and it shows in every column: the highest mean wind of the six, a
  -- strong WINTER maximum from the North Atlantic storm track, and the smallest
  -- temperature swings anywhere in the fleet. Water has enormous thermal
  -- inertia, so the annual range is narrow AND the warmest part of the year lags
  -- to late August (doy 235) instead of mid-July. The daily swing is almost
  -- nothing — 1.2 degC against 6.5 on the Great Plains.
  ('North Sea',                 'United Kingdom / Denmark',
   ST_MakeEnvelope(  -6.0, 51.0,    8.0, 59.0, 4326), 245.0, true,
   9.5, 2.2,  15,    10.5,  5.5, 235, 1.2),

  -- Northern Germany: same westerly belt as the North Sea, same winter peak,
  -- but onshore roughness costs about 3 m/s of mean wind and the continental
  -- influence roughly doubles both temperature amplitudes.
  ('North German Plain',        'Germany',
   ST_MakeEnvelope(   8.4, 47.0,   14.2, 54.6, 4326), 250.0, false,
   6.6, 1.8,  10,     9.5,  9.5, 205, 4.5),

  -- The Spanish interior. Winter-into-spring wind maximum, weaker seasonality
  -- than further north, and a large daily temperature swing for its latitude —
  -- high, dry plateau air holds little heat overnight.
  ('Iberian Meseta',            'Spain',
   ST_MakeEnvelope(  -9.0, 36.0,    3.0, 43.5, 4326), 290.0, false,
   6.8, 1.3,  40,    14.0, 10.5, 205, 7.0),

  -- India, and the most interesting row in the table. The southwest monsoon
  -- makes the windiest season MIDSUMMER (doy 200) — in direct antiphase with
  -- Europe — and it is by far the strongest seasonality of the six: 5.2 +/- 3.4
  -- means the monsoon peak is nearly five times the dry-season minimum.
  --
  -- Temperature runs the other way and peaks BEFORE the rains (doy 120, late
  -- April/May), because monsoon cloud and evaporative cooling drop temperatures
  -- through July and August. So this is the one region where the windiest months
  -- are not the hottest — visible immediately on the turbine dashboard once you
  -- have two years loaded.
  ('Deccan Plateau',            'India',
   ST_MakeEnvelope(  72.0,  8.0,   80.0, 21.0, 4326), 225.0, false,
   5.2, 3.4, 200,    26.0,  4.0, 120, 6.0),

  -- The Chinese steppe: spring wind maximum like the US plains, and the most
  -- extreme continental temperature regime in the fleet. A 17 degC seasonal
  -- amplitude around a 6 degC mean puts midwinter near -11 and midsummer near
  -- +23, which is what actually happens there.
  ('Inner Mongolian Plateau',   'China',
   ST_MakeEnvelope(  96.0, 35.0,  122.0, 46.0, 4326), 305.0, false,
   6.4, 1.9, 100,     6.0, 17.0, 200, 8.0)

ON CONFLICT (region_name) DO UPDATE SET
  -- DO UPDATE rather than DO NOTHING so that re-running this file after editing
  -- a climate figure actually applies it. With DO NOTHING you would edit a
  -- number, re-run, see no change, and have no indication why.
  country             = EXCLUDED.country,
  boundary            = EXCLUDED.boundary,
  prevailing_wind_deg = EXCLUDED.prevailing_wind_deg,
  is_offshore         = EXCLUDED.is_offshore,
  wind_base_ms        = EXCLUDED.wind_base_ms,
  wind_seasonal_ms    = EXCLUDED.wind_seasonal_ms,
  wind_peak_doy       = EXCLUDED.wind_peak_doy,
  temp_mean_c         = EXCLUDED.temp_mean_c,
  temp_seasonal_amp_c = EXCLUDED.temp_seasonal_amp_c,
  temp_peak_doy       = EXCLUDED.temp_peak_doy,
  temp_diurnal_amp_c  = EXCLUDED.temp_diurnal_amp_c;

-- Southern Great Plains prevailing wind is SOUTHERLY (190), not westerly — the
-- Great Plains low-level jet pulls Gulf air northward, and it is why the Texas
-- and Oklahoma wind corridor runs the way it does. Getting this right matters
-- here because it sets the orientation of every turbine grid in the region.


-- ============================================================================
-- ## 2. Site catalogue
-- ============================================================================
-- Thirty-six real places with real coordinates, six per region, each an actual
-- wind-development area. Sweetwater and Roscoe in Texas, Dogger Bank and Hornsea
-- in the North Sea, Muppandal near Kanyakumari, the Gansu corridor at Jiuquan:
-- these are where the turbines genuinely are.
--
-- `site_rank` numbers the sites within each region so that step 3 can interleave
-- them — with num_plants = 6 you get one plant in each region rather than six
-- crowded into Texas.

CREATE TEMPORARY TABLE tmp_sites AS
WITH raw AS (
  SELECT * FROM (VALUES
    -- region                     , site slug        , display name        , lat   , lon
    ('Southern Great Plains'      , 'Sweetwater'     , 'Sweetwater, TX'    ,  32.47, -100.41),
    ('Southern Great Plains'      , 'Snyder'         , 'Snyder, TX'        ,  32.72, -100.92),
    ('Southern Great Plains'      , 'Amarillo'       , 'Amarillo, TX'      ,  35.22, -101.83),
    ('Southern Great Plains'      , 'Woodward'       , 'Woodward, OK'      ,  36.43,  -99.39),
    ('Southern Great Plains'      , 'DodgeCity'      , 'Dodge City, KS'    ,  37.75, -100.02),
    ('Southern Great Plains'      , 'GreatBend'      , 'Great Bend, KS'    ,  38.36,  -98.76),

    ('North Sea'                  , 'DoggerBank'     , 'Dogger Bank'       ,  54.75,    2.35),
    ('North Sea'                  , 'Hornsea'        , 'Hornsea'           ,  53.90,    1.79),
    ('North Sea'                  , 'ForthEstuary'   , 'Firth of Forth'    ,  56.30,   -2.20),
    ('North Sea'                  , 'HornsRev'       , 'Horns Rev'         ,  55.53,    7.84),
    ('North Sea'                  , 'EastAnglia'     , 'East Anglia'       ,  52.23,    2.30),
    ('North Sea'                  , 'HumberGateway'  , 'Humber Gateway'    ,  53.64,    0.62),

    ('North German Plain'         , 'Husum'          , 'Husum'             ,  54.47,    9.05),
    ('North German Plain'         , 'Bremerhaven'    , 'Bremerhaven'       ,  53.55,    8.58),
    ('North German Plain'         , 'Magdeburg'      , 'Magdeburg'         ,  52.13,   11.63),
    ('North German Plain'         , 'Neubrandenburg' , 'Neubrandenburg'    ,  53.56,   13.26),
    ('North German Plain'         , 'Paderborn'      , 'Paderborn'         ,  51.72,    8.75),
    ('North German Plain'         , 'Leipzig'        , 'Leipzig'           ,  51.34,   12.37),

    ('Iberian Meseta'             , 'Zaragoza'       , 'Zaragoza'          ,  41.65,   -0.89),
    ('Iberian Meseta'             , 'Albacete'       , 'Albacete'          ,  38.99,   -1.86),
    ('Iberian Meseta'             , 'Burgos'         , 'Burgos'            ,  42.34,   -3.70),
    ('Iberian Meseta'             , 'ACoruna'        , 'A Coruna'          ,  43.36,   -8.40),
    ('Iberian Meseta'             , 'Tarifa'         , 'Tarifa'            ,  36.11,   -5.60),
    ('Iberian Meseta'             , 'Soria'          , 'Soria'             ,  41.76,   -2.47),

    ('Deccan Plateau'             , 'Kanyakumari'    , 'Kanyakumari'       ,   8.19,   77.54),
    ('Deccan Plateau'             , 'Tirunelveli'    , 'Tirunelveli'       ,   8.71,   77.76),
    ('Deccan Plateau'             , 'Palladam'       , 'Palladam'          ,  10.99,   77.29),
    ('Deccan Plateau'             , 'Chitradurga'    , 'Chitradurga'       ,  14.23,   76.40),
    ('Deccan Plateau'             , 'Satara'         , 'Satara'            ,  17.69,   74.02),
    ('Deccan Plateau'             , 'Sangli'         , 'Sangli'            ,  16.85,   74.58),

    ('Inner Mongolian Plateau'    , 'Ulanqab'        , 'Ulanqab'           ,  41.02,  113.12),
    ('Inner Mongolian Plateau'    , 'Zhangbei'       , 'Zhangbei'          ,  41.16,  114.71),
    ('Inner Mongolian Plateau'    , 'Jiuquan'        , 'Jiuquan'           ,  39.74,   98.51),
    ('Inner Mongolian Plateau'    , 'Bayannur'       , 'Bayannur'          ,  40.75,  107.42),
    ('Inner Mongolian Plateau'    , 'Xilinhot'       , 'Xilinhot'          ,  43.94,  116.07),
    ('Inner Mongolian Plateau'    , 'Chifeng'        , 'Chifeng'           ,  42.26,  118.96)
  ) AS v(region_name, slug, display_name, lat, lon)
)
SELECT r.region_name,
       r.slug,
       r.display_name,
       ST_SetSRID(ST_MakePoint(r.lon, r.lat), 4326)::geography AS center_location,
       ROW_NUMBER() OVER (PARTITION BY r.region_name ORDER BY r.slug)   AS site_rank,
       DENSE_RANK()  OVER (ORDER BY r.region_name)                      AS region_rank
  FROM raw r;

-- Every site must fall inside its own declared region. Catches a transposed
-- coordinate immediately rather than three files later.
SELECT s.display_name, s.region_name AS declared_region
  FROM tmp_sites s
  LEFT JOIN regions g
         ON g.region_name = s.region_name
        AND ST_Contains(g.boundary, s.center_location::geometry)
 WHERE g.region_name IS NULL;

-- Expected: (0 rows)


-- ============================================================================
-- ## 3. Plants
-- ============================================================================
-- Take the first `num_plants` sites in round-robin order across regions, and
-- build a plant at each.
--
-- Plant names follow a business asset-code convention: <Site>_RRSS where RR is
-- the region number and SS the sequence within it. `Sweetwater_0106` is the sixth
-- plant in region 1. Operators really do name assets this way, and it means a
-- plant name sorts usefully and carries its region.
--
-- Turbine model is chosen by region so the fleet is plausible: the big
-- direct-drive offshore machines in the North Sea, Enercon and Nordex on the
-- North German Plain, Goldwind in Inner Mongolia, Suzlon on the Deccan.
--
-- Spacing is derived from rotor diameter, in the units the industry uses:
-- 5 rotor diameters crosswind, 8 downwind. For a 150 m rotor that is 750 m and
-- 1,200 m. The asymmetry exists purely because of wakes.

INSERT INTO plants (
  plant_name, site_name, operator, region_name, center_location, grid_bearing_deg,
  turbine_count, model, hub_height_m, rotor_diameter_m, rated_capacity_kw,
  cut_in_ms, cut_out_ms, spacing_crosswind_m, spacing_downwind_m,
  is_offshore, commissioned_at
)
SELECT s.slug || '_' || LPAD(s.region_rank::text, 2, '0')
                     || LPAD(s.site_rank::text,   2, '0')          AS plant_name,
       s.display_name,
       spec.operator,
       s.region_name,
       s.center_location,
       -- Grid rows run along the prevailing wind, so the wide spacing is the
       -- downwind one. This is what a developer would do.
       g.prevailing_wind_deg,
       cfg_int('turbines_per_plant'),
       spec.model, spec.hub_m, spec.rotor_m, spec.rated_kw, spec.cut_in, spec.cut_out,
       spec.rotor_m * cfg_num('spacing_crosswind_rotors'),
       spec.rotor_m * cfg_num('spacing_downwind_rotors'),
       g.is_offshore,
       -- Deterministic commissioning date spread over recent years, so the fleet
       -- has plausible vintage rather than all appearing on one day.
       (DATE '2019-01-01'
         + (( ('x' || SUBSTR(MD5(s.slug), 1, 6))::bit(24)::INTEGER % 2200 ))::int) AS commissioned_at
  FROM tmp_sites s
  JOIN regions g ON g.region_name = s.region_name
  CROSS JOIN LATERAL (
    SELECT * FROM (VALUES
      ('North Sea',               'SG 167-8.0 DD',      'Ørsted North Sea',      110.0, 167.0, 8000.0, 3.0, 25.0),
      ('North German Plain',      'Enercon E-138 EP3',  'EnBW Onshore',          111.0, 138.0, 3500.0, 2.5, 24.0),
      ('Southern Great Plains',   'Vestas V150-4.2',    'Lone Star Renewables',  105.0, 150.0, 4200.0, 3.0, 22.5),
      ('Iberian Meseta',          'Nordex N149-4.5',    'Iberdrola Renovables',  125.0, 149.0, 4500.0, 3.0, 25.0),
      ('Deccan Plateau',          'Suzlon S144-3.0',    'Suzlon Energy',         140.0, 144.0, 3000.0, 3.0, 20.0),
      ('Inner Mongolian Plateau', 'Goldwind GW140-3.4', 'Longyuan Power',        120.0, 140.0, 3400.0, 2.5, 22.0)
    ) AS t(region_name, model, operator, hub_m, rotor_m, rated_kw, cut_in, cut_out)
    WHERE t.region_name = s.region_name
  ) spec
 ORDER BY s.site_rank, s.region_rank      -- round-robin across regions
 LIMIT cfg_int('num_plants')
ON CONFLICT (plant_name) DO NOTHING;


-- ============================================================================
-- ## 4. Turbines — a geodesic grid around each plant centre
-- ============================================================================
-- The layout maths, and the reason it uses ST_Project rather than arithmetic.
--
-- The naive approach converts a metre offset to degrees by dividing by 111,320.
-- That is right for latitude and WRONG for longitude, where a degree shrinks by
-- cos(latitude) — at Dogger Bank's 54.75 degrees a degree of longitude is 64 km,
-- not 111 km. Get it wrong and every grid is stretched east-west by a factor of
-- 1.7, more at higher latitudes.
--
-- ST_Project(geography, distance_m, azimuth_radians) walks a true geodesic on the
-- spheroid. No projection to choose, no cos(lat) correction to forget, correct at
-- any latitude. Verify it if you like:
--
--   SELECT ST_Distance(g, ST_Project(g, 750, radians(45)))
--     FROM (SELECT ST_SetSRID(ST_MakePoint(-100.41, 32.47), 4326)::geography g) x;
--   -- exactly 750
--
-- Layout algorithm:
--   cols  = ceil(sqrt(n))                    a roughly square array
--   col   = i % cols,  row = i / cols
--   dx    = (col - (cols-1)/2) * crosswind   centred on the plant
--   dy    = (row - (rows-1)/2) * downwind
--   rotate (dx, dy) by the plant's grid bearing
--   dist  = hypot(dx, dy),  azimuth = atan2(dx, dy)
--
-- atan2(dx, dy) — east first, north second — because a compass azimuth is
-- measured clockwise FROM NORTH, which is the transpose of the mathematical
-- convention.

INSERT INTO turbines (plant_id, name, turbine_no, grid_row, grid_col, location, installed_at)
SELECT p.plant_id,
       -- Zero-pad to the width of the largest turbine number, minimum 2.
       --
       -- LPAD TRUNCATES when the value is wider than the pad length:
       -- LPAD('100', 2, '0') returns '10', not '100'. Hard-coding 2 therefore
       -- names turbine 100 "T10", which collides with turbine 10, and the
       -- ON CONFLICT DO NOTHING below silently discards it. Asking for 150
       -- turbines per plant produced 99 — no error, just missing machines.
       p.plant_name || '-T'
         || LPAD((k.i + 1)::text, GREATEST(2, LENGTH(p.turbine_count::text)), '0'),
       k.i + 1,
       g.grow,
       g.gcol,
       ST_Project(p.center_location, o.dist_m, o.azimuth_rad),
       p.commissioned_at
  FROM plants p
  CROSS JOIN generate_series(0, p.turbine_count - 1) AS k(i)
  CROSS JOIN LATERAL (
    SELECT CEIL(SQRT(p.turbine_count::numeric))::int AS cols
  ) c
  CROSS JOIN LATERAL (
    SELECT (k.i % c.cols)                                        AS gcol,
           (k.i / c.cols)                                        AS grow,
           CEIL(p.turbine_count::numeric / c.cols)::int           AS rows_n
  ) g
  CROSS JOIN LATERAL (
    -- STAGGERED, NOT A PLAIN GRID. Every odd row is shifted half a crosswind
    -- spacing, giving a checkerboard. This is what real wind farms do, and the
    -- reason is the Jensen deficit's 1/(1+2kx/D)^2 falloff.
    --
    -- In an aligned grid, the machine directly ahead of you sits at one downwind
    -- spacing (8 rotor diameters here) and its wake lands squarely on you when the
    -- wind blows down the rows — which is precisely the direction the plant was
    -- oriented for. Measured on a 4x4 plant before this change: 25.8% mean power
    -- loss at exactly the design bearing.
    --
    -- Offsetting alternate rows moves that machine 2.5 diameters sideways at 8
    -- downwind, i.e. atan(2.5/8) = 17.4 degrees off the axis. The wake half-angle
    -- at 8D is only atan((0.5 + 0.05*8)/8) = 6.4 degrees, so at the design bearing
    -- the near wake MISSES entirely. What is left aligned is the row TWO ahead, at
    -- 16D — and the deficit there is 0.5528/(1+2*0.05*16)^2 = 0.082 against 0.171
    -- at 8D, less than half.
    --
    -- It does not remove wake, it MOVES it: the diagonal neighbour is now aligned
    -- at +/-17.4 degrees, so the loss reappears as narrow spikes either side of the
    -- axis instead of a broad peak on it. The sweep in step 06 shows both.
    SELECT (g.gcol - (c.cols   - 1) / 2.0
            + CASE WHEN g.grow % 2 = 1 THEN 0.5 ELSE 0.0 END) * p.spacing_crosswind_m AS dx0,
           -- Note the sign: ((rows-1)/2 - grow), not (grow - (rows-1)/2).
           --
           -- grid_bearing_deg is the direction the wind comes FROM, so +dy points
           -- upwind. Flipping the sign here makes ROW 0 THE UPWIND ROW — the
           -- "front row" in the way the industry talks about it — with grid_row
           -- counting how far back from clean air a turbine sits.
           --
           -- Get this backwards and every query about front-row versus back-row
           -- performance is inverted, while still looking superficially plausible.
           ((g.rows_n - 1) / 2.0 - g.grow) * p.spacing_downwind_m  AS dy0
  ) d
  CROSS JOIN LATERAL (
    -- Rotate the grid so the DOWNWIND axis (dy0, wide spacing) points along the
    -- plant's grid bearing.
    --
    -- Careful with the sign convention — getting it wrong mirrors the grid and
    -- was a real bug here. A compass bearing theta as an (east, north) unit
    -- vector is (sin θ, cos θ), NOT the (cos θ, sin θ) of mathematical
    -- convention. The crosswind axis is theta+90, i.e. (cos θ, -sin θ). So:
    --
    --   east  = dx0·cos θ + dy0·sin θ
    --   north = dy0·cos θ - dx0·sin θ
    --
    -- Using the textbook rotation matrix instead rotates by -theta, which leaves
    -- a perfectly plausible-looking grid whose wide spacing is aimed 2x(bearing
    -- error) away from the prevailing wind. The verification query at the end of
    -- this file catches it: the downwind neighbour's bearing must equal the
    -- plant's grid_bearing_deg.
    SELECT  d.dx0 * COS(RADIANS(p.grid_bearing_deg)) + d.dy0 * SIN(RADIANS(p.grid_bearing_deg)) AS dx,
            d.dy0 * COS(RADIANS(p.grid_bearing_deg)) - d.dx0 * SIN(RADIANS(p.grid_bearing_deg)) AS dy
  ) r
  CROSS JOIN LATERAL (
    SELECT SQRT(r.dx * r.dx + r.dy * r.dy) AS dist_m,
           ATAN2(r.dx, r.dy)               AS azimuth_rad
  ) o
ON CONFLICT (name) DO NOTHING;


-- ============================================================================
-- ## 5. Wake geometry
-- ============================================================================
-- Pairwise, within each plant. Computed once here so the generator in step 06
-- only has to compare an angle per reading.
--
-- The Jensen (Park) model, the standard first-order wake model since 1983:
--
--     deficit = (1 - sqrt(1 - Ct)) / (1 + 2k·x/D)²
--
--   Ct  thrust coefficient, ~0.8 for a modern turbine below rated wind, giving
--       a numerator of 1 - sqrt(0.2) = 0.5528
--   k   wake decay constant: 0.05 onshore, 0.04 offshore. Lower offshore because
--       smooth water generates less turbulence, so wakes recover more slowly —
--       which is exactly why offshore arrays are spaced further apart.
--   x/D separation in rotor diameters
--
-- Sanity: at 5D a turbine loses about 25% of its wind speed, at 8D about 17%,
-- at 12D about 10%. Because power goes as v³, a 17% velocity deficit is roughly
-- a 43% power loss for that machine while it is shaded. That is why layout is
-- worth paying an engineer to optimise.
--
-- wake_half_angle_deg: the wake spreads linearly as it travels, radius
-- (D/2 + k·x). A neighbour off-axis by more than atan(radius/x) does not shade
-- this turbine at all.
--
-- Cut off beyond 12 rotor diameters — the deficit there is ~10% and falling as
-- 1/x², so more distant pairs add cost for negligible physics.
--
-- COST: the cutoff is what keeps this LINEAR, and it has to be applied by the
-- SPATIAL INDEX rather than as an afterthought.
--
-- The obvious formulation joins every turbine to every other turbine in its
-- plant and filters on ST_Distance:
--
--   FROM turbines a JOIN turbines b ON b.plant_id = a.plant_id
--    WHERE ST_Distance(a.location, b.location) <= 12 * p.rotor_diameter_m
--
-- That reads fine and produces the right answer, but ST_Distance in the WHERE
-- clause cannot use an index, so the planner materialises all n² same-plant
-- pairs and discards most of them. Measured at 6 plants: with 8 turbines each it
-- examines 336 pairs to keep 228 (1.5x waste); with 100 each it examines 59,400
-- to keep 5,016 (12x). The waste ratio grows linearly with plant size, so total
-- work is O(n²).
--
-- Using ST_DWithin inside a LATERAL lets the GiST index on turbines.location do
-- the pruning. The plan becomes a nested loop with
-- "Index Cond: location && _st_expand(...)", so each turbine examines only the
-- handful of machines actually near it. Because wake physics bounds the
-- neighbourhood (at 5D/8D spacing, ~8 turbines fall within 12D no matter how big
-- the plant is), the work per turbine is CONSTANT and the whole build is O(n).
--
-- Same output, both ways — the pair counts are identical. Only the cost differs.

INSERT INTO turbine_neighbors (
  turbine_id, neighbor_id, plant_id, distance_m, bearing_deg,
  rotor_diameters, jensen_deficit, wake_half_angle_deg
)
SELECT a.turbine_id,
       nb.neighbor_id,
       a.plant_id,
       nb.dist_m,
       -- Azimuth FROM this turbine TO the neighbour. The turbine is waked when
       -- the wind blows FROM that direction, so this compares directly against a
       -- meteorological wind direction with no 180-degree flip to get wrong.
       DEGREES(ST_Azimuth(a.location, nb.location)),
       nb.dist_m / p.rotor_diameter_m,
       0.5528 / POWER(1.0 + 2.0 * k.wake_k * (nb.dist_m / p.rotor_diameter_m), 2),
       DEGREES(ATAN((p.rotor_diameter_m / 2.0 + k.wake_k * nb.dist_m) / nb.dist_m))
  FROM turbines a
  JOIN plants   p ON p.plant_id = a.plant_id
  CROSS JOIN LATERAL (
    -- Offshore wakes persist further, so the decay constant is smaller.
    SELECT CASE WHEN p.is_offshore THEN 0.04 ELSE cfg_num('wake_decay_k') END AS wake_k
  ) k
  CROSS JOIN LATERAL (
    -- ST_DWithin, not ST_Distance in a WHERE clause. This is the index-assisted
    -- form: the radius is a parameter per outer row, so the GiST index expands
    -- a's bounding box and returns only nearby candidates.
    SELECT b.turbine_id AS neighbor_id,
           b.location,
           ST_Distance(a.location, b.location) AS dist_m
      FROM turbines b
     WHERE b.plant_id = a.plant_id
       AND b.turbine_id <> a.turbine_id
       AND ST_DWithin(b.location, a.location, 12.0 * p.rotor_diameter_m)
  ) nb
 WHERE nb.dist_m > 1.0
ON CONFLICT (turbine_id, neighbor_id) DO NOTHING;

-- Confirm the index is doing the pruning rather than the planner brute-forcing
-- it. You want a Nested Loop with an Index Scan on idx_turbines_location and an
-- "Index Cond: (location && _st_expand(...))" line. A Merge Join or Hash Join
-- with ST_Distance as a Join Filter means it fell back to the quadratic plan.
--
--   EXPLAIN (COSTS OFF)
--   SELECT a.turbine_id, nb.neighbor_id
--     FROM turbines a
--     JOIN plants p ON p.plant_id = a.plant_id
--     CROSS JOIN LATERAL (
--       SELECT b.turbine_id AS neighbor_id FROM turbines b
--        WHERE b.plant_id = a.plant_id AND b.turbine_id <> a.turbine_id
--          AND ST_DWithin(b.location, a.location, 12.0 * p.rotor_diameter_m)
--     ) nb;



-- ============================================================================
-- ## 6. Turbine faults — seed the underperformers
-- ============================================================================
-- Roughly one turbine in nine gets a fault, which is about right for a real
-- fleet at any given moment. Assignment is DETERMINISTIC (derived from a hash of
-- the turbine name) so the same turbines are faulted on every rebuild and the
-- dashboards are reproducible.
--
-- The mix is chosen so the detection queries in step 11 have to work for their
-- answers rather than reading off one obvious outlier:
--
--   * gradual ramps (soiling, erosion, gearbox wear) that no single reading
--     reveals — you need a trend
--   * step changes (pitch, yaw, curtailment) that a threshold catches easily
--   * one RESOLVED fault, so history contains a dip that has since recovered
--   * several with detected_at NULL — still undiagnosed, which is the realistic
--     state of a fleet
--   * one grid_curtailment, which looks exactly like a fault in the data and is
--     not one. Telling those apart needs context the telemetry does not carry.
--
-- Severities are drawn from published wind-industry loss ranges.

INSERT INTO turbine_faults
  (turbine_id, fault_type, severity, ramp_days, started_at, resolved_at, detected_at, notes)
SELECT t.turbine_id,
       spec.fault_type,
       spec.severity,
       spec.ramp_days,
       date_trunc('hour', now()) - make_interval(days => spec.days_ago),
       CASE WHEN spec.resolved_days_ago IS NULL THEN NULL
            ELSE date_trunc('hour', now()) - make_interval(days => spec.resolved_days_ago)
       END,
       CASE WHEN spec.detected_days_ago IS NULL THEN NULL
            ELSE date_trunc('hour', now()) - make_interval(days => spec.detected_days_ago)
       END,
       spec.notes
  FROM (
    -- Pick every 8th turbine by a stable hash order, then hand each one a fault
    -- profile in rotation.
    SELECT t.turbine_id,
           t.name,
           ROW_NUMBER() OVER (ORDER BY md5(t.name)) AS n
      FROM turbines t
  ) t
  JOIN (VALUES
    (0, 'blade_soiling',       0.055, 45.0, 60,  NULL, NULL,
        'Gradual output decline; insect and dust accumulation on leading edge. Undiagnosed.'),
    (1, 'pitch_misalignment',  0.085,  0.0, 22,  NULL,  9,
        'Step drop after maintenance visit; blade angle out by ~1.5 degrees.'),
    (2, 'gearbox_degradation', 0.115, 70.0, 90,  NULL, 12,
        'Rising drivetrain losses, vibration trending up. Overhaul scheduled.'),
    (3, 'yaw_misalignment',    0.065,  0.0, 35,  NULL, NULL,
        'Nacelle consistently off-wind; wind vane calibration suspected. Undiagnosed.'),
    (4, 'blade_erosion',       0.075, 120.0, 150, NULL, 30,
        'Leading-edge erosion confirmed by drone inspection; repair in next window.'),
    (5, 'grid_curtailment',    0.300,  0.0, 14,   6,   14,
        'NOT A FAULT: grid operator curtailment during transmission works. Resolved.'),
    (6, 'generator_derate',    0.095,  0.0,  8,  NULL, NULL,
        'Thermal derate; cooling circuit under investigation. Undiagnosed.'),
    (7, 'blade_soiling',       0.040, 30.0, 40,  NULL, NULL,
        'Mild soiling, second site. Right at most alarm thresholds.'),
    (8, 'blade_erosion',       0.060, 90.0, 10,  NULL, NULL,
        'EARLY STAGE: 10 days into a 90-day ramp, so under 1% derate today. '
        'Invisible to a threshold alarm; only trend or peer comparison finds it. '
        'This is the row that justifies detectors 2 and 3 in step 11.')
  ) AS spec(slot, fault_type, severity, ramp_days, days_ago,
            resolved_days_ago, detected_days_ago, notes)
    ON spec.slot = (t.n % 9)
 -- One fault per selected turbine: take only the first turbine in each hash
 -- block of 8, so roughly 1 in 8 machines is affected.
 WHERE (t.n - 1) / 9 < 2                  -- at most 2 rounds -> up to 18 faults
ON CONFLICT DO NOTHING;


-- ============================================================================
-- ## Verify: faults
-- ============================================================================

SELECT f.fault_type,
       COUNT(*)                                             AS turbines,
       ROUND((AVG(f.severity) * 100)::numeric, 1)           AS avg_severity_pct,
       ROUND(AVG(f.ramp_days)::numeric, 0)                  AS avg_ramp_days,
       COUNT(*) FILTER (WHERE f.resolved_at IS NULL)        AS still_active,
       COUNT(*) FILTER (WHERE f.detected_at IS NULL)        AS undiagnosed
  FROM turbine_faults f
 GROUP BY f.fault_type
 ORDER BY avg_severity_pct DESC;

-- The health function applied right now. A gradual fault that started 60 days ago
-- with a 45-day ramp is at full severity; one that started 8 days ago with a
-- 30-day ramp is only part way in.
SELECT t.name                                              AS turbine,
       p.plant_name,
       f.fault_type,
       ROUND((f.severity * 100)::numeric, 1)                AS full_severity_pct,
       f.ramp_days,
       (now()::date - f.started_at::date)                   AS days_running,
       ROUND(((1 - turbine_health(t.turbine_id, now())) * 100)::numeric, 1)
                                                            AS derate_now_pct,
       f.detected_at IS NOT NULL                            AS detected
  FROM turbine_faults f
  JOIN turbines t ON t.turbine_id = f.turbine_id
  JOIN plants   p ON p.plant_id   = t.plant_id
 WHERE f.resolved_at IS NULL
 ORDER BY derate_now_pct DESC;

-- derate_now_pct is what the generator will actually apply. Compare it with
-- full_severity_pct to see the ramp partway through.

SELECT COUNT(*) FILTER (WHERE turbine_health(t.turbine_id, now()) < 0.999) AS turbines_derated_now,
       COUNT(*)                                                            AS turbines_total,
       ROUND((100.0 * COUNT(*) FILTER (WHERE turbine_health(t.turbine_id, now()) < 0.999)
              / COUNT(*))::numeric, 1)                                     AS pct_of_fleet
  FROM turbines t;


-- ============================================================================
-- ## 7. Export region geometry as GeoJSON for the map
-- ============================================================================
-- Grafana's geomap can draw a GeoJSON layer, but only from a STATIC FILE — there
-- is no query-driven polygon layer. So region geometry is exported once to a file
-- that docker-compose mounts into Grafana's public/maps directory.
--
-- IMPORTANT: this exports the OPERATIONAL FOOTPRINT, not `regions.boundary`.
--
-- regions.boundary is an axis-aligned ST_MakeEnvelope box. It is the right shape
-- for the administrative job it does — point-in-polygon assignment of sites to
-- regions — and completely the wrong shape to draw on a map. A rectangle sitting
-- over the North Sea tells a viewer nothing except that someone typed four
-- numbers, and it covers a great deal of territory where no asset exists.
--
-- The footprint is derived from where the assets actually are: the convex hull of
-- the region's turbines, buffered outward so it reads as a territory rather than
-- a taut rubber band. That is a shape worth putting under a map — it shows the
-- operating area, and it moves if the portfolio moves.
--
-- Two PostGIS notes. ST_ConvexHull needs at least 3 non-collinear points, so a
-- region with a single plant is handled by the buffer doing the work. And
-- ST_Buffer is called on ::geography so the radius is in METRES; buffering a
-- 4326 geometry would take the radius as degrees and distort with latitude.
--
-- Regenerate after changing the fleet shape:
--   psql -tAc "<the query below>" > grafana-geojson/wind-regions.geojson

SELECT jsonb_pretty(jsonb_build_object(
         'type', 'FeatureCollection',
         'features', jsonb_agg(
           jsonb_build_object(
             'type', 'Feature',
             'properties', jsonb_build_object(
               'region_name',         f.region_name,
               'country',             f.country,
               'prevailing_wind_deg', f.prevailing_wind_deg,
               'is_offshore',         f.is_offshore,
               'plants',              f.plants,
               'turbines',            f.turbines,
               'nameplate_mw',        f.nameplate_mw
             ),
             'geometry', ST_AsGeoJSON(ST_Simplify(f.footprint::geometry, 0.02))::jsonb
           ) ORDER BY f.region_name)
       )) AS wind_regions_geojson
  FROM (
    SELECT r.region_name,
           r.country,
           r.prevailing_wind_deg,
           r.is_offshore,
           COUNT(DISTINCT p.plant_id)                                  AS plants,
           COUNT(t.turbine_id)                                         AS turbines,
           ROUND((SUM(p.rated_capacity_kw) / 1000.0)::numeric, 1)      AS nameplate_mw,
           -- Hull of the assets, buffered 60 km so it reads as a territory.
           ST_Buffer(
             ST_ConvexHull(ST_Collect(t.location::geometry))::geography,
             60000
           )                                                           AS footprint
      FROM regions r
      JOIN plants   p ON p.region_name = r.region_name
      JOIN turbines t ON t.plant_id    = p.plant_id
     GROUP BY r.region_name, r.country, r.prevailing_wind_deg, r.is_offshore
  ) f;

-- Compare the two shapes to see why the box was replaced. The footprint is a
-- small fraction of the envelope's area, because an envelope has to span every
-- site in the region including the empty ocean between them.
SELECT r.region_name,
       ROUND((ST_Area(r.boundary::geography) / 1e6)::numeric, 0)        AS envelope_km2,
       ROUND((ST_Area(ST_Buffer(ST_ConvexHull(ST_Collect(t.location::geometry))::geography,
                                60000)) / 1e6)::numeric, 0)            AS footprint_km2,
       ROUND((100.0 * ST_Area(ST_Buffer(ST_ConvexHull(ST_Collect(t.location::geometry))::geography, 60000))
              / NULLIF(ST_Area(r.boundary::geography), 0))::numeric, 1) AS pct_of_envelope
  FROM regions r
  JOIN plants   p ON p.region_name = r.region_name
  JOIN turbines t ON t.plant_id    = p.plant_id
 GROUP BY r.region_name, r.boundary
 ORDER BY r.region_name;


-- ============================================================================
-- ## Verify: the fleet
-- ============================================================================

-- Assert the fleet is the size that was asked for. This is not ceremony: the
-- turbine INSERT uses ON CONFLICT DO NOTHING on a GENERATED name, which is a
-- silent-data-loss combination — a name collision drops a machine without an
-- error. That is exactly how the LPAD truncation bug hid (150 turbines requested,
-- 99 created). If a generator is meant to produce a known number of rows, count
-- them.

SELECT p.plant_name,
       p.turbine_count AS expected,
       COUNT(t.turbine_id) AS actual
  FROM plants p
  LEFT JOIN turbines t ON t.plant_id = p.plant_id
 GROUP BY p.plant_id, p.plant_name, p.turbine_count
HAVING COUNT(t.turbine_id) <> p.turbine_count;

-- Expected: (0 rows). Anything here means turbines went missing.


SELECT r.region_name,
       r.country,
       COUNT(DISTINCT p.plant_id)                                    AS plants,
       COUNT(t.turbine_id)                                           AS turbines,
       ROUND((SUM(p.rated_capacity_kw) / 1000.0)::numeric, 1)        AS nameplate_mw,
       r.prevailing_wind_deg                                         AS wind_from_deg,
       BOOL_OR(r.is_offshore)                                        AS offshore
  FROM regions r
  LEFT JOIN plants   p ON p.region_name = r.region_name
  LEFT JOIN turbines t ON t.plant_id    = p.plant_id
 GROUP BY r.region_name, r.country, r.prevailing_wind_deg
 ORDER BY r.region_name;

-- With the defaults (12 plants, 8 turbines each) every region gets 2 plants and
-- 16 turbines. Set num_plants = 6 and each region gets exactly one.

SELECT p.plant_name,
       p.site_name,
       p.region_name,
       p.operator,
       p.model,
       p.turbine_count,
       ROUND((p.turbine_count * p.rated_capacity_kw / 1000.0)::numeric, 1) AS nameplate_mw,
       ROUND(p.spacing_crosswind_m::numeric, 0)                            AS crosswind_m,
       ROUND(p.spacing_downwind_m::numeric, 0)                             AS downwind_m,
       p.commissioned_at
  FROM plants p
 ORDER BY p.region_name, p.plant_name;


-- ============================================================================
-- ## Verify: the grid geometry is actually correct
-- ============================================================================
-- Measure the layout that was just built, rather than trusting the arithmetic.
-- For each plant, the nearest-neighbour distance should equal the crosswind
-- spacing, and the overall footprint should be about (cols-1)x(rows-1) spacings.

-- Nearest-neighbour distance comes from turbine_neighbors, which was just built
-- and is already bounded to ~9 rows per turbine. The tempting alternative —
--
--   CROSS JOIN LATERAL (SELECT MIN(ST_Distance(t.location, o.location))
--                         FROM turbines o WHERE o.plant_id = t.plant_id ...)
--
-- recomputes every pairwise distance in the plant and is O(n²), which made this
-- verification query the most expensive statement in the file at large plant
-- sizes. Reusing the precomputed table keeps the whole script linear.

SELECT p.plant_name,
       p.turbine_count,
       MAX(t.grid_col) + 1                                            AS cols,
       MAX(t.grid_row) + 1                                            AS rows,
       ROUND(p.spacing_crosswind_m::numeric, 0)                       AS intended_crosswind_m,
       ROUND(MIN(nn.nearest_m)::numeric, 0)                           AS measured_nearest_m,
       ROUND((ST_Area(ST_ConvexHull(ST_Collect(t.location::geometry))::geography)
              / 1e6)::numeric, 2)                                     AS footprint_km2
  FROM plants p
  JOIN turbines t ON t.plant_id = p.plant_id
  CROSS JOIN LATERAL (
    SELECT MIN(n.distance_m) AS nearest_m
      FROM turbine_neighbors n
     WHERE n.turbine_id = t.turbine_id
  ) nn
 GROUP BY p.plant_id, p.plant_name, p.turbine_count, p.spacing_crosswind_m
 ORDER BY p.plant_name
 LIMIT 6;

-- measured_nearest_m should match intended_crosswind_m to within a metre or two.
-- Any large discrepancy means the geodesic projection went wrong — most likely
-- a latitude/longitude transposition, or hand-rolled degree arithmetic creeping
-- back in.


-- ---------------------------------------------------------------------------
-- The grid must be ORIENTED correctly, not merely spaced correctly
-- ---------------------------------------------------------------------------
-- A mirrored or mis-rotated grid still has perfect spacing, so the check above
-- passes and everything looks fine. This is the check that actually catches it.
--
-- Take each turbine and its immediately-DOWNWIND neighbour (one grid row further
-- back, same column), then measure the bearing from the downwind one BACK to the
-- upwind one. That is the direction the wind comes from, so it must equal the
-- plant's grid bearing.
--
-- Measuring it the other way round gives grid_bearing + 180 and looks like a
-- catastrophic failure; measuring with the rotation wrong gives an error of twice
-- the bearing offset and looks like nothing much. Both are worth being able to
-- tell apart.

SELECT p.plant_name,
       ROUND(p.grid_bearing_deg::numeric, 0)                       AS intended_bearing,
       ROUND(AVG(DEGREES(ST_Azimuth(b.location, a.location)))::numeric, 1)
                                                                   AS measured_bearing,
       ROUND(AVG(angular_diff_deg(p.grid_bearing_deg,
                 DEGREES(ST_Azimuth(b.location, a.location))))::numeric, 2)
                                                                   AS error_deg,
       ROUND(AVG(ST_Distance(a.location, b.location))::numeric, 0) AS spacing_m,
       ROUND(p.spacing_downwind_m::numeric, 0)                     AS intended_downwind_m
  FROM plants p
  JOIN turbines a ON a.plant_id = p.plant_id
  -- TWO rows back, not one. The layout is staggered, so the machine one row ahead
  -- sits half a crosswind spacing to the side and its bearing is ~17 degrees off
  -- the axis by design. The row TWO ahead is the one that lines up, at twice the
  -- downwind spacing — so that is what verifies the rotation.
  JOIN turbines b ON b.plant_id = p.plant_id
                 AND b.grid_col = a.grid_col
                 AND b.grid_row = a.grid_row + 2
 GROUP BY p.plant_id, p.plant_name, p.grid_bearing_deg, p.spacing_downwind_m
 ORDER BY p.plant_name
 LIMIT 6;

-- error_deg must be ~0 for every plant, and spacing_m must match TWICE
-- intended_downwind_m, because this compares rows two apart. Anything else means
-- the rotation in the INSERT above is wrong, and the whole wake model is then
-- aimed in the wrong direction.

-- Every turbine must sit inside its plant's region. The grid extends a few km
-- from the centre, so a plant sited near a region edge could in principle spill
-- out; with these sites none do.
SELECT t.name, p.region_name
  FROM turbines t
  JOIN plants  p ON p.plant_id    = t.plant_id
  JOIN regions r ON r.region_name = p.region_name
 WHERE NOT ST_Contains(r.boundary, t.location::geometry);

-- Expected: (0 rows)


-- ============================================================================
-- ## Verify: wake geometry
-- ============================================================================
-- Which neighbours can shade a turbine, and how badly. Look at one plant's
-- middle turbine.

SELECT a.name                                     AS turbine,
       b.name                                     AS neighbour,
       ROUND(n.distance_m::numeric, 0)            AS distance_m,
       ROUND(n.rotor_diameters::numeric, 1)       AS separation_rotors,
       ROUND(n.bearing_deg::numeric, 0)           AS wind_from_deg,
       ROUND((n.jensen_deficit * 100)::numeric, 1) AS velocity_deficit_pct,
       -- Power scales with v^3, so a velocity deficit hurts far more than it looks.
       ROUND(((1 - POWER(1 - n.jensen_deficit, 3)) * 100)::numeric, 1) AS power_loss_pct,
       ROUND(n.wake_half_angle_deg::numeric, 1)   AS wake_half_angle_deg
  FROM turbine_neighbors n
  JOIN turbines a ON a.turbine_id = n.turbine_id
  JOIN turbines b ON b.turbine_id = n.neighbor_id
 WHERE a.name = (SELECT name FROM turbines ORDER BY name LIMIT 1)
 ORDER BY n.distance_m;

-- Read the wind_from_deg column against the plant's prevailing wind. The
-- neighbours whose bearing matches it are the ones that will actually shade this
-- turbine most of the time — and those are the wide-spaced downwind ones, by
-- design.

SELECT COUNT(*)                                          AS neighbour_pairs,
       ROUND(AVG(rotor_diameters)::numeric, 1)           AS avg_separation_rotors,
       ROUND(MIN(rotor_diameters)::numeric, 1)           AS min_separation_rotors,
       ROUND((AVG(jensen_deficit) * 100)::numeric, 1)    AS avg_deficit_pct,
       ROUND((MAX(jensen_deficit) * 100)::numeric, 1)    AS worst_deficit_pct
  FROM turbine_neighbors;

DROP TABLE tmp_sites;
