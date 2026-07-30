# OEE Monitoring Workshop -- Time-Series Manufacturing Analytics with TigerData

## Overview

This workshop demonstrates how to build an **end-to-end OEE (Overall
Equipment Effectiveness)** analytics pipeline using **TigerData
(Timescale)**.\
You will create a production-grade time-series schema for a plant with
**three manufacturing lines (A, B, C)**, simulate 7 days of 5-second OEE
measurements, apply columnstore compression, build a 1-hour continuous
aggregate, and run real analytical queries.

This workshop is ideal for anyone interested in understanding how
TigerData handles **industrial IoT**, **manufacturing telemetry**, **OEE
monitoring**, **high-frequency data ingestion**, and **real-time
analytics** at scale.

## What You'll Learn

-   **Hypertables for OEE Data**\
    Build a time-series optimized hypertable storing high-frequency
    OEE + environmental metrics.

-   **Production Line Metadata Modeling**\
    Create a dimension table to join OEE metrics with line-level
    attributes.

-   **Realistic OEE Data Simulation**\
    Auto-generate 7 days of per-line OEE data, including availability,
    performance, quality, runtime, output, temperature, vibration,
    energy, and more.

-   **Columnstore Compression**\
    Enable high-value compression yielding 10×+ smaller storage and
    faster scans.

-   **Continuous Aggregates (CAGGs)**\
    Build a 1-hour rolling aggregate for instant plant-level analytics.

-   **Real-Time Updates**\
    Use real-time CAGG mode to merge raw + aggregated data
    transparently.

-   **Analytical Queries**\
    Explore OEE per line and compare row counts between raw and
    aggregated data.

## Contents

-   **`OEE_Workshop.sql`** -- the complete SQL workshop script; run it end to
    end (see [Getting Started](#getting-started))

## Prerequisites

-   A TigerData Cloud service with **time-series + analytics enabled**\
-   Optional: Install the `psql` CLI\
-   Your connection string for TigerData\
-   Basic SQL knowledge

## Getting Started

### Using psql

Run the entire workshop non-interactively:

```bash
psql "postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require" \
  -f OEE_Workshop.sql
```

Or connect interactively and run the sections one at a time:

```bash
psql "postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require"
```

### Using the TigerData Console

Open the **Data** tab, create a new query, and paste the contents of
`OEE_Workshop.sql` (or run it section by section).

The script creates the schema, generates 7 days of demo data, enables
compression, builds the 1-hour continuous aggregate, and runs the example
queries end to end.

## Data Model

### Production Line Metadata

``` sql
CREATE TABLE production_lines (
    line_id    TEXT PRIMARY KEY,
    line_name  TEXT,
    plant      TEXT,
    target_oee DOUBLE PRECISION
);
```

### OEE Time-Series Hypertable

``` sql
CREATE TABLE oee_timeseries (
    time TIMESTAMPTZ NOT NULL,
    line_id TEXT NOT NULL,
    shift SMALLINT,
    planned_time_seconds SMALLINT,
    planned_downtime_seconds SMALLINT,
    unplanned_downtime_seconds SMALLINT,
    runtime_seconds SMALLINT,
    ideal_cycle_time_seconds DOUBLE PRECISION,
    actual_output INTEGER,
    good_output INTEGER,
    availability DOUBLE PRECISION,
    performance DOUBLE PRECISION,
    quality DOUBLE PRECISION,
    oee DOUBLE PRECISION,
    temperature_c DOUBLE PRECISION,
    vibration_mm_s DOUBLE PRECISION,
    noise_db DOUBLE PRECISION,
    energy_kwh DOUBLE PRECISION,
    PRIMARY KEY (line_id, time)
)
WITH (
   tsdb.hypertable,
   tsdb.partition_column='time',
   tsdb.segmentby='line_id',
   tsdb.orderby='time DESC'
);
```

## Data Generation

Generate 7 days of 5-second interval demo data:

``` sql
SELECT generate_oee_timeseries_demo(7, 5);
```

## Compression

``` sql
-- Columnstore is enabled by the segmentby/orderby settings in CREATE TABLE,
-- which auto-creates a default 7-day policy. Replace it with a 24-hour policy:
CALL remove_columnstore_policy('oee_timeseries');
CALL add_columnstore_policy('oee_timeseries', after => INTERVAL '24 hours');

-- Compress existing chunks now to see immediate storage savings:
SELECT compress_chunk(c, true) FROM show_chunks('oee_timeseries') c;
```

## Continuous Aggregates

``` sql
CREATE MATERIALIZED VIEW oee_1h
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', time) AS bucket,
    line_id,
    ...
FROM oee_timeseries
GROUP BY bucket, line_id;

ALTER MATERIALIZED VIEW oee_1h
SET (timescaledb.materialized_only = false);
```

## Example Queries

### OEE per line (24 hours)

``` sql
SELECT
    line_id,
    ROUND((AVG(oee) * 100)::numeric, 2) AS oee_pct
FROM oee_timeseries
WHERE time >= now() - INTERVAL '24 hours'
GROUP BY line_id;
```

### Row count comparison

``` sql
SELECT
    (SELECT COUNT(*) FROM oee_timeseries) AS raw_count,
    (SELECT COUNT(*) FROM oee_1h)         AS cagg_1h_count;
```

## License

MIT License

## Acknowledgments

This workshop was created by the TigerData Solutions team.
