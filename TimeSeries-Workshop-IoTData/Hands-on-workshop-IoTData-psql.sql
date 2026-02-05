-- -- ============================================================================
-- # Analyze nternet of Things (IoT) Data (UI Version)
-- ============================================================================
--
-- The Internet of Things (IoT) describes a trend where computing capabilities are embedded into IoT devices. 
-- That is, physical objects, ranging from light bulbs to oil wells. 
-- Many IoT devices collect sensor data about their environment and generate time-series datasets with relational metadata.
-- It is often necessary to simulate IoT datasets. 
-- For example, when you are testing a new system. 

-- This tutorial shows how to simulate a basic dataset in your Tiger Cloud service, and then run simple queries on it.
-- ============================================================================
-- ## Prerequisites
-- ============================================================================
-- To follow the steps on this page:
--
-- 1. Create a target TigerData Cloud service with time-series and analytics enabled.
--    https://console.cloud.timescale.com/signup
--
-- 2. You need your connection details like: 
--    "postgres://tsdbadmin:xxxxxxx.yyyyy.tsdb.cloud.timescale.com:39966/tsdb?sslmode=require"

-- ============================================================================
-- ## Setup
-- ============================================================================
-- If you are using PSQL command line - To simulate a dataset, run the queries outlined below:
--
-- **For TigerData Console UI:**
-- 1. Switch to the "Data" tab in the TigerData Console
-- 2. Create new "Query Tab" (+) sign at the top right
-- 3. Copy and paste the code below into the query editor
--

-- ### Drop tables and associated objects
DROP TABLE IF EXISTS sensors CASCADE;
DROP TABLE IF EXISTS sensor_data CASCADE;

-- ============================================================================
-- ## Create Tables
-- ============================================================================
-- (highlight the SQL and click Run)

-- Create a standard PostgreSQL heap reference (meta data)table for relational data:
CREATE TABLE sensors(
  id SERIAL PRIMARY KEY,
  type VARCHAR(50),
  location VARCHAR(50)
);

-- Create a hypertable to store the real-time sensor data
-- To enable columnarstore, you need to set the tsdb.hypertable
-- parameter to true.
-- The tsdb.orderby parameter specifies the order in which the
-- data is compressed.
-- The tsdb.segmentby parameter specifies the column by which the data
-- is segmented. The segmentby column is used to group the data into segments,
-- which are then compressed separately.


CREATE TABLE sensor_data (
  time TIMESTAMPTZ NOT NULL,
  sensor_id INTEGER,
  temperature DOUBLE PRECISION,
  cpu DOUBLE PRECISION,
  FOREIGN KEY (sensor_id) REFERENCES sensors (id)
) WITH (
  tsdb.hypertable,
  tsdb.segmentby = 'sensor_id',
  tsdb.orderby = 'time DESC'
);

-- ============================================================================
-- ## Create Indexes
-- ============================================================================
-- Indexes are used to speed up the retrieval of data from a database table.
-- In this case, you create an index on the sensor_id column of the sensor_data table. 
-- Hypertables automatically create indexes on the 
-- time column, so you don't need to create an index on that column.

CREATE INDEX ON sensor_data (sensor_id, time);

-- Configurable sparse indexes
-- lightweight metadata structures created on compressed chunks
-- to allow efficient filtering without needing full B-tree indexes.
--
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


ALTER TABLE sensor_data SET (
   timescaledb.compress_index =
'minmax(temperature), minmax(cpu)');

-- Please note that setting up a bloom index in this case on sensor_id wouldn't work as these are desined for compressed columns
-- and sensor_id is what we are segmenting on, and as such it stays uncompressed. 


-- ============================================================================
-- ## Populate the sensors table: 
-- ============================================================================
INSERT INTO sensors (type, location) VALUES
('a','floor'),
('a', 'ceiling'),
('b','floor'),
('b', 'ceiling');

-- ============================================================================
-- ## Verify that the sensors have been added correctly:
-- ============================================================================
SELECT * FROM sensors;

-- Sample output:
id | type | location
----+------+----------
  1 | a    | floor
  2 | a    | ceiling
  3 | b    | floor
  4 | b    | ceiling
(4 rows)

-- ============================================================================
-- ## Generate and insert a dataset for all sensors:
-- ============================================================================
INSERT INTO sensor_data (time, sensor_id, cpu, temperature)
SELECT
  time,
  sensor_id,
  random() AS cpu,
  random()*100 AS temperature
FROM generate_series(now() - interval '30 days', now(), interval '5 seconds') AS g1(time), generate_series(1,4,1) AS g2(sensor_id);

-- ## Load data from S3 - Optional
-- ============================================================================
-- Ingest IoT device data from S3 via Online S3 Connector
--e.g. s3://dario-demo-data/sensor_data.csv

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
WHERE hypertable_name = 'sensor_data';

-- Sample output:
       chunk_name       |      range_start       |       range_end        | is_compressed 
------------------------+------------------------+------------------------+---------------
 _hyper_259_26078_chunk | 2026-01-01 00:00:00+00 | 2026-01-08 00:00:00+00 | f
 _hyper_259_26079_chunk | 2026-01-08 00:00:00+00 | 2026-01-15 00:00:00+00 | f
 _hyper_259_26080_chunk | 2026-01-15 00:00:00+00 | 2026-01-22 00:00:00+00 | f
 _hyper_259_26081_chunk | 2026-01-22 00:00:00+00 | 2026-01-29 00:00:00+00 | f
 _hyper_259_26082_chunk | 2026-01-29 00:00:00+00 | 2026-02-05 00:00:00+00 | f
 _hyper_259_26083_chunk | 2026-02-05 00:00:00+00 | 2026-02-12 00:00:00+00 | f
(6 rows)


-- ============================================================================
-- ## Verify the simulated dataset:
-- ============================================================================
SELECT Count(*) FROM sensor_data;
SELECT * FROM sensor_data ORDER BY time LIMIT 100;

-- Sample output:
time              | sensor_id |    temperature     |         cpu         
-------------------------------+-----------+--------------------+---------------------
 2020-03-31 15:56:25.843575+00 |         1 |   6.86688972637057 |   0.682070567272604
 2020-03-31 15:56:40.244287+00 |         2 |    26.589260622859 |   0.229583469685167
 2030-03-31 15:56:45.653115+00 |         3 |   79.9925176426768 |   0.457779890391976
 2020-03-31 15:56:53.560205+00 |         4 |   24.3201029952615 |   0.641885648947209
 2020-03-31 16:01:25.843575+00 |         1 |   33.3203678019345 |  0.0159163917414844
 2020-03-31 16:01:40.244287+00 |         2 |   31.2673618085682 |   0.701185956597328
 2020-03-31 16:01:45.653115+00 |         3 |   85.2960689924657 |   0.693413889966905
 2020-03-31 16:01:53.560205+00 |         4 |   79.4769988860935 |   0.360561791341752
...

-- ============================================================================
-- ## After you simulate a dataset, you can run some basic queries on it, e.g. 
-- Average and last temperature, average CPU by 30-minute windows:
-- ============================================================================
SELECT
  time_bucket('30 minutes', time) AS period,
  AVG(temperature) AS avg_temp,
  last(temperature, time) AS last_temp,
  AVG(cpu) AS avg_cpu
FROM sensor_data
GROUP BY period
ORDER BY period;

-- Sample output:
       period         |      avg_temp      |       last_temp       |       avg_cpu       
------------------------+--------------------+-----------------------+---------------------
 2026-01-06 14:00:00+00 |  51.60930295600504 |     7.967133992592035 |  0.5190356186358789
 2026-01-06 14:30:00+00 | 49.944447015084826 |    2.1082860067580533 | 0.49407287047243675
 2026-01-06 15:00:00+00 | 48.890921442323844 |      70.1353514024994 |  0.4959841832825577
 2026-01-06 15:30:00+00 |  49.19831742462273 |    41.015060145537554 | 0.49869157688373034
 2026-01-06 16:00:00+00 | 50.178389952691994 |     59.29227603711116 |  0.5049884275739991
...

-- ============================================================================
-- ## JOIN Hypertable and Regular Table
-- ============================================================================
-- While organized differently internally, hypertables are fully-featured 
-- PostgreSQL tables. You can use standard SQL to query the data in a hytertable, 
-- including joining it with other tables. In this example, you join the 
-- sensor_data hypertable with the sensors table to get the type of the sensor.
--
-- Optionally add EXPLAIN ANALYZE to see the query plan.
-- You would see that the query goes through internal chunks of the hypertable 
-- like `_hyper_1_1_chunk`

--EXPLAIN ANALYZE
SELECT
  sensors.location,
  time_bucket('30 minutes', time) AS period,
  AVG(temperature) AS avg_temp,
  last(temperature, time) AS last_temp,
  AVG(cpu) AS avg_cpu
FROM sensor_data JOIN sensors on sensor_data.sensor_id = sensors.id
GROUP BY period, sensors.location;

-- Sample output:
location |         period         |     avg_temp     |     last_temp     |      avg_cpu      
----------+------------------------+------------------+-------------------+-------------------
 ceiling  | 20120-03-31 15:30:00+00 | 25.4546818090603 |  24.3201029952615 | 0.435734559316188
 floor    | 2020-03-31 15:30:00+00 | 43.4297036845237 |  79.9925176426768 |  0.56992522883229
 ceiling  | 2020-03-31 16:00:00+00 | 53.8454438598516 |  43.5192013625056 | 0.490728285357666
 floor    | 2020-03-31 16:00:00+00 | 47.0046211887772 |  23.0230117216706 |  0.53142289724201
 ceiling  | 2020-03-31 16:30:00+00 | 58.7817596504465 |  63.6621567420661 | 0.488188337767497
 floor    | 2020-03-31 16:30:00+00 |  44.611586847653 |  2.21919436007738 | 0.434762630766879
 ceiling  | 2020-03-31 17:00:00+00 | 35.7026890735142 |  42.9420990403742 | 0.550129583687522
 floor    | 2020-03-31 17:00:00+00 | 62.2794370166957 |  52.6636955793947 | 0.454323202022351
...


-- ============================================================================
-- ## Calculate One-Day Summary Data on Non-Compressed Hypertable
-- ============================================================================
SELECT
    time_bucket('1 day', time) AS period,
    AVG(temperature) AS avg_temp,
    last(temperature, time) AS last_temp,
    AVG(cpu) AS avg_cpu
FROM sensor_data
WHERE sensor_id = '4' 
  AND time >= NOW() - INTERVAL '7 days'
GROUP BY period, sensor_id
ORDER BY period;

-- Remember the time it took to run the query. Later we will compare the performance 
-- of the same query on compressed data and preaggregated data in Continuous aggregate

-- ============================================================================
-- ## Enable Columnarstore (Compression)
-- ============================================================================
-- Enabling a columnarstore for the table by itself does not compress the data.
-- You can either manually compress hypertable chunks or create a policy to 
-- automatically compress chunks. The compress_chunk() function compresses the 
-- chunk of data in the hypertable.

-- ### Manually compress all the chunks of the hypertable
-- TODO: switch to convert_to_columnarstore()?
SELECT compress_chunk(c, true) FROM show_chunks('sensor_data') c;
-- SELECT decompress_chunk(c, true) FROM show_chunks('sensor_data') c;

-- ### Automatically compress Hypertable with a policy
-- Columnstore compression policies are now created automatically upon hypertable definition. 
-- Tiger Data DB enables the columnstore by default and creates a compression policy that runs after one chunk interval (default of 7-days).

-- ============================================================================
-- ## Storage Saved by Compression
-- ============================================================================
-- The hypertable_compression_stats() function returns the size of the compressed 
-- and uncompressed data in the hypertable.

SELECT 
    pg_size_pretty(before_compression_total_bytes) AS before,
    pg_size_pretty(after_compression_total_bytes)  AS after
FROM hypertable_compression_stats('sensor_data');

-- The same information you can access in the TigerData Console UI.
-- In the Explorer, click on the `sensor_data` hypertable.

-- To check the compression ration on a per chunk basis:
SELECT 
c.chunk_name,
to_timestamp(c.range_start_integer/1000) as range_start,
to_timestamp(c.range_end_integer/1000) as range_end,
to_timestamp(c.range_end_integer/1000) - to_timestamp(c.range_start_integer/1000) as chunk_length,
c.is_compressed,
CASE
   WHEN s.before_compression_total_bytes IS NOT NULL
         THEN pg_size_pretty(s.before_compression_total_bytes)
   ELSE pg_size_pretty(d.total_bytes)
END before_compression,
pg_size_pretty(s.after_compression_total_bytes) as after_compression,
ROUND((before_compression_total_bytes::NUMERIC-s.after_compression_total_bytes::NUMERIC)/before_compression_total_bytes::NUMERIC *100,2) AS compression_ratio
FROM 
chunks_detailed_size('sensor_data') d, 
chunk_compression_stats('sensor_data') s,
timescaledb_information.chunks c 
WHERE (d.chunk_name=c.chunk_name and d.chunk_name=s.chunk_name) 
order by range_start desc limit 100;

-- ============================================================================
-- ## Calculate One-Day Summary Data on Compressed Hypertable
-- ============================================================================
-- This is the same query as above, but now it runs on compressed data.
--Explain ANALYZE 
SELECT
    time_bucket('1 day', time) AS period,
    AVG(temperature) AS avg_temp,
    last(temperature, time) AS last_temp,
    AVG(cpu) AS avg_cpu
FROM sensor_data
WHERE sensor_id = '4' 
  AND time >= NOW() - INTERVAL '30 days'
GROUP BY period, sensor_id
ORDER BY period;

-- The query runs on columnar/compressed data and it is faster than the same query on uncompressed data

-- ============================================================================
-- ## Create a Continuous Aggregate 
-- ============================================================================
-- Continuous aggregates are a TimescaleDB feature that allows you to pre-aggregate 
-- data in a hypertable and store the results in a materialized view.
-- This allows you to query the pre-aggregated data instead of the raw data, 
-- which can significantly improve query performance. 
-- Continuous aggregates are automatically updated as new data is ingested into the hypertable.
-- DROP MATERIALIZED VIEW one_day_summary;
CREATE MATERIALIZED VIEW one_day_summary
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    time_bucket('1 day', time) AS period,
    sensor_id, 
    AVG(temperature) AS avg_temp,
    last(temperature, time) AS last_temp,
    AVG(cpu) AS avg_cpu
FROM sensor_data
GROUP BY period, sensor_id;

-- ### Create Continuous Aggregate Policy
-- The add_continuous_aggregate_policy() function creates a policy that automatically 
-- refreshes the continuous aggregate view.
--
-- The start_offset and end_offset parameters specify the time range for the job, 
-- updating the aggregate view.
--
-- The schedule_interval parameter specifies how often the continuous aggregate view is refreshed.

SELECT add_continuous_aggregate_policy('one_day_summary',
    start_offset => INTERVAL '3 days',
    end_offset => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 day');

-- ============================================================================
-- ## Query Continuous Aggregate
-- ============================================================================
-- This query delivers the same results as the previous query, 
-- but it runs on the continuous aggregate view instead of the raw data.
-- It is significantly faster than the same query on the raw data.

SELECT * 
FROM one_day_summary
WHERE sensor_id = '4' 
  AND period >= NOW() - INTERVAL '14 days'
ORDER BY period;

-- ============================================================================
-- ## Real Time Continuous Aggregates
-- ============================================================================
-- The continuous aggregate view is automatically updated as new data is ingested 
-- into the hypertable. Let's insert a new row into the sensor_data table and 
-- see how the continuous aggregate view is updated.

INSERT INTO sensor_data (time, sensor_id, cpu, temperature)
VALUES (NOW() + INTERVAL '1day', '4', 5, 150);

SELECT * 
FROM one_day_summary
WHERE sensor_id = '4' 
  AND period >= NOW() - INTERVAL '14 days'
ORDER BY period;

-- As you can see, the continuous aggregate view is automatically updated with 
-- the new data. This is the stark contrast to standard Postgres Materialized 
-- view that needs to be refreshed manually and does not support real-time updates.


-- ============================================================================
-- ## Tier data to S3 storage older than 7 Days
-- ============================================================================
-- Tiered Storage is Tiger's multi-tiered storage architecture engineered to enable infinite, low-cost scalability for time series and analytical databases in Tiger. 
-- Tiered storage complements Tiger's standard high-performance storage tier with a low-cost bottomless storage tier; an object store built on Amazon S3.
-- Make sure that Tiered storage is enabled for your service (TigerData Service|Explorer|Storage Configuration|TieringStorage|Enabled)

SELECT add_tiering_policy('sensor_data', INTERVAL '7 days');


-- enable/diable tiered reads for all future sessions
ALTER DATABASE tsdb SET timescaledb.enable_tiered_reads to true;
ALTER DATABASE tsdb SET timescaledb.enable_tiered_reads to false;

-- list tiered chunks
SELECT * FROM timescaledb_osm.tiered_chunks WHERE hypertable_name = 'sensor_data';

-- list chunks scheduled for tiering
SELECT * FROM timescaledb_osm.chunks_queued_for_tiering WHERE hypertable_name = 'sensor_data';

-- ============================================================================
-- ## Query Data Tiered to S3 
-- ============================================================================
-- There will be some latency, depending on the query, you may have to go back and forth 10 * 20 * 30 times and read from S3 bucket.
-- That by itself adds, 20 Multiply 100 milliseconds as a minimum on top of everything else. 
-- This can still be good enough for large scans, but not for point lookups.
SELECT
    time_bucket('1 day', time) AS period,
    AVG(temperature) AS avg_temp,
    last(temperature, time) AS last_temp,
    AVG(cpu) AS avg_cpu
FROM sensor_data
WHERE sensor_id = '4' 
  AND time >= NOW() - INTERVAL '20 days'
GROUP BY period, sensor_id
ORDER BY period;

-- ============================================================================
-- ## Add Data Retention Policy by dropping data older than 21 Days
-- ============================================================================
SELECT add_retention_policy ('sensor_data', INTERVAL '21 days');
