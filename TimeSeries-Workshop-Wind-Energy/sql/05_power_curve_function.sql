-- ============================================================================
-- # Wind Energy — Step 05: The Power Curve
-- ============================================================================
-- The centrepiece of this workshop. Power output is NOT a stored measurement and NOT
-- a lookup table — it is computed from wind speed and turbine geometry by a
-- single IMMUTABLE function.
--
-- Why that matters:
--
--   * One source of truth. Backfill, live generation, and any ad-hoc query all
--     call the same function, so they cannot disagree.
--
--   * Reproducible. Same inputs, same output, forever. If the model improves
--     you can recompute every historical power_generation row from the
--     preserved wind_measurements rows.
--
--   * Usable everywhere. Because it is IMMUTABLE, PostgreSQL will accept it in
--     index expressions, generated columns, and continuous aggregate
--     definitions. A VOLATILE function (anything calling random() or now())
--     could not be used that way.
-- ============================================================================


-- ============================================================================
-- ## The physics
-- ============================================================================
-- The power available in moving air through a disc of area A:
--
--     P = 0.5 * rho * A * Cp * v^3
--
--   rho  air density, 1.225 kg/m^3 at sea level and 15 C
--   A    swept area of the rotor, pi * (diameter/2)^2
--   Cp   power coefficient — the fraction of wind energy the rotor captures
--   v    wind speed in m/s
--
-- The v^3 term is the whole story of wind energy. Double the wind speed and
-- you get EIGHT times the power. It is why siting matters so much, and why a
-- turbine at a 7 m/s site is worth far more than 17% more than one at 6 m/s.
--
-- Three regimes, and the function must handle all three:
--
--   v < cut_in     0 kW. There is not enough torque to overcome drivetrain
--                  friction, so the rotor is parked.
--
--   cut_in <= v    P = 0.5*rho*A*Cp*v^3, capped at the generator's rated
--   < cut_out      capacity. Beyond rated wind speed the blades are actively
--                  pitched to spill the excess — the machine could physically
--                  make more power, but the generator and grid connection
--                  cannot take it.
--
--   v >= cut_out   0 kW. Not a limitation — a deliberate safety shutdown to
--                  protect the structure in a storm. This produces the
--                  counter-intuitive shape of a real power curve: output falls
--                  off a cliff to zero in the highest winds.
--
-- Simplifying assumption worth stating out loud: we treat Cp as a constant
-- 0.40. In a real turbine Cp varies with tip-speed ratio and blade pitch,
-- peaking around 0.45-0.50 in the mid range and falling off at both ends. The
-- Betz limit — the theoretical maximum for ANY open-rotor device — is 16/27,
-- about 0.593. A constant 0.40 keeps the function readable and lands rated
-- power at a realistic wind speed; it slightly overstates output at the low
-- end of the curve.

CREATE OR REPLACE FUNCTION power_from_wind_speed(
  p_wind_speed_ms     DOUBLE PRECISION,
  p_cut_in_ms         DOUBLE PRECISION,
  p_cut_out_ms        DOUBLE PRECISION,
  p_rotor_diameter_m  DOUBLE PRECISION,
  p_rated_capacity_kw DOUBLE PRECISION
) RETURNS DOUBLE PRECISION
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT CASE
           -- Missing reading: propagate NULL rather than inventing a zero.
           -- A parked turbine and a broken anemometer are different facts.
           WHEN p_wind_speed_ms IS NULL THEN NULL

           -- Below cut-in: rotor parked.
           WHEN p_wind_speed_ms < p_cut_in_ms THEN 0.0

           -- At or above cut-out: storm shutdown.
           WHEN p_wind_speed_ms >= p_cut_out_ms THEN 0.0

           -- Productive range, clipped at rated capacity.
           ELSE LEAST(
                  p_rated_capacity_kw,
                  0.5
                  * 1.225                                                    -- rho, kg/m^3
                  * (pi() * power(p_rotor_diameter_m / 2.0, 2))              -- swept area, m^2
                  * 0.40                                                     -- Cp
                  * power(p_wind_speed_ms, 3)                                -- v^3
                  / 1000.0                                                   -- W -> kW
                )
         END;
$$;

COMMENT ON FUNCTION power_from_wind_speed IS
  'Turbine power output in kW derived from wind speed via P = 0.5*rho*A*Cp*v^3, '
  'zero below cut-in and at/above cut-out, clipped at rated capacity.';


-- ============================================================================
-- ## Inspect the curve
-- ============================================================================
-- Walk a Vestas V150-4.2 (150 m rotor, 4200 kW rated, cut-in 3, cut-out 22.5)
-- through its whole operating range. Reading this table is the fastest way to
-- understand why wind forecasting is worth so much money.

SELECT v                                                        AS wind_ms,
       ROUND(power_from_wind_speed(v, 3.0, 22.5, 150, 4200)::numeric, 0) AS power_kw,
       ROUND((power_from_wind_speed(v, 3.0, 22.5, 150, 4200)
              / 4200 * 100)::numeric, 0)                        AS pct_of_rated
  FROM generate_series(0, 25, 1) AS g(v)
 ORDER BY v;

--  wind_ms | power_kw | pct_of_rated
-- ---------+----------+--------------
--        0 |        0 |            0
--        1 |        0 |            0     <- below cut-in
--        2 |        0 |            0
--        3 |      117 |            3     <- cut-in: production starts
--        4 |      277 |            7
--        5 |      541 |           13
--        6 |      935 |           22
--        7 |     1485 |           35
--        8 |     2217 |           53
--        9 |     3156 |           75
--       10 |     4200 |          100     <- rated power reached (~9.9 m/s)
--       11 |     4200 |          100     <- pitch control spills the excess
--      ... |     4200 |          100
--       22 |     4200 |          100
--       23 |        0 |            0     <- cut-out: storm shutdown
--       24 |        0 |            0
--       25 |        0 |            0
-- (26 rows)

-- The cliff at 23 m/s is the single most surprising feature of wind
-- generation. On the stormiest day of the year, a whole region's output can
-- drop to zero within minutes as turbines hit cut-out one after another —
-- which is exactly the kind of correlated, geographically-clustered event the
-- regional continuous aggregate in step 08 is built to surface.


-- ============================================================================
-- ## Sanity checks
-- ============================================================================
-- Rated wind speed per model in our fleet: the lowest wind speed at which each
-- machine reaches 100% output. Real datasheets put this at 10-13 m/s, so these
-- numbers confirm the constant-Cp approximation is in a defensible range.

-- Note this reads `plants`, not `turbines`. Turbine specifications live on the
-- plant, because a wind farm is procured as one order and every machine on site
-- is the same model.

SELECT DISTINCT
       p.model,
       p.rotor_diameter_m,
       p.rated_capacity_kw,
       ROUND(power(p.rated_capacity_kw * 1000.0
                   / (0.5 * 1.225 * pi() * power(p.rotor_diameter_m / 2.0, 2) * 0.40),
                   1.0 / 3.0)::numeric, 1) AS rated_wind_ms
  FROM plants p
 ORDER BY p.model;

-- Every model should land between roughly 9 and 12 m/s.
