# TimeSeries Workshop - Biowearables

## Overview

This workshop demonstrates advanced time-series data analysis using PostgreSQL and TigerData for Biowearables,  
eg track health metrics from wearable devices including:

- Heart Rate (BPM)
- Blood Pressure (Systolic/Diastolic)
- Blood Oxygen Saturation (SpO2)
- Body Temperature
- Steps Count
- Sleep Quality Score

Use case: Remote patient monitoring, fitness tracking, and health analytics

## What You'll Learn

- **Hypertables**: Convert regular PostgreSQL tables into time-series optimized hypertables

- **Working with Bioweareables Data**: Work with sample generated bioweareables data

- **Bioweareables Data Analysis**: Generate daily health summaries & other health monitoring queries

- **Columnar Compression**: Achieve 10x storage reduction while improving query performance

- **Continuous Aggregates**: Pre-compute aggregations for lightning-fast analytics

- **Real-time Updates**: Build materialized views that update automatically as new data arrives

## Contents

- **`analyze-bioweareables-data-psql.sql`**: Complete workshop for psql command-line interface

## Prerequisites

- Timescale Cloud account (get free 30 days at <https://console.cloud.timescale.com/signup>)

- Optional, but recommended - install psql CLI https://www.tigerdata.com/blog/how-to-install-psql-on-mac-ubuntu-debian-windows

- Basic knowledge of SQL and relational data concepts

## Sample Architecture with TigerData

![Sample Architecture with TigerData](https://imgur.com/j1H6zxv.png)

## Architecture highlights

- **Unified Data Flow**: Ingest data from files, streams, IoT devices, and APIs into the TigerData Cloud Service (AWS or Azure)
  
- **Centralized Storage**: Data is organized in the TigerData Cloud Service for analytics, AI, and ML applications (with built in compression and continous real-time aggregations) 
  
- **Real-Time Analytics**: Enables SQL-based queries, dashboards, alerts, and visualizations using Grafana or other tools
  
- **AI & ML Integration**: Connects seamlessly with ChatGPT and Amazon SageMaker for data enrichment and devops automation


## Data Structure

### Health Data Table

```sql
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

```

### Users Table

```sql
CREATE TABLE users(
   id SERIAL PRIMARY KEY,
   name VARCHAR(100), 
   age INTEGER,
   gender VARCHAR(10),
   medical_conditions TEXT
);
```

### Wearable Devices Table

```sql
CREATE TABLE wearable_devices(
   id SERIAL PRIMARY KEY,
   user_id INTEGER,
   device_type VARCHAR(50),  -- smartwatch, fitness_band, patch, ring
   device_model VARCHAR(100),
   firmware_version VARCHAR(20)
);

```

## Key Features Demonstrated

### 1. Hypertable Creation

Time-series optimized hypertables:

```sql
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
```

### 2. Generate Data & Run Analytical Queries 

Run Analytical Queries like Daily Health Analysis

```sql
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
```

### 3. Columnar Compression 

Enable ~10x storage compression with improved query performance:

```sql
-- A default 7-day columnstore policy is auto-created at table creation; remove it first:
CALL remove_columnstore_policy('health_data');
CALL add_columnstore_policy('health_data', after => INTERVAL '7d');
```

### 4. Real Time Continuous Aggregates

Create self-updating materialized views for instant analytics:

```sql
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

SELECT add_continuous_aggregate_policy(
   'daily_health_summary',
   start_offset => INTERVAL '7 days',
   end_offset => INTERVAL '1 day',
   schedule_interval => INTERVAL '1 day'
);
```


## Getting Started

### Using psql Command Line

Run the entire workshop non-interactively:

```bash
psql "postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require" \
  -f analyze-bioweareables-data-psql.sql
```

Or connect interactively and run the sections one at a time:

```bash
psql "postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require"
```

The script creates the tables, generates ~2M rows of sample health data (via
`generate_series`), and walks through the analytics, compression, continuous
aggregate, and real-time update steps — including timing comparisons that
demonstrate the performance improvements.

## Workshop Highlights

- **Bioweareables Data**: Work with sample generated bioweareables data 
- **Performance Optimization**: Compare query times before and after compression
- **Storage Efficiency**: See 10x storage reduction with columnar compression
- **Automatic Updates**: Demonstrate real-time continuous aggregate updates
- **Production Ready**: Learn policies for automatic compression and aggregate refreshing

## Performance Benefits

- **Hypertables**: Automatic partitioning for optimal time-series queries
- **Columnar Storage**: 90% storage reduction with faster analytical queries
- **Continuous Aggregates**: Sub-second response times for complex aggregations
- **Automatic Policies**: Set-and-forget data lifecycle management

## License
