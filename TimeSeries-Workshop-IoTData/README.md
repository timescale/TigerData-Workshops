# Timeseries Workshop - IoT Data Analysis

## Overview

The Internet of Things (IoT) describes a trend where computing capabilities are embedded into IoT devices. That is, physical objects, ranging from light bulbs to oil wells. Many IoT devices collect sensor data about their environment and generate time-series datasets with relational metadata.

It is often necessary to simulate IoT datasets. For example, when you are testing a new system. This tutorial shows how to simulate a basic dataset in your Tiger Cloud service, and then run simple queries on it.

## What You'll Learn

- **Hypertables**: Convert regular PostgreSQL tables into time-series optimized hypertables

- **Real-time IoT Sensor Data**: Work with the actual manifacturing line IoT devices/sensor data

- **Metadata Analysis**: Combine the timeseries sensor data with a device reference meta data via joins to create useful visualization

- **Columnar Compression**: Achieve 10x storage reduction while improving query performance

- **Continuous Aggregates**: Pre-compute aggregations for lightning-fast analytics

- **Real-time Updates**: Build materialized views that update automatically as new data arrives


## Contents

- **`Hands-on-workshop-IoTData-psql.sql`**: Complete workshop for psql command-line interface

## Prerequisites

- Create a target TigerData Cloud service with time-series and analytics enabled (at <https://console.cloud.timescale.com/signup>)
  
- Optional, but recommended - install psql CLI https://www.tigerdata.com/blog/how-to-install-psql-on-mac-ubuntu-debian-windows

- You need your connection details like: "postgres://tsdbadmin:xxxxxxx.yyyyy.tsdb.cloud.timescale.com:39966/tsdb?sslmode=require"

- Basic knowledge of SQL

## Sample Architecture with TigerData

![Sample Architecture with TigerData](https://imgur.com/j1H6zxv.png)

## Architecture highlights

Unified Data Flow: Ingest data from files, streams, IoT devices, and APIs into the TigerData Cloud Service (AWS or Azure)

Centralized Storage: Data is organized in the TigerData Cloud Service for analytics, AI, and ML applications (with built in compression and continous real-time aggregations)

Real-Time Analytics: Enables SQL-based queries, dashboards, alerts, and visualizations using Grafana or other tools

AI & ML Integration: Connects seamlessly with ChatGPT and Amazon SageMaker for data enrichment and devops automation


## Data Structure

### Standard Postgres reference table for relational (meta) data:

```sql
CREATE TABLE sensors(
  id SERIAL PRIMARY KEY,
  type VARCHAR(50),
  location VARCHAR(50)
);
```

### Hypertable to store the real-time sensor data:

```sql
CREATE TABLE sensor_data (
  time TIMESTAMPTZ NOT NULL,
  sensor_id INTEGER,
  temperature DOUBLE PRECISION,
  cpu DOUBLE PRECISION,
  FOREIGN KEY (sensor_id) REFERENCES sensors (id)
) WITH (
   tsdb.hypertable,
   tsdb.partition_column='time',
   tsdb.segmentby = 'sensor_id',
   tsdb.orderby = 'time DESC'
);
```


## Key Features Demonstrated

### 1. Hypertable Creation
Creating time-series optimized hypertables via sql-like function 

### 2. Data Generation
#### Populate the sensors table: 
```sql
INSERT INTO sensors (type, location) VALUES
('a','floor'),
('a', 'ceiling'),
('b','floor'),
('b', 'ceiling');
```

#### Generate and insert a dataset for all IoT sensors:
```sql
INSERT INTO sensor_data (time, sensor_id, cpu, temperature)
SELECT
  time,
  sensor_id,
  random() AS cpu,
  random()*100 AS temperature
FROM generate_series(now() - interval '60 days', now(), interval '5 seconds') AS g1(time), generate_series(1,4,1) AS g2(sensor_id);
```

#### Load data from S3 - Optional
Ingest IoT device data from S3 via Online S3 Connector (https://docs.tigerdata.com/migrate/latest/livesync-for-s3/#sync-data-from-s3)
e.g. s3://tiger-demo-data/sensor_data.csv

### 3. Columnar Compression 
Automatically compress Hypertable via columnstore policy:
```sql
-- A default 7-day columnstore policy is auto-created at table creation; remove it first:
CALL remove_columnstore_policy('sensor_data');
CALL add_columnstore_policy('sensor_data', after => INTERVAL '1 days');
```

### 4. Continuous Aggregates
Create self-updating materialized views for instant analytics:
```sql
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
```

## Getting Started

### Using psql Command Line

Run the entire workshop non-interactively:

```bash
psql "postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require" \
  -f Hands-on-workshop-IoTData-psql.sql
```

Or connect interactively and run the sections one at a time:

```bash
psql "postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require"
```

The script creates the tables, simulates the sensor dataset (via
`generate_series`), and walks through the analytics, compression, continuous
aggregate, and real-time update steps — including timing comparisons that
demonstrate the performance improvements.


## Workshop Highlights

- **Real Data**: Uses randomly generated data for IoT sensors
- **Performance Optimization**: Compare query times before and after compression
- **Storage Efficiency**: See 10x storage reduction with columnar compression
- **Automatic Updates**: Demonstrate real-time continuous aggregate updates
- **Production Ready**: Learn policies for automatic compression and aggregate refreshing

## Data Sources

The workshop uses randomply generated IoT sensor data with parameters like Interval Range, Reporting Frequency etc. 

## License

MIT License

## Acknowledgments

This workshop was created by Dario Govedarovic/TigerData and is based on the official Tiger Data "Simulate an IoT sensor dataset" tutorial.
