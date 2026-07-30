-- ============================================================================
-- generate_sensor_data.sql
-- ----------------------------------------------------------------------------
-- Generates the two workshop CSV files — sensors.csv and data.csv — entirely
-- in SQL using generate_series(), replacing the former Python generator.
--
-- Run it with psql connected to ANY PostgreSQL / Tiger Cloud service. The
-- \copy commands run on the CLIENT, so the CSVs are written to your LOCAL
-- current working directory (no files are left on the server):
--
--     psql "<your-service-connection-string>" -f generate_sensor_data.sql
--
-- Output (identical columns to the original Python script):
--   sensors.csv : sensor_id, model, location
--   data.csv    : timestamp, sensor_id, temperature, humidity
--
-- Data shape: 20 sensors x 1-minute readings over the last 60 days
-- (~1.73M rows), with a daily temperature cycle (peaks around midday), a
-- weekday/weekend offset, and Gaussian noise — matching the Python output.
-- ============================================================================

\set ON_ERROR_STOP on

\echo 'Generating sensor metadata and time-series readings...'

-- ----------------------------------------------------------------------------
-- Per-sensor metadata.
-- Materialising into a TEMP table FREEZES the random() draws, so every reading
-- for a given sensor shares the same baseline (mirrors the Python base_temp /
-- base_humidity that are drawn once per sensor).
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS gen_sensors;
CREATE TEMP TABLE gen_sensors AS
SELECT
    'sensor_' || lpad(i::text, 3, '0')                                  AS sensor_id,
    (ARRAY['TempSense-Pro','ClimateGuard-X1',
           'EnviroMonitor-2000','SensorMax-Elite'])[1 + floor(random()*4)::int]
                                                                        AS model,
    'Room ' || i                                                        AS location,
    18.0 + random() * 6.0                                               AS base_temp,     -- uniform 18..24
    40.0 + random() * 20.0                                              AS base_humidity  -- uniform 40..60
FROM generate_series(1, 20) AS i;

-- ----------------------------------------------------------------------------
-- Reading generator. A view keeps the row-level expressions (including the
-- Gaussian noise) evaluated lazily at \copy time.
--
--   daily cycle   : 3*sin((hour-6)*pi/12) for temperature, inverse for humidity
--                   (peaks around midday, troughs overnight)
--   weekly offset : cooler/more humid on weekends (dow 0=Sun, 6=Sat)
--   noise         : Box-Muller transform turns two uniform random() draws into
--                   a standard normal; scaled by 0.5 (temp) and 2.0 (humidity)
--   humidity clamp: greatest(20, least(80, ...))
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS gen_readings;
CREATE TEMP VIEW gen_readings AS
SELECT
    to_char(g.ts, 'YYYY-MM-DD HH24:MI:SS')                              AS "timestamp",
    s.sensor_id,
    round((
        s.base_temp
        + 3.0 * sin((extract(hour from g.ts) + extract(minute from g.ts) / 60.0 - 6) * pi() / 12.0)
        + (case when extract(dow from g.ts) in (0, 6) then -2.0 else 1.0 end)
        + 0.5 * sqrt(-2.0 * ln(1 - random())) * cos(2.0 * pi() * random())
    )::numeric, 2)                                                      AS temperature,
    round(greatest(20.0, least(80.0,
        s.base_humidity
        + (-5.0) * sin((extract(hour from g.ts) + extract(minute from g.ts) / 60.0 - 6) * pi() / 12.0)
        + (case when extract(dow from g.ts) in (0, 6) then 5.0 else -2.0 end)
        + 2.0 * sqrt(-2.0 * ln(1 - random())) * cos(2.0 * pi() * random())
    ))::numeric, 2)                                                     AS humidity
FROM gen_sensors s
CROSS JOIN generate_series(
        date_trunc('minute', now() - interval '60 days')::timestamp,
        date_trunc('minute', now())::timestamp,
        interval '1 minute') AS g(ts);

-- ----------------------------------------------------------------------------
-- Write the two CSV files to the client's current directory.
-- (Each \copy must stay on a single line — this is a psql meta-command.)
-- ----------------------------------------------------------------------------
\copy (SELECT sensor_id, model, location FROM gen_sensors ORDER BY sensor_id) TO 'sensors.csv' WITH (FORMAT CSV, HEADER)
\echo '  -> wrote sensors.csv (20 sensors)'

\copy (SELECT "timestamp", sensor_id, temperature, humidity FROM gen_readings ORDER BY sensor_id, "timestamp") TO 'data.csv' WITH (FORMAT CSV, HEADER)
\echo '  -> wrote data.csv (20 sensors x 1-minute readings over 60 days)'

\echo 'Done. sensors.csv and data.csv are in your current directory.'
