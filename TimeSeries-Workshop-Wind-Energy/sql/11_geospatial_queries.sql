-- ============================================================================
-- # Wind Energy — Step 11: Geospatial Query Gallery
-- ============================================================================
-- The PostGIS half of this workshop, now that there is data to query. Each section is
-- a question a wind-farm operator actually asks, and each one demonstrates a
-- different spatial verb.
--
-- The recurring theme: geography for measurement, geometry for construction.
-- Store geography(Point, 4326) so distances come back in metres on the
-- spheroid; cast to ::geometry only for the operations geography does not
-- implement, and cast back before measuring anything.
-- ============================================================================


-- ============================================================================
-- ## 1. ST_DWithin — turbines within X km of a point
-- ============================================================================
-- "A transformer substation at this location has failed. Which turbines are
-- affected?"
--
-- ST_DWithin(a, b, metres) is the right tool, and the reason is indexing.
-- Compare:
--
--   WHERE ST_Distance(location, point) < 50000      -- computes distance for
--                                                   -- EVERY row, no index
--   WHERE ST_DWithin(location, point, 50000)        -- uses the GiST index to
--                                                   -- discard most rows first
--
-- On geography, the third argument is always metres regardless of latitude —
-- one of the main reasons to prefer geography over geometry for GPS data.

SELECT t.name,
       pl.plant_name,
       pl.model,
       ROUND((ST_Distance(
                t.location,
                ST_SetSRID(ST_MakePoint(-101.83, 35.22), 4326)::geography
              ) / 1000)::numeric, 2) AS distance_km,
       ROUND(pl.rated_capacity_kw::numeric / 1000, 1) AS rated_mw
  FROM turbines t
  JOIN plants pl ON pl.plant_id = t.plant_id
 WHERE ST_DWithin(
         t.location,
         ST_SetSRID(ST_MakePoint(-101.83, 35.22), 4326)::geography,
         50000                                   -- 50 km, in metres
       )
 ORDER BY distance_km;

-- Every turbine of the Amarillo plant falls inside the radius, because a plant
-- is a few kilometres across — which is exactly the point of modelling plants:
-- a substation outage is a PLANT-level event, not a per-turbine one.

-- Combine the spatial filter with the time series to quantify the exposure:
-- how much generation is at risk inside that radius right now?

SELECT COUNT(*)                                           AS turbines_in_radius,
       COUNT(DISTINCT t.plant_id)                          AS plants_affected,
       ROUND(SUM(latest.power_kw)::numeric / 1000, 2)      AS mw_at_risk,
       ROUND(SUM(pl.rated_capacity_kw)::numeric / 1000, 2) AS rated_mw_in_radius
  FROM turbines t
  JOIN plants pl ON pl.plant_id = t.plant_id
  CROSS JOIN LATERAL (
         SELECT power_kw FROM power_generation p
          WHERE p.turbine_id = t.turbine_id
          ORDER BY p.time DESC LIMIT 1
       ) latest
 WHERE ST_DWithin(t.location,
                  ST_SetSRID(ST_MakePoint(-101.83, 35.22), 4326)::geography,
                  50000);


-- ============================================================================
-- ## 2. ST_Distance and the <-> operator — nearest turbines
-- ============================================================================
-- "A maintenance crew is at these coordinates. Which five turbines are closest?"
--
-- Two ways to order by distance, and the difference matters:
--
--   ORDER BY ST_Distance(...)   exact spheroidal distance, but computed for
--                               every candidate row.
--
--   ORDER BY location <-> pt    the KNN operator. The GiST index returns rows
--                               in distance order directly, so with a LIMIT it
--                               only ever examines the few rows it needs.
--
-- Two caveats on <-> that catch people out:
--
--   * On geography, <-> measures on a SPHERE while ST_Distance defaults to the
--     SPHEROID. They disagree by up to about 0.3%. The ordering is
--     effectively always the same, so the idiom is: order with <->, report the
--     distance with ST_Distance. That is exactly what this query does.
--
--   * The index is only used when one operand is a CONSTANT. Put the reference
--     point in a subquery, a CTE, or a correlated column reference and the
--     planner silently falls back to a sequential scan. Always EXPLAIN it.

SELECT t.name,
       pl.plant_name,
       pl.region_name,
       ROUND((ST_Distance(
                t.location,
                ST_SetSRID(ST_MakePoint(9.05, 54.47), 4326)::geography
              ) / 1000)::numeric, 2) AS distance_km
  FROM turbines t
  JOIN plants pl ON pl.plant_id = t.plant_id
 ORDER BY t.location <-> ST_SetSRID(ST_MakePoint(9.05, 54.47), 4326)::geography
 LIMIT 5;

-- Confirm the index is actually doing the work. You want to see
-- "Index Scan using idx_turbines_location" with an "Order By:" line — NOT a
-- "Seq Scan" followed by a "Sort".

EXPLAIN (COSTS OFF)
SELECT t.name
  FROM turbines t
 ORDER BY t.location <-> ST_SetSRID(ST_MakePoint(9.05, 54.47), 4326)::geography
 LIMIT 5;

-- At this fleet size PostgreSQL may well decide a sequential scan is cheaper
-- than the index — that is a correct decision, not a bug. The pattern is what
-- matters; at 40,000 turbines the index scan wins decisively. Force it with
-- SET enable_seqscan = off to see the plan you expect.


-- ============================================================================
-- ## 3. ST_Centroid and ST_Envelope — regional bounding boxes
-- ============================================================================
-- "Give me the map bounding box and centre point for each region, so the UI can
-- zoom to a region's assets."
--
-- Both functions are geometry-only, so we cast in, and cast back out for the
-- distance measurement. ST_Collect gathers many geometries into one collection
-- without doing any geometric work — cheap, and the right input for both.
--
-- ST_Envelope gives the axis-aligned bounding box: exactly what a mapping
-- library wants for fitBounds(). ST_ConvexHull would give a tighter shape that
-- follows the actual asset spread, which is better for "where do we operate"
-- and worse for zooming.

SELECT pl.region_name,
       COUNT(*) AS turbines,
       -- Centre of gravity of the region's assets.
       ST_AsText(ST_Centroid(ST_Collect(t.location::geometry)), 4) AS centroid,
       -- Bounding box corners, for map zoom.
       ROUND(ST_XMin(ST_Extent(t.location::geometry))::numeric, 3) AS min_lon,
       ROUND(ST_YMin(ST_Extent(t.location::geometry))::numeric, 3) AS min_lat,
       ROUND(ST_XMax(ST_Extent(t.location::geometry))::numeric, 3) AS max_lon,
       ROUND(ST_YMax(ST_Extent(t.location::geometry))::numeric, 3) AS max_lat,
       -- Diagonal of the bounding box in km — how spread out is this cluster?
       ROUND((ST_Distance(
                ST_SetSRID(ST_MakePoint(ST_XMin(ST_Extent(t.location::geometry)),
                                        ST_YMin(ST_Extent(t.location::geometry))), 4326)::geography,
                ST_SetSRID(ST_MakePoint(ST_XMax(ST_Extent(t.location::geometry)),
                                        ST_YMax(ST_Extent(t.location::geometry))), 4326)::geography
              ) / 1000)::numeric, 1) AS bbox_diagonal_km
  FROM turbines t
  JOIN plants pl ON pl.plant_id = t.plant_id
 GROUP BY pl.region_name
 ORDER BY pl.region_name;

-- Note ST_Extent returns a box2d, and ST_XMin/ST_YMin/etc. read its corners.
-- ST_Envelope(ST_Collect(...)) would give the same box as a proper polygon
-- geometry if you need to store it or send it as GeoJSON.


-- ============================================================================
-- ## 4. Point-in-polygon, revisited as a live query
-- ============================================================================
-- Step 04 used ST_Contains once, at seed time, to assign region_name. Here is
-- the same test as an ad-hoc query — "which region would a NEW turbine at these
-- coordinates belong to?" — which is what you would run when onboarding an
-- asset.

SELECT r.region_name,
       r.country
  FROM regions r
 WHERE ST_Contains(
         r.boundary,
         ST_SetSRID(ST_MakePoint(11.50, 52.20), 4326)   -- somewhere in Saxony-Anhalt
       );

-- ST_Contains vs ST_Intersects vs ST_Within is a classic source of confusion:
--   ST_Contains(A, B)    A completely contains B          (argument order matters)
--   ST_Within(B, A)      the same test, arguments swapped
--   ST_Intersects(A, B)  they share ANY space, including just touching edges
-- For "is this point inside that polygon", ST_Contains(polygon, point) is the
-- one you want.


-- ============================================================================
-- ## 5. Spatial correlation — do neighbouring turbines see the same weather?
-- ============================================================================
-- This is where the spatial and temporal halves of the workshop finally meet,
-- and it is the question that justifies storing geometry alongside a time
-- series at all.
--
-- Pair every turbine with every other, measure the physical distance between
-- them, and compare their wind speeds over the same hour. If the model is
-- behaving like weather, nearby turbines should agree closely and distant ones
-- should not.

WITH pairs AS (
  SELECT a.turbine_id      AS a_id,
         b.turbine_id      AS b_id,
         a.name            AS a_name,
         b.name            AS b_name,
         ROUND((ST_Distance(a.location, b.location) / 1000)::numeric, 0) AS distance_km
    FROM turbines a
    JOIN turbines b ON a.turbine_id < b.turbine_id   -- each pair once, no self-pairs
),
hourly AS (
  SELECT turbine_id, bucket, avg_wind_ms
    FROM cagg_turbine_power_hourly
   WHERE bucket >= now() - INTERVAL '7 days'
),
compared AS (
  SELECT p.distance_km,
         ABS(ha.avg_wind_ms - hb.avg_wind_ms) AS wind_difference_ms
    FROM pairs p
    JOIN hourly ha ON ha.turbine_id = p.a_id
    JOIN hourly hb ON hb.turbine_id = p.b_id AND hb.bucket = ha.bucket
)
SELECT CASE
         WHEN distance_km <    25 THEN '1. under 25 km (same farm)'
         WHEN distance_km <   100 THEN '2. 25-100 km'
         WHEN distance_km <   500 THEN '3. 100-500 km'
         WHEN distance_km <  1000 THEN '4. 500-1000 km'
         ELSE                          '5. 1000-2000 km'
       END                                              AS separation,
       COUNT(*)                                         AS hourly_comparisons,
       ROUND(AVG(wind_difference_ms)::numeric, 2)       AS avg_wind_difference_ms
  FROM compared
 WHERE distance_km < 2000
 GROUP BY separation
 ORDER BY separation;

--          separation          | hourly_comparisons | avg_wind_difference_ms
-- ----------------------------+--------------------+------------------------
--  1. under 25 km (same farm) |               1680 |                   0.98
--  2. 25-100 km               |               1344 |                   0.97
--  3. 100-500 km              |              13776 |                   1.82
--  4. 500-1000 km             |               7728 |                   3.42
--  5. 1000-2000 km            |              15456 |                   4.69
-- (5 rows)
--
-- Turbines in the same farm differ by about 1 m/s — essentially just sensor
-- noise, since they share the same weather. By 1000-2000 km the difference has
-- more than quadrupled: those turbines are under different weather systems.
--
-- This is the quantitative form of the argument for geographic
-- diversification. A portfolio concentrated in one wind regime has highly
-- correlated output, so a single becalmed week hits all of it at once; a
-- portfolio spread across regimes does not. Note that it cuts both ways: the
-- same correlation is why a single storm can knock out a whole region's output
-- within an hour, as the shutdown clustering in step 07 showed.
--
-- HONEST LIMITATION, and worth understanding before you trust a synthetic
-- dataset. The spatial phase in step 06 is a SINUSOID, with a wavelength of 55
-- degrees of longitude. Sinusoids are periodic, so once pairs are far enough
-- apart to wrap a full cycle they come back INTO phase and look correlated
-- again. Run the query without the distance cap to see it:
--
--   ... SELECT width_bucket(distance_km, 0, 16000, 16) * 1000 AS km_upper,
--              COUNT(*), ROUND(AVG(wind_difference_ms)::numeric, 2)
--         FROM compared GROUP BY 1 ORDER BY 1;
--
-- The difference peaks around 2000 km at roughly 4.7 m/s, then falls away to
-- about 1.5 m/s for antipodal pairs — which is physically meaningless. Below
-- 2000 km the model behaves like weather; beyond that it is an artifact.
--
-- A production system would not model this at all — it would ingest ERA5
-- reanalysis or a numerical weather prediction feed, where the spatial
-- correlation structure comes from actual physics. See the workshop README for
-- how to swap in live Open-Meteo data.
--
-- Note the shortest bucket here is "under 25 km", which lumps together turbines
-- in the same plant (a few hundred metres apart) with turbines in neighbouring
-- plants. The next section zooms inside a single plant, where the interesting
-- effect is no longer weather correlation but WAKE INTERACTION.


-- ============================================================================
-- ## 6. Inside a single plant — layout, and who shades whom
-- ============================================================================
-- Zoom all the way in. At this scale weather correlation is irrelevant (every
-- machine is under the same cloud); what matters is the geometry between them.
--
-- Render one plant's grid as text, with each turbine's average wake loss. The
-- shape of the numbers is the shape of the layout.

-- Aggregate per turbine FIRST, then string-aggregate the rows. Doing it in one
-- step — STRING_AGG(... AVG(...) ...) — fails with "aggregate function calls
-- cannot be nested", which is PostgreSQL correctly refusing an ambiguous query.

WITH per_turbine AS (
  SELECT t.turbine_id,
         t.name,
         t.grid_row,
         t.grid_col,
         AVG(c.avg_wake_loss_pct) AS wake_loss_pct
    FROM turbines t
    JOIN plants  p ON p.plant_id = t.plant_id
    JOIN cagg_turbine_power_hourly c USING (turbine_id)
   WHERE p.plant_name = (SELECT plant_name FROM plants ORDER BY plant_name LIMIT 1)
   GROUP BY t.turbine_id, t.name, t.grid_row, t.grid_col
)
SELECT grid_row,
       STRING_AGG(
         'T' || LPAD(SPLIT_PART(name, '-T', 2), 2, '0')
             || ' ' || LPAD(ROUND(wake_loss_pct::numeric, 1)::text, 5) || '%',
         '  |  ' ORDER BY grid_col
       ) AS row_upwind_to_downwind
  FROM per_turbine
 GROUP BY grid_row
 ORDER BY grid_row;

--  grid_row |            row_upwind_to_downwind
-- ----------+------------------------------------------------
--         0 | T01   5.9% |  T02  11.1% |  T03   8.1%
--         1 | T04   6.5% |  T05  10.2% |  T06   5.9%
--         2 | T07   1.6% |  T08   3.6%
-- (3 rows)

-- Rows run along the prevailing wind, so row 0 is the upwind edge. Wake loss
-- generally climbs as you move downwind and falls again at the far edge, and the
-- outer columns do better than the middle because they have clean air on one
-- side. That gradient is the whole reason wind farm layout is a paid speciality.


-- ---------------------------------------------------------------------------
-- Which turbine shades which, and by how much
-- ---------------------------------------------------------------------------
-- The wake geometry from step 04, joined to the actual measured loss. This is
-- the query an analyst runs when one machine underperforms its neighbours.

SELECT victim.name                                        AS turbine,
       victim.grid_row || ',' || victim.grid_col           AS grid_pos,
       culprit.name                                       AS shaded_by,
       ROUND(n.rotor_diameters::numeric, 1)               AS separation_rotors,
       ROUND(n.bearing_deg::numeric, 0)                   AS waked_when_wind_from,
       ROUND((n.jensen_deficit * 100)::numeric, 1)        AS velocity_deficit_pct,
       -- The fraction of all readings in which this pairing was actually active.
       ROUND((100.0 * COUNT(*) FILTER (
                WHERE angular_diff_deg(m.wind_direction_deg, n.bearing_deg)
                      <= n.wake_half_angle_deg)
              / NULLIF(COUNT(*), 0))::numeric, 1)         AS pct_of_time_waking
  FROM turbine_neighbors n
  JOIN turbines victim  ON victim.turbine_id  = n.turbine_id
  JOIN turbines culprit ON culprit.turbine_id = n.neighbor_id
  JOIN plants   p       ON p.plant_id         = n.plant_id
  JOIN wind_measurements m ON m.turbine_id    = n.turbine_id
 WHERE p.plant_name = (SELECT plant_name FROM plants ORDER BY plant_name LIMIT 1)
 GROUP BY victim.name, victim.grid_row, victim.grid_col, culprit.name,
          n.rotor_diameters, n.bearing_deg, n.jensen_deficit
HAVING COUNT(*) FILTER (WHERE angular_diff_deg(m.wind_direction_deg, n.bearing_deg)
                              <= n.wake_half_angle_deg) > 0
 ORDER BY pct_of_time_waking DESC
 LIMIT 12;

-- Two things to read here. The pairs with the highest pct_of_time_waking are the
-- ones aligned with the prevailing wind — the layout cannot avoid them, which is
-- precisely why those are the 8-rotor-diameter pairs rather than the 5D ones.
-- And separation_rotors is the lever: doubling it cuts the deficit roughly
-- fourfold, because the Jensen deficit falls as 1/(1 + 2kx/D)².


-- ---------------------------------------------------------------------------
-- Front row versus back row, measured
-- ---------------------------------------------------------------------------
-- The single most quotable number from the whole wake model.

WITH edges AS (
  SELECT t.turbine_id,
         t.plant_id,
         CASE
           WHEN t.grid_row = MIN(t.grid_row) OVER (PARTITION BY t.plant_id)
             THEN 'upwind edge'
           WHEN t.grid_row = MAX(t.grid_row) OVER (PARTITION BY t.plant_id)
             THEN 'downwind edge'
           ELSE 'interior'
         END AS position
    FROM turbines t
)
SELECT e.position,
       COUNT(DISTINCT e.turbine_id)                                AS turbines,
       ROUND(AVG(c.avg_wake_loss_pct)::numeric, 1)                 AS avg_wake_loss_pct,
       ROUND(AVG(c.avg_power_kw)::numeric, 0)                      AS avg_power_kw,
       ROUND((AVG(c.avg_power_kw) / AVG(p.rated_capacity_kw) * 100)::numeric, 1)
                                                                   AS capacity_factor_pct
  FROM edges e
  JOIN plants p                     ON p.plant_id = e.plant_id
  JOIN cagg_turbine_power_hourly c  ON c.turbine_id = e.turbine_id
 GROUP BY e.position
 ORDER BY avg_wake_loss_pct;

-- The upwind edge always wins: it is standing in clean air by definition. In real
-- projects this gradient is large enough that front-row turbines are used to
-- calibrate the wake model for the rest of the site, and large enough that
-- landowners with front-row parcels negotiate harder.


-- ============================================================================
-- ## 7. Plant footprints — the map overlay geometry
-- ============================================================================
-- Each plant's physical extent, derived from its turbines. ST_ConvexHull of the
-- turbine positions is the site boundary as built; ST_Centroid is the point a map
-- should label.
--
-- Note the ::geography casts around the area calculation. ST_Area on a geometry
-- in SRID 4326 returns SQUARE DEGREES, which is not a unit of area — the number
-- is meaningless and silently varies with latitude. Casting to geography gives
-- square metres on the spheroid.

SELECT p.plant_name,
       p.region_name,
       p.turbine_count,
       ROUND((p.turbine_count * p.rated_capacity_kw / 1000.0)::numeric, 1) AS nameplate_mw,
       ST_AsText(ST_Centroid(ST_Collect(t.location::geometry)), 4)         AS centroid,
       -- Hull through the turbine CENTRES, then buffered outward by half the
       -- crosswind spacing. The buffer matters: a bare hull measures the polygon
       -- joining the outermost turbines, which for a small array badly understates
       -- the land actually occupied — an 8-turbine site comes out roughly 40%
       -- smaller than it really is, and the power density correspondingly
       -- inflated. ST_Buffer on geography works in metres.
       ROUND((ST_Area(ST_Buffer(ST_ConvexHull(ST_Collect(t.location::geometry))::geography,
                                p.spacing_crosswind_m / 2.0))
              / 1e6)::numeric, 2)                                         AS footprint_km2,
       -- Power density: MW per square kilometre of site.
       ROUND((p.turbine_count * p.rated_capacity_kw / 1000.0
              / NULLIF(ST_Area(ST_Buffer(ST_ConvexHull(ST_Collect(t.location::geometry))::geography,
                                         p.spacing_crosswind_m / 2.0)) / 1e6, 0))::numeric, 2)
                                                                          AS mw_per_km2
  FROM plants p
  JOIN turbines t ON t.plant_id = p.plant_id
 GROUP BY p.plant_id, p.plant_name, p.region_name, p.turbine_count, p.rated_capacity_kw
 ORDER BY mw_per_km2 DESC;

-- The offshore plants show the highest MW/km² because the machines are so much
-- larger, not because they are packed tighter — their spacing in rotor diameters
-- is the same or wider. Comparing power density without normalising for turbine
-- size is a classic way to reach the wrong conclusion about a layout.
--
-- Two honest caveats on the absolute numbers. Real utility-scale projects quote
-- 2-5 MW/km², and small arrays like these read higher because an 8-turbine site
-- is nearly all edge — the buffered hull still under-counts the land a real
-- project ties up in setbacks, access roads and property lines. Raise
-- turbines_per_plant to 25 or 36 and watch the density fall toward the published
-- range as the interior starts to dominate. That convergence is itself the point:
-- power density is an area-to-perimeter artefact at small scale.


-- ---------------------------------------------------------------------------
-- Do any plants overlap, or sit close enough to wake each other?
-- ---------------------------------------------------------------------------
-- A real question in mature wind regions: neighbouring developments genuinely
-- steal each other's wind, and it ends up in court. Our wake model deliberately
-- stops at the plant boundary, so this query finds cases the model ignores.

SELECT a.plant_name                                              AS plant_a,
       b.plant_name                                              AS plant_b,
       ROUND((ST_Distance(a.center_location, b.center_location) / 1000)::numeric, 1)
                                                                 AS centre_distance_km,
       ROUND((ST_Distance(a.center_location, b.center_location)
              / a.rotor_diameter_m)::numeric, 0)                 AS separation_rotors
  FROM plants a
  JOIN plants b ON a.plant_id < b.plant_id
               AND a.region_name = b.region_name
 WHERE ST_DWithin(a.center_location, b.center_location, 30000)    -- within 30 km
 ORDER BY centre_distance_km;

-- With the shipped site catalogue the plants are far enough apart that this
-- returns nothing. Seed two plants at neighbouring towns and it will start
-- finding pairs — at which point a serious model would extend the wake
-- calculation across plant boundaries instead of stopping at them.


-- ============================================================================
-- ## 8. Finding underperforming turbines
-- ============================================================================
-- A turbine that is quietly making 8% less than it should is worth more to find
-- than almost anything else in this dataset. Over a year on a 4 MW machine at a
-- 35% capacity factor, 8% is roughly 980 MWh — real money, and completely
-- invisible in an output chart.
--
-- The reason it is invisible: output alone cannot distinguish "light wind" from
-- "broken". 800 kW is excellent in a 6 m/s breeze and alarming in a gale. So every
-- method below compares actual output against EXPECTED output — what the power
-- curve says the wind that turbine actually measured should have produced.
--
-- power_generation stores both, so the comparison is a division:
--
--     performance ratio = SUM(power_kw) / SUM(expected_power_kw)
--
-- Both are powers, so this is valid at any grain: turbine, plant, region, fleet.
--
-- `turbine_faults` is the ANSWER KEY. None of the detectors below look at it. The
-- last query scores them against it — which is a luxury no real analytics team
-- gets, and exactly why it is worth doing here.


-- ---------------------------------------------------------------------------
-- Detector 1: rank by performance ratio
-- ---------------------------------------------------------------------------
-- The blunt instrument, and it works for step faults. Reads the turbine tier.

SELECT h.turbine_name,
       h.plant_name,
       h.region_name,
       ROUND(AVG(h.performance_ratio_pct)::numeric, 1)   AS performance_ratio_pct,
       ROUND(AVG(h.capacity_factor_pct)::numeric, 1)     AS capacity_factor_pct,
       ROUND(SUM(h.lost_kw)::numeric, 0)                 AS lost_kwh_in_window,
       COUNT(*)                                          AS hours
  FROM v_turbine_hourly h
 WHERE h.bucket >= now() - INTERVAL '7 days'
 GROUP BY h.turbine_name, h.plant_name, h.region_name
HAVING AVG(h.performance_ratio_pct) < 96
 ORDER BY performance_ratio_pct
 LIMIT 20;

-- Note capacity_factor_pct alongside. It is all over the place — some suspects
-- have high CF and some low — which is precisely why a CF-based alarm is useless
-- for this job. The two columns measure different things.


-- ---------------------------------------------------------------------------
-- Detector 2: trend — catching the gradual faults
-- ---------------------------------------------------------------------------
-- Soiling and erosion ramp in over weeks. On any single day they look normal, so
-- detector 1 misses them until they are expensive. Compare a recent window
-- against an older baseline for the SAME turbine and the drift appears.

WITH windows AS (
  SELECT h.turbine_id,
         h.turbine_name,
         h.plant_name,
         SUM(h.avg_power_kw)          FILTER (WHERE h.bucket >= now() - INTERVAL '3 days')  AS recent_act,
         SUM(h.avg_expected_power_kw) FILTER (WHERE h.bucket >= now() - INTERVAL '3 days')  AS recent_exp,
         SUM(h.avg_power_kw)          FILTER (WHERE h.bucket <  now() - INTERVAL '21 days') AS base_act,
         SUM(h.avg_expected_power_kw) FILTER (WHERE h.bucket <  now() - INTERVAL '21 days') AS base_exp
    FROM v_turbine_hourly h
   GROUP BY h.turbine_id, h.turbine_name, h.plant_name
)
SELECT turbine_name,
       plant_name,
       ROUND((100.0 * base_act   / NULLIF(base_exp, 0))::numeric, 1)   AS baseline_pr_pct,
       ROUND((100.0 * recent_act / NULLIF(recent_exp, 0))::numeric, 1) AS recent_pr_pct,
       ROUND((100.0 * recent_act / NULLIF(recent_exp, 0)
              - 100.0 * base_act / NULLIF(base_exp, 0))::numeric, 1)   AS drift_pct_points
  FROM windows
 WHERE base_exp > 0 AND recent_exp > 0
 ORDER BY drift_pct_points
 LIMIT 15;

-- A drift of -3 percentage points or worse is a degrading machine. Positive drift
-- means a fault was REPAIRED during the window — the resolved grid curtailment in
-- the seed data shows up here as a strong positive.


-- ---------------------------------------------------------------------------
-- Detector 3: peer comparison inside a plant
-- ---------------------------------------------------------------------------
-- The most sensitive method, and the one that needs the geometry.
--
-- Turbines in the same plant are within a few kilometres of each other, share the
-- same model, and see the same weather. Wake losses differ by grid position — so
-- compare each turbine's performance ratio against its plant's MEDIAN, and any
-- residual gap is the machine itself rather than the wind or the site.
--
-- This is why the fleet is modelled as plants rather than loose turbines: the peer
-- group is what makes a 3% anomaly detectable.

WITH per_turbine AS (
  SELECT h.plant_id, h.plant_name, h.turbine_id, h.turbine_name,
         t.grid_row, t.grid_col,
         SUM(h.avg_power_kw) / NULLIF(SUM(h.avg_expected_power_kw), 0) * 100 AS pr_pct,
         AVG(h.avg_wake_loss_pct)                                           AS wake_pct
    FROM v_turbine_hourly h
    JOIN turbines t ON t.turbine_id = h.turbine_id
   WHERE h.bucket >= now() - INTERVAL '7 days'
   GROUP BY h.plant_id, h.plant_name, h.turbine_id, h.turbine_name, t.grid_row, t.grid_col
),
-- PERCENTILE_CONT is an ORDERED-SET aggregate, and PostgreSQL does not allow
-- those as window functions:
--   ERROR:  OVER is not supported for ordered-set aggregate percentile_cont
-- So aggregate the median per plant separately and join it back, rather than
-- reaching for OVER (PARTITION BY ...).
plant_median AS (
  SELECT plant_id,
         PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY pr_pct) AS plant_median_pr
    FROM per_turbine
   GROUP BY plant_id
),
with_peers AS (
  SELECT p.*, m.plant_median_pr
    FROM per_turbine p
    JOIN plant_median m USING (plant_id)
)
SELECT turbine_name,
       plant_name,
       grid_row || ',' || grid_col                       AS grid_pos,
       ROUND(pr_pct::numeric, 1)                         AS turbine_pr_pct,
       ROUND(plant_median_pr::numeric, 1)                AS plant_median_pr_pct,
       ROUND((pr_pct - plant_median_pr)::numeric, 1)     AS vs_peers_pct_points,
       ROUND(wake_pct::numeric, 1)                       AS wake_loss_pct
  FROM with_peers
 WHERE pr_pct - plant_median_pr < -1.5
 ORDER BY vs_peers_pct_points
 LIMIT 15;

-- Read wake_loss_pct in the last column: it is NOT correlated with the peer gap.
-- Wake loss is a property of grid POSITION; underperformance is a property of the
-- MACHINE. Storing both separately is what lets you tell them apart — and a
-- monitoring system that conflates them will chase the back row of every array
-- forever.


-- ---------------------------------------------------------------------------
-- Scoring the detectors against the answer key
-- ---------------------------------------------------------------------------
-- Now look at turbine_faults, and only now. For each turbine, did the simple
-- threshold detector fire, and was it actually faulted?

WITH detected AS (
  SELECT h.turbine_id,
         SUM(h.avg_power_kw) / NULLIF(SUM(h.avg_expected_power_kw), 0) < 0.96 AS flagged
    FROM v_turbine_hourly h
   WHERE h.bucket >= now() - INTERVAL '7 days'
   GROUP BY h.turbine_id
),
truth AS (
  SELECT t.turbine_id,
         EXISTS (SELECT 1 FROM turbine_faults f
                  WHERE f.turbine_id = t.turbine_id
                    AND f.resolved_at IS NULL) AS actually_faulted
    FROM turbines t
)
SELECT CASE WHEN d.flagged AND tr.actually_faulted      THEN '1. true positive  (caught it)'
            WHEN d.flagged AND NOT tr.actually_faulted  THEN '2. false positive (wild goose chase)'
            WHEN NOT d.flagged AND tr.actually_faulted  THEN '3. FALSE NEGATIVE (missed it)'
            ELSE                                             '4. true negative  (correctly quiet)'
       END      AS outcome,
       COUNT(*) AS turbines
  FROM detected d
  JOIN truth tr USING (turbine_id)
 GROUP BY outcome
 ORDER BY outcome;

-- Two rows deserve attention.
--
-- FALSE NEGATIVES are gradual faults whose ramp has not yet pushed them past the
-- 4% threshold. The seed data includes one deliberately: a blade erosion fault ten
-- days into a ninety-day ramp, currently costing under 1%. A threshold alarm
-- cannot see it. Detector 2 (trend) and detector 3 (peers) exist for exactly this
-- case, and lowering the threshold to catch it would flood the operations team
-- with false positives.
--
-- FALSE POSITIVES are turbines flagged with no fault recorded. They are not
-- necessarily detector failures — a turbine on the downwind edge of a dense array
-- genuinely produces less, and if its peers are in cleaner air the threshold fires.
-- That is why detector 3 compares against a PLANT MEDIAN rather than a fleet-wide
-- constant.
--
-- Which turbines did the threshold miss, and why?
SELECT t.name        AS turbine,
       f.fault_type,
       ROUND((f.severity * 100)::numeric, 1)                              AS full_severity_pct,
       f.ramp_days,
       (now()::date - f.started_at::date)                                 AS days_running,
       ROUND(((1 - turbine_health(t.turbine_id, now())) * 100)::numeric, 1) AS derate_now_pct,
       ROUND((100.0 * SUM(h.avg_power_kw)
              / NULLIF(SUM(h.avg_expected_power_kw), 0))::numeric, 1)     AS measured_pr_pct
  FROM turbine_faults f
  JOIN turbines t ON t.turbine_id = f.turbine_id
  JOIN v_turbine_hourly h ON h.turbine_id = t.turbine_id
                         AND h.bucket >= now() - INTERVAL '7 days'
 WHERE f.resolved_at IS NULL
 GROUP BY t.turbine_id, t.name, f.fault_type, f.severity, f.ramp_days, f.started_at
HAVING 100.0 * SUM(h.avg_power_kw) / NULLIF(SUM(h.avg_expected_power_kw), 0) >= 96
 ORDER BY derate_now_pct DESC;

-- Compare full_severity_pct with derate_now_pct: these are faults still partway
-- up their ramp. They will cross the threshold eventually — the question a real
-- operator faces is whether to act now on weaker evidence.
