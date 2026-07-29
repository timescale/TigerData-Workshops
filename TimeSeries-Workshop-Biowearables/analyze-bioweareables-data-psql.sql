-- ============================================================================
-- # Biowearables Health Monitoring System (IoT Data Analysis)
-- ============================================================================
--
-- This system tracks health metrics from wearable devices including:
-- - Heart Rate (BPM)
-- - Blood Pressure (Systolic/Diastolic)
-- - Blood Oxygen Saturation (SpO2)
-- - Body Temperature
-- - Steps Count
-- - Sleep Quality Score
--
-- Use case: Remote patient monitoring, fitness tracking, and health analytics
  

-- ============================================================================
-- ## Prerequisites
-- ============================================================================
-- To follow the steps on this page:
--
-- 1. Create a target Timescale Cloud service with time-series and analytics enabled.
--    https://console.cloud.timescale.com/signup
--
-- 2. You need your connection details like:
--    "postgres://tsdbadmin:xxxxxxx.yyyyy.tsdb.cloud.timescale.com:39966/tsdb?sslmode=require"
--
-- 3. using psql cli connect to your Timescale Cloud service:
--    psql -d "postgres://tsdbadmin:xxxxxxx.yyyyy.tsdb.cloud.timescale.com:39966/tsdb?sslmode=require"


-- ============================================================================
-- ## Setup
-- ============================================================================
-- ### Drop tables and associated objects
DROP TABLE IF EXISTS wearable_devices CASCADE;
DROP TABLE IF EXISTS health_data CASCADE;
DROP TABLE IF EXISTS users CASCADE;


-- ============================================================================
-- ## Create Tables
-- ============================================================================
-- Create a hypertable to store the real-time biometric data
-- To enable columnarstore, you need to set the tsdb.hypertable
-- parameter to true.
-- The tsdb.orderby parameter specifies the order in which the
-- data is compressed.
-- The tsdb.segmentby parameter specifies the column by which the data
-- is segmented. The segmentby column is used to group the data into segments,
-- which are then compressed separately.


-- Create the health_data hypertable
CREATE TABLE health_data (
   time TIMESTAMPTZ NOT NULL,
   device_id INTEGER,
   heart_rate INTEGER,  -- BPM
   blood_pressure_systolic INTEGER,  -- mmHg
   blood_pressure_diastolic INTEGER,  -- mmHg
   spo2 DOUBLE PRECISION,  -- Blood oxygen saturation %
   body_temperature DOUBLE PRECISION,  -- Celsius
   steps_count INTEGER,  -- Daily cumulative steps
   sleep_quality_score DOUBLE PRECISION,  -- 0-100 scale
   activity_level TEXT  -- sedentary, light, moderate, vigorous
) WITH (
   tsdb.hypertable,
   tsdb.partition_column='time',
   tsdb.segmentby='device_id',
   tsdb.orderby='time DESC'
);


-- Create a standard PostgreSQL table for relational data
CREATE TABLE users(
   id SERIAL PRIMARY KEY,
   name VARCHAR(100), -- consider conversing to TEXT if field used in TigerData C-Aggs
   age INTEGER,
   gender VARCHAR(10),
   medical_conditions TEXT
);


CREATE TABLE wearable_devices(
   id SERIAL PRIMARY KEY,
   user_id INTEGER,
   device_type VARCHAR(50),  -- smartwatch, fitness_band, patch, ring
   device_model VARCHAR(100),
   firmware_version VARCHAR(20)
);



-- ============================================================================
-- ## Create Indexes
-- ============================================================================
-- Indexes are used to speed up the retrieval of data from a database table.
-- In this case, you create an index on the device_id column of the health_data 
-- table. Hypertables automatically create indexes on the
-- time column, so you don't need to create an index on that column.


CREATE INDEX ON health_data (device_id, time);
CREATE INDEX ON health_data (heart_rate, time DESC);
CREATE INDEX ON health_data (blood_pressure_systolic, time DESC);


-- If you have sparse data, with columns that are often NULL, 
-- you can add a clause to the index, saying WHERE column IS NOT NULL. 
-- This prevents the index from indexing NULL data, 
-- which can lead to a more compact and efficient index.


CREATE INDEX ON health_data (blood_pressure_systolic, time DESC)
  WHERE blood_pressure_systolic IS NOT NULL;


-- Configurable sparse indexes: 
-- lightweight metadata structures created on compressed chunks
-- to allow efficient filtering without needing full B-tree indexes.
-- They are designed to reduce I/O and improve query performance on compressed data

-- Types of sparse indexes
-- Minmax: Stores the minimum and maximum values for an ORDER BY column
-- (or any chosen column) in each compressed segment. 
-- Ideal for range filters (e.g., WHERE ts BETWEEN ...).
-- Bloom: Uses a probabilistic Bloom filter to record whether a value might exist in a segment.
-- Best for equality lookups or "existence" queries on high-cardinality
-- columns (e.g., UUIDs, device IDs) without decompressing

-- Ideal for queries like:
-- Point lookups - WHERE device_id = 20050 (sparse value)
-- Range queries - SELECT count(*) WHERE heart_rate BETWEEN 90 AND 95
-- Attribute filtering - SELECT count(*) WHERE device_id BETWEEN 1000 AND 1100
-- Exclusion queries - SELECT count(*) WHERE device_id > 4000

-- Make sure that the sparse index creation is set to TRUE
SET timescaledb.enable_sparse_index_bloom TO true;

-- In the case where a measurement is very likely to exist in all chunks/segments 
-- eg heart rate of 80 bpm, use bloom index to check is a value might exist in a segment

ALTER TABLE health_data SET (
   timescaledb.compress_index =
'bloom(body_temperature), bloom(heart_rate), minmax(blood_pressure_systolic)');

-- If you have sparse data, with columns that are often NULL, 
-- you can add a clause to the index, saying WHERE column IS NOT NULL. 
-- This prevents the index from indexing NULL data, 
-- which can lead to a more compact and efficient index.


-- ============================================================================
-- ## Populate the users table
-- ============================================================================
INSERT INTO users (name, age, gender, medical_conditions) VALUES
('Alice Johnson', 34, 'Female', 'None'),
('Bob Smith', 58, 'Male', 'Hypertension'),
('Carol White', 45, 'Female', 'Diabetes Type 2'),
('David Brown', 29, 'Male', 'None');


-- ============================================================================
-- ## Populate the wearable_devices table
-- ============================================================================
INSERT INTO wearable_devices (user_id, device_type, device_model, firmware_version) VALUES
(1, 'smartwatch', 'Apple Watch Series 9', '10.2'),
(2, 'fitness_band', 'Fitbit Charge 6', '2.4.1'),
(3, 'smartwatch', 'Samsung Galaxy Watch 6', '5.1.0'),
(4, 'fitness_ring', 'Oura Ring Gen 3', '3.2.5');


-- ============================================================================
-- ## Generate and insert simulated health data (Approx 2M records)
-- ============================================================================
INSERT INTO health_data (
   time,
   device_id,
   heart_rate,
   blood_pressure_systolic,
   blood_pressure_diastolic,
   spo2,
   body_temperature,
   steps_count,
   sleep_quality_score,
   activity_level
)
SELECT
   time,
   device_id,
   -- Heart rate: 60-100 BPM normal range with some variation
   60 + (random() * 40)::INTEGER AS heart_rate,
   -- Blood pressure systolic: 110-140 mmHg
   110 + (random() * 30)::INTEGER AS blood_pressure_systolic,
   -- Blood pressure diastolic: 70-90 mmHg
   70 + (random() * 20)::INTEGER AS blood_pressure_diastolic,
   -- SpO2: 95-100%
   95 + (random() * 5) AS spo2,
   -- Body temperature: 36.1-37.2°C
   36.1 + (random() * 1.1) AS body_temperature,
   -- Steps count: cumulative 0-15000 per day
   (random() * 15000)::INTEGER AS steps_count,
   -- Sleep quality: 0-100 score
   random() * 100 AS sleep_quality_score,
   -- Activity level
   CASE
       WHEN random() < 0.4 THEN 'sedentary'
       WHEN random() < 0.7 THEN 'light'
       WHEN random() < 0.9 THEN 'moderate'
       ELSE 'vigorous'
   END AS activity_level
FROM generate_series(now() - interval '30 days', now(), interval '5 second') AS g1(time),
generate_series(1, 4, 1) AS g2(device_id);  -- adjust interval eg '30 days' to generate larger dataset

-- ============================================================================
-- ## Verify the simulated health dataset
-- ============================================================================
SELECT * FROM health_data ORDER BY time DESC LIMIT 10;


-- ============================================================================
-- ## Verify devices and users
-- ============================================================================
SELECT u.name, u.age, wd.device_type, wd.device_model
FROM users u
JOIN wearable_devices wd ON u.id = wd.user_id;


-- ============================================================================
-- ## Examine Hypertable Partitions
-- ============================================================================
-- Timescale provides SQL API (functions, views, procedures) to manage hypertables
-- and chunks. The timescaledb_information.chunks view provides information about
-- the chunks of a hypertable.


SELECT
   chunk_name,
   range_start,
   range_end,
   is_compressed
FROM timescaledb_information.chunks
WHERE hypertable_name = 'health_data';




-- ============================================================================
-- ## Sample Health Analytics Queries
-- ============================================================================


-- ### Identify abnormal heart rate readings (>90 or <60 BPM) in past day
SELECT
   time,
   device_id,
   heart_rate,
   CASE
       WHEN heart_rate > 99 THEN 'Tachycardia'
       WHEN heart_rate < 60 THEN 'Bradycardia'
   END AS condition
FROM health_data
WHERE (heart_rate > 99 OR heart_rate < 60)
  AND time >= NOW() - INTERVAL '1 day'
ORDER BY time DESC;



-- ### Average vital signs by 1-hour windows
SELECT
   time_bucket('1 hour', time) AS period,
   AVG(heart_rate) AS avg_heart_rate,
   AVG(blood_pressure_systolic) AS avg_bp_systolic,
   AVG(blood_pressure_diastolic) AS avg_bp_diastolic,
   AVG(spo2) AS avg_spo2,
   AVG(body_temperature) AS avg_temp
FROM health_data
WHERE time >= NOW() - INTERVAL '1 day'
GROUP BY period
ORDER BY period DESC
LIMIT 24;


-- ============================================================================
-- ## JOIN Hypertable and Regular Table
-- ============================================================================
-- While organized differently internally, hypertables are fully-featured
-- PostgreSQL tables. You can use standard SQL to query the data in a hypertable,
-- including joining it with other tables. 
--
-- Optionally add EXPLAIN ANALYZE to see the query plan.
-- You would see that the query goes through internal chunks of the hypertable
-- like `_hyper_60_285_chunk`


-- ### Daily activity summary per user over past week
-- EXPLAIN ANALYZE
SELECT
   time_bucket('1 day', hd.time) AS date,
   u.name,
   MAX(hd.steps_count) AS total_steps,
   AVG(hd.heart_rate) AS avg_heart_rate,
   AVG(hd.sleep_quality_score) AS avg_sleep_quality
FROM health_data hd
JOIN wearable_devices wd ON hd.device_id = wd.id
JOIN users u ON wd.user_id = u.id
WHERE time >= NOW() - INTERVAL '1 week'
GROUP BY date, u.name
ORDER BY date DESC, u.name;



-- ### Monitor blood pressure trends for hypertensive patients
SELECT
   time_bucket('1 day', hd.time) AS date,
   u.name,
   AVG(hd.blood_pressure_systolic) AS avg_systolic,
   AVG(hd.blood_pressure_diastolic) AS avg_diastolic,
   MAX(hd.blood_pressure_systolic) AS max_systolic,
   MAX(hd.blood_pressure_diastolic) AS max_diastolic
FROM health_data hd
JOIN wearable_devices wd ON hd.device_id = wd.id
JOIN users u ON wd.user_id = u.id
WHERE u.medical_conditions LIKE '%Hypertension%'
GROUP BY date, u.name
ORDER BY date DESC;


-- ### Real-time health alerts (last 1 hour critical readings)
SELECT
   hd.time,
   u.name,
   wd.device_type,
   hd.heart_rate,
   hd.blood_pressure_systolic,
   hd.blood_pressure_diastolic,
   hd.spo2,
   CASE
       WHEN hd.heart_rate > 120 THEN 'Critical: High Heart Rate'
       WHEN hd.blood_pressure_systolic > 140 THEN 'Warning: High BP'
       WHEN hd.spo2 < 95 THEN 'Critical: Low Oxygen'
       ELSE 'Normal'
   END AS alert_status
FROM health_data hd
JOIN wearable_devices wd ON hd.device_id = wd.id
JOIN users u ON wd.user_id = u.id
WHERE hd.time >= NOW() - INTERVAL '1 hour'
   AND (hd.heart_rate > 99
        OR hd.blood_pressure_systolic > 140
        OR hd.spo2 < 95)
ORDER BY hd.time DESC;




-- Enable timing tracking for the PSQL session
-- \timing on


-- ============================================================================
-- ## Daily Health Summary By Device on Hypertable
-- ============================================================================


SELECT
   time_bucket('1 day', time) AS day,
   device_id,
   AVG(heart_rate) AS avg_heart_rate,
   MIN(heart_rate) AS min_heart_rate,
   MAX(heart_rate) AS max_heart_rate,
   AVG(blood_pressure_systolic) AS avg_bp_systolic,
   AVG(blood_pressure_diastolic) AS avg_bp_diastolic,
   AVG(spo2) AS avg_spo2,
   AVG(body_temperature) AS avg_temperature,
   MAX(steps_count) AS total_steps,
   AVG(sleep_quality_score) AS avg_sleep_quality,
   COUNT(*) AS readings_count
FROM health_data
WHERE health_data.time >= NOW() - INTERVAL '14 days'
GROUP BY day, device_id;

-- Remember the time it took to run the query. Later we will compare the performance
-- of the same query on compressed data and preaggregated data in Continuous aggregate


-- ============================================================================
-- ## Enable Columnarstore (Compression)
-- ============================================================================
-- Enabling a columnstore for the table by itself does not compress the data.
-- You can either manually compress hypertable chunks or create a policy to
-- automatically compress chunks. The compress_chunk() function compresses the
-- chunk of data in the hypertable.


-- ### Manually compress all the chunks of the hypertable
SELECT compress_chunk(c, true) FROM show_chunks('health_data') c;
-- SELECT decompress_chunk(c, true) FROM show_chunks('health_data') c;


-- ### Automatically compress Hypertable with a policy
-- Create a job that automatically converts chunks in a hypertable to the
-- columnstore older than 7 days. This is a preferred way to compress data in production.
-- A default 7-day columnstore policy is auto-created when the hypertable is
-- created with columnstore configured (segmentby/orderby). Remove it first so
-- this call is idempotent (and so a custom interval would actually take effect).
CALL remove_columnstore_policy('health_data');
CALL add_columnstore_policy('health_data', after => INTERVAL '7d');


-- ============================================================================
-- ## Storage Saved by Compression
-- ============================================================================
-- The hypertable_compression_stats() function returns the size of the compressed
-- and uncompressed data in the hypertable.
SELECT
   pg_size_pretty(before_compression_total_bytes) AS before,
   pg_size_pretty(after_compression_total_bytes) AS after,
   ROUND((1 - after_compression_total_bytes::NUMERIC /
          before_compression_total_bytes) * 100, 2) AS compression_ratio_percent
FROM hypertable_compression_stats('health_data');


-- ============================================================================
-- ## Daily Health Summary on Compressed Hypertable
-- ============================================================================
-- This is the same query as above, but now it runs on compressed data.


SELECT
   time_bucket('1 day', time) AS day,
   device_id,
   AVG(heart_rate) AS avg_heart_rate,
   MIN(heart_rate) AS min_heart_rate,
   MAX(heart_rate) AS max_heart_rate,
   AVG(blood_pressure_systolic) AS avg_bp_systolic,
   AVG(blood_pressure_diastolic) AS avg_bp_diastolic,
   AVG(spo2) AS avg_spo2,
   AVG(body_temperature) AS avg_temperature,
   MAX(steps_count) AS total_steps,
   AVG(sleep_quality_score) AS avg_sleep_quality,
   COUNT(*) AS readings_count
FROM health_data
WHERE health_data.time >= NOW() - INTERVAL '14 days'
GROUP BY day, device_id;

-- The query runs on columnar/compressed data and it is faster than the same query on uncompressed data


-- ============================================================================
-- ## Create Continuous Aggregates for Daily Health Summary
-- ============================================================================
-- Continuous aggregates are a TimescaleDB feature that allows you to pre-aggregate
-- data in a hypertable and store the results in a materialized view.
-- This allows you to query the pre-aggregated data instead of the raw data,
-- which can significantly improve query performance.
-- Continuous aggregates are automatically updated as new data is ingested into the hypertable.


CREATE MATERIALIZED VIEW daily_health_summary
WITH (
   timescaledb.continuous,
   timescaledb.materialized_only = false
) AS
SELECT
   time_bucket('1 day', time) AS day,
   device_id,
   AVG(heart_rate) AS avg_heart_rate,
   MIN(heart_rate) AS min_heart_rate,
   MAX(heart_rate) AS max_heart_rate,
   AVG(blood_pressure_systolic) AS avg_bp_systolic,
   AVG(blood_pressure_diastolic) AS avg_bp_diastolic,
   AVG(spo2) AS avg_spo2,
   AVG(body_temperature) AS avg_temperature,
   MAX(steps_count) AS total_steps,
   AVG(sleep_quality_score) AS avg_sleep_quality,
   COUNT(*) AS readings_count
FROM health_data
GROUP BY day, device_id;


-- ============================================================================
-- ### Create Continuous Aggregate Policy
-- ============================================================================
-- The add_continuous_aggregate_policy() function creates a policy that automatically
-- refreshes the continuous aggregate view.
--
-- The start_offset and end_offset parameters specify the time range for the job,
-- updating the aggregate view.
--
-- The schedule_interval parameter specifies how often the continuous aggregate view is refreshed.
SELECT add_continuous_aggregate_policy(
   'daily_health_summary',
   start_offset => INTERVAL '7 days',
   end_offset => INTERVAL '1 day',
   schedule_interval => INTERVAL '1 day'
);


-- ============================================================================
-- ## Query Daily Health Summary Continuous Aggregate
-- ============================================================================
-- This query delivers the same results as the previous query,
-- but it runs on the continuous aggregate view instead of the raw data.
-- It is significantly faster than the same query on the raw data.


SELECT  *
FROM daily_health_summary
WHERE day >= NOW() - INTERVAL '14 days'
ORDER BY day;




-- ============================================================================
-- ## Real Time Continuous Aggregates
-- ============================================================================
-- The continuous aggregate view is automatically updated as new data is ingested
-- into the hypertable. Let's insert a new row into the health_data table and
-- see how the continuous aggregate view is updated.


INSERT INTO health_data (
   time, device_id, heart_rate, blood_pressure_systolic,
   blood_pressure_diastolic, spo2, body_temperature,
   steps_count, sleep_quality_score, activity_level
) VALUES (
   NOW() + INTERVAL '1 day', 99, 72, 118, 78, 98.5, 36.8, 5000, 85.0, 'moderate'
);


-- Verify the real-time update in the continuous aggregate (not the raw table).
-- The inserted row is above the materialization watermark, so it appears immediately.
SELECT day, device_id, ROUND(avg_heart_rate::numeric, 1) AS avg_heart_rate, readings_count
FROM daily_health_summary
WHERE device_id = 99;

-- As you can see, the continuous aggregate view is automatically updated with
-- the new data. This is the stark contrast to standard Postgres Materialized
-- view that needs to be refreshed manually and does not support real-time updates.




-- ============================================================================
-- ## Tier data to S3 storage (older than 30 days)
-- ============================================================================
-- Tiered storage must be enabled for the service first
-- (Service -> Explorer -> Storage Configuration -> Tiering Storage -> Enabled).
SELECT remove_tiering_policy('health_data');
SELECT add_tiering_policy('health_data', INTERVAL '14 days');


-- Enable/disable tiered reads for all future sessions
ALTER DATABASE tsdb SET timescaledb.enable_tiered_reads to true;
-- ALTER DATABASE tsdb SET timescaledb.enable_tiered_reads to false;


-- List tiered chunks
SELECT * FROM timescaledb_osm.tiered_chunks 
WHERE hypertable_name = 'health_data';


-- List chunks scheduled for tiering
SELECT * FROM timescaledb_osm.chunks_queued_for_tiering;




-- ============================================================================
-- ## Add Data Retention Policy (drop data older than 2 years)
-- ============================================================================
SELECT add_retention_policy('health_data', INTERVAL '730 days');


-- ============================================================================
-- ## Advanced Analytics Queries
-- ============================================================================


-- ### Correlation between activity level and heart rate
SELECT
   activity_level,
   AVG(heart_rate) AS avg_heart_rate,
   AVG(spo2) AS avg_spo2,
   COUNT(*) AS sample_count
FROM health_data
WHERE time >= NOW() - INTERVAL '7 days'
GROUP BY activity_level
ORDER BY avg_heart_rate DESC;


-- ### Heart rate variability analysis (HRV proxy)
SELECT
   time_bucket('1 hour', time) AS hour,
   device_id,
   AVG(heart_rate) AS avg_hr,
   STDDEV(heart_rate) AS hr_variability,
   MAX(heart_rate) - MIN(heart_rate) AS hr_range
FROM health_data
WHERE time >= NOW() - INTERVAL '24 hours'
GROUP BY hour, device_id
ORDER BY hour DESC;


-- ### Sleep quality vs next-day heart rate correlation
WITH sleep_data AS (
   SELECT
       time_bucket('1 day', time) AS day,
       device_id,
       AVG(sleep_quality_score) AS sleep_score
   FROM health_data
   WHERE sleep_quality_score IS NOT NULL
   GROUP BY day, device_id
),
next_day_hr AS (
   SELECT
       time_bucket('1 day', time) AS day,
       device_id,
       AVG(heart_rate) AS avg_heart_rate
   FROM health_data
   GROUP BY day, device_id
)
SELECT
   s.day AS sleep_day,
   s.device_id,
   s.sleep_score,
   n.avg_heart_rate AS next_day_avg_hr
FROM sleep_data s
JOIN next_day_hr n ON s.device_id = n.device_id
   AND n.day = s.day + INTERVAL '1 day'
WHERE s.day >= NOW() - INTERVAL '30 days'
ORDER BY s.day DESC;

