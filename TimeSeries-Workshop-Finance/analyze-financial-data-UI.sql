-- ============================================================================
-- # Analyze Financial Tick Data (UI Version)
-- ============================================================================
--
-- The financial industry is extremely data-heavy and relies on real-time and 
-- historical data for decision-making, risk assessment, fraud detection, and 
-- market analysis. Timescale simplifies management of these large volumes of 
-- data, while also providing you with meaningful analytical insights and 
-- optimizing storage costs.
--
-- To analyze financial data, you can chart the open, high, low, close, and 
-- volume (OHLCV) information for a financial asset. Using this data, you can 
-- create candlestick charts that make it easier to analyze the price changes 
-- of financial assets over time. You can use candlestick charts to examine 
-- trends in stock, cryptocurrency, or NFT prices.
--
-- In this tutorial, you use real raw financial data provided by Twelve Data, 
-- create an aggregated candlestick view, query the aggregated data.
--
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
--
-- ============================================================================
-- ## About OHLCV Data and Candlestick Charts
-- ============================================================================
-- The financial sector regularly uses candlestick charts to visualize the 
-- price change of an asset. Each candlestick represents a time period, such 
-- as one minute or one hour, and shows how the asset's price changed during 
-- that time.
--
-- Candlestick charts are generated from the open, high, low, close, and volume 
-- data for each financial asset during the time period. This is often 
-- abbreviated as OHLCV:
-- - Open: opening price
-- - High: highest price
-- - Low: lowest price
-- - Close: closing price
-- - Volume: volume of transactions
--
-- ![candlestick data](https://assets.timescale.com/docs/images/tutorials/intraday-stock-analysis/timescale_cloud_candlestick.png)

-- ============================================================================
-- ## Setup
-- ============================================================================
-- If you are using PSQL command line - follow the analyze-financial-data-psql.sql
--
-- **For TigerData Console UI:**
-- 1. Switch to the "Data" tab in the TigerData Console
-- 2. Create new "Query Tab" (+) sign at the top right
-- 3. Copy and paste the code below into the query editor
--

-- ### Drop tables and associated objects
DROP TABLE IF EXISTS crypto_ticks CASCADE;
DROP TABLE IF EXISTS crypto_assets CASCADE;

-- ### Load Data from S3
-- **Option 1: Using TigerData Console UI**
-- 1. In TigerData Console: Actions -> S3 Import
-- 2. As path enter: s3://timescale-demo-data/crypto_assets.csv
-- 3. Select "Public" as access method
-- 4. Click "Import CSV"
--
-- **Repeat the steps above for the second file:**
-- 1. Path: s3://timescale-demo-data/crypto_ticks.csv
-- 2. Make sure to turn on "Hypertable partition" for the 'time' column
--
-- **If you missed the "Hypertable partition" option, you can convert table to hypertable later using:**
-- SELECT create_hypertable('crypto_ticks', 'time');

-- ============================================================================
-- ## Preview Data
-- ============================================================================
-- (highlight the SQL and click Run)

-- Preview the tick data
SELECT * FROM crypto_ticks LIMIT 10;

-- Preview the reference data
SELECT * FROM crypto_assets LIMIT 10;

-- ============================================================================
-- ## Create Indexes
-- ============================================================================
-- Indexes are used to speed up the retrieval of data from a database table.
-- In this case, you create an index on the symbol column of the crypto_assets 
-- and crypto_ticks tables. Hypertables automatically create indexes on the 
-- time column, so you don't need to create an index on that column.

CREATE INDEX ON crypto_assets (symbol);
CREATE INDEX ON crypto_ticks (symbol, time);
-- ============================================================================
-- ## Examine Hypertable Details 
-- ============================================================================
-- In Tiger Cloud Console Navigate to Explorer, locate the `crypto_ticks` hypertable,
-- and click on it to see the details.
-- 
-- Clock on the "Chunks" tab to see the list of chunks that make up the hypertable.

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
WHERE hypertable_name = 'crypto_ticks';

-- ============================================================================
-- ## JOIN Hypertable and Regular Table
-- ============================================================================
-- While organized differently internally, hypertables are fully-featured 
-- PostgreSQL tables. You can use standard SQL to query the data in a hytertable, 
-- including joining it with other tables. In this example, you join the 
-- crypto_ticks hypertable with the crypto_assets table to get the name of the asset.
--
-- Optionally add EXPLAIN ANALYZE to see the query plan.
-- You would see that the query goes through internal chunks of the hypertable 
-- like `_hyper_60_285_chunk`

-- EXPLAIN ANALYZE 
SELECT 
    t.time, 
    t.symbol, 
    t.price, 
    t.day_volume, 
    a.name
FROM crypto_ticks t
JOIN crypto_assets a ON t.symbol = a.symbol
ORDER BY t.time DESC
LIMIT 10;

-- ============================================================================
-- ## Calculate One-Day Candlestick Data on Non-Compressed Hypertable
-- ============================================================================
-- The Twelve Data sample is historical, so the "last 14 days" window is anchored
-- to the most recent tick in the table — (SELECT max(time) FROM crypto_ticks) —
-- rather than now(). That way these queries return data whenever you run the
-- workshop, regardless of the sample's capture date.

SELECT
    time_bucket('1 day', time) AS bucket,
    symbol,
    FIRST(price, time)          AS "open",
    MAX(price)                  AS high,
    MIN(price)                  AS low,
    LAST(price, time)           AS "close",
    LAST(day_volume, time)      AS day_volume
FROM crypto_ticks
WHERE symbol = 'BTC/USD' 
  AND time >= (SELECT max(time) FROM crypto_ticks) - INTERVAL '14 days'
GROUP BY bucket, symbol
ORDER BY bucket;

-- Remember the time it took to run the query. Later we will compare the performance 
-- of the same query on compressed data and preaggregated data in Continuous aggregate

-- ============================================================================
-- ## Enable Columnarstore (Compression)
-- ============================================================================
-- To enable columnarstore, you need to set the timescaledb.enable_columnstore 
-- parameter to true. This parameter is set at the table level, so you need to 
-- run the ALTER TABLE command on the crypto_ticks hypertable.
-- The timescaledb.orderby parameter specifies the order in which the 
-- data is compressed.
-- The timescaledb.segmentby parameter specifies the column by which the data 
-- is segmented. The segmentby column is used to group the data into segments, 
-- which are then compressed separately.

ALTER TABLE crypto_ticks 
SET (
    timescaledb.enable_columnstore = true, 
    timescaledb.segmentby = 'symbol',
    timescaledb.orderby = 'time DESC'
);

-- Enabling a columnarstore for the table by itself does not compress the data.
-- You can either manually compress hypertable chunks or create a policy to 
-- automatically compress chunks. The compress_chunk() function compresses the 
-- chunk of data in the hypertable.

-- ### Manually compress all the chunks of the hypertable
-- TODO: switch to convert_to_columnarstore()?
SELECT compress_chunk(c, true) FROM show_chunks('crypto_ticks') c;
-- SELECT decompress_chunk(c, true) FROM show_chunks('crypto_ticks') c;

-- ### Automatically compress Hypertable with a policy
-- Create a job that automatically converts chunks in a hypertable to the 
-- columnstore older than 1 day. This is a preferred way to compress data in production.
CALL add_columnstore_policy('crypto_ticks', after => INTERVAL '1d');

-- ============================================================================
-- ## Storage Saved by Compression
-- ============================================================================
-- The hypertable_compression_stats() function returns the size of the compressed 
-- and uncompressed data in the hypertable.

SELECT 
    pg_size_pretty(before_compression_total_bytes) AS before,
    pg_size_pretty(after_compression_total_bytes)  AS after
FROM hypertable_compression_stats('crypto_ticks');

-- The same information you can access in the TigerData Console UI.
-- In the Explorer, click on the `crypto_ticks` hypertable.

-- In our case the compression ratio is ~10x
-- In practice that means that to store 1TB of data in a hypertable, you need just 100GB of storage.

-- ============================================================================
-- ## Calculate One-Day Candlestick Data on Compressed Hypertable
-- ============================================================================
-- This is the same query as above, but now it runs on compressed data.

SELECT
    time_bucket('1 day', time) AS bucket,
    symbol,
    FIRST(price, time)          AS "open",
    MAX(price)                  AS high,
    MIN(price)                  AS low,
    LAST(price, time)           AS "close",
    LAST(day_volume, time)      AS day_volume
FROM crypto_ticks
WHERE symbol = 'BTC/USD' 
  AND time >= (SELECT max(time) FROM crypto_ticks) - INTERVAL '14 days'
GROUP BY bucket, symbol
ORDER BY bucket;

-- The query runs on columnar/compressed data and it is faster than the same query on uncompressed data

-- ============================================================================
-- ## Create a Continuous Aggregate 
-- ============================================================================
-- Continuous aggregates are a TimescaleDB feature that allows you to pre-aggregate 
-- data in a hypertable and store the results in a materialized view.
-- This allows you to query the pre-aggregated data instead of the raw data, 
-- which can significantly improve query performance. 
-- Continuous aggregates are automatically updated as new data is ingested into the hypertable.

CREATE MATERIALIZED VIEW one_day_candle
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
    time_bucket('1 day', time) AS bucket,
    symbol,
    FIRST(price, time)          AS "open",
    MAX(price)                  AS high,
    MIN(price)                  AS low,
    LAST(price, time)           AS "close",
    LAST(day_volume, time)      AS day_volume
FROM crypto_ticks
GROUP BY bucket, symbol;

-- ### Create Continuous Aggregate Policy
-- The add_continuous_aggregate_policy() function creates a policy that automatically 
-- refreshes the continuous aggregate view.
--
-- The start_offset and end_offset parameters specify the time range for the job, 
-- updating the aggregate view.
--
-- The schedule_interval parameter specifies how often the continuous aggregate view is refreshed.

SELECT add_continuous_aggregate_policy('one_day_candle',
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
FROM one_day_candle
WHERE symbol = 'BTC/USD' 
  AND bucket >= (SELECT max(bucket) FROM one_day_candle) - INTERVAL '14 days'
ORDER BY bucket;

-- ============================================================================
-- ## Real Time Continuous Aggregates
-- ============================================================================
-- The continuous aggregate view is automatically updated as new data is ingested 
-- into the hypertable. Let's insert a new row into the crypto_ticks table and 
-- see how the continuous aggregate view is updated.

INSERT INTO crypto_ticks (time, symbol, price, day_volume)
VALUES ((SELECT max(time) FROM crypto_ticks) + INTERVAL '1 day', 'BTC/USD', 120000, 30750246);

SELECT *
FROM one_day_candle
WHERE symbol = 'BTC/USD'
  AND bucket >= (SELECT max(bucket) FROM one_day_candle) - INTERVAL '14 days'
ORDER BY bucket DESC; -- to see the most recently inserted row first

-- As you can see, the continuous aggregate view is automatically updated with 
-- the new data. This is the stark contrast to standard Postgres Materialized 
-- view that needs to be refreshed manually and does not support real-time updates.