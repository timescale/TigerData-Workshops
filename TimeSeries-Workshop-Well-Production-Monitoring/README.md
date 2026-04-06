# Oil & Gas Well Production Monitoring and Optimization

## Overview

Oil and gas operations generate continuous streams of production telemetry from wellheads, downhole gauges, and surface equipment. Pressure readings, flow rates, temperature, and choke position arrive at 15-minute intervals across dozens or hundreds of wells — and must be stored, queried, and acted on at scale, across years of history.

TigerData is purpose-built for this workload. High-ingest time-series data with multi-year retention, 90%+ compression, and SQL-based analytics — no new query language, no pipeline overhead, no costly rebuilds as asset counts grow.

This workshop shows how to build a production-grade well monitoring database on TigerData, from schema design to automated data lifecycle management.

## What You'll Learn

- **Hypertables**: Time-partitioned tables optimised for high-ingest production telemetry
- **Columnar Compression**: 90%+ storage reduction that improves, not degrades, query performance
- **Continuous Aggregates**: Pre-computed daily rollups that auto-refresh as new data arrives
- **Real-Time Updates**: Materialized views that reflect live telemetry without manual refresh
- **Tiered Storage**: Hot/warm/cold data management on S3 for multi-year production history
- **Data Retention**: Automated lifecycle policies for raw telemetry
- **Geospatial queries using PostGIS** : Find wells within a radius of a point, Filter wells by bounding box

## Contents

- **`Hands-on-workshop-well-production-monitoring-psql.sql`**: Complete workshop for psql command-line interface

## Prerequisites

- Create a TigerData Cloud service with time-series and analytics enabled at [https://console.cloud.timescale.com/signup](https://console.cloud.timescale.com/signup)
- Install psql CLI (recommended): [https://www.tigerdata.com/blog/how-to-install-psql-on-mac-ubuntu-debian-windows](https://www.tigerdata.com/blog/how-to-install-psql-on-mac-ubuntu-debian-windows)
- Connection string from the TigerData Console: `postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require`
- Basic SQL knowledge

## Sample Architecture with TigerData

![Sample Architecture with TigerData](https://imgur.com/j1H6zxv.png)

## Architecture Highlights

**Unified Data Flow**: Ingest SCADA telemetry, field sensors, and historian exports directly into TigerData Cloud (AWS or Azure) — no intermediate pipeline required.

**Centralised Storage**: All production data in one place — raw telemetry, compressed history, and pre-aggregated rollups — queryable with standard SQL.

**Real-Time Analytics**: SQL-based dashboards, alerts, and visualisations using Grafana, Power BI, or any PostgreSQL-compatible tool.

**AI & ML Integration**: Connect production history to forecasting models, decline curve analysis, and anomaly detection pipelines.

## Data Structure

### Reference table for well and field metadata

```sql
CREATE TABLE wells (
  id              SERIAL       PRIMARY KEY,
  well_name       VARCHAR(50)  NOT NULL,
  field_name      VARCHAR(50)  NOT NULL,
  operator        VARCHAR(100) NOT NULL,
  production_type VARCHAR(10)  NOT NULL CHECK (production_type IN ('Oil', 'Gas', 'Dual')),
  status          VARCHAR(20)  NOT NULL CHECK (status IN ('Active', 'Inactive', 'Suspended')),
  depth_ft        INTEGER,
  latitude        DOUBLE PRECISION,
  longitude       DOUBLE PRECISION,
  spud_date       DATE
);
```

### Hypertable for real-time wellhead and downhole telemetry

```sql
CREATE TABLE well_production (
  time                  TIMESTAMPTZ      NOT NULL,
  well_id               INTEGER          NOT NULL,
  oil_rate              DOUBLE PRECISION,    -- bbl/day equivalent (instantaneous)
  gas_rate              DOUBLE PRECISION,    -- Mcf/day equivalent (instantaneous)
  water_rate            DOUBLE PRECISION,    -- bbl/day equivalent (instantaneous)
  wellhead_pressure     DOUBLE PRECISION,    -- psi
  wellhead_temperature  DOUBLE PRECISION,    -- degrees Fahrenheit
  choke_size            DOUBLE PRECISION,    -- 1/64th inch
  downhole_pressure     DOUBLE PRECISION,    -- psi
  FOREIGN KEY (well_id) REFERENCES wells (id)
) WITH (
  tsdb.hypertable,                               -- Make this table a TimescaleDB hypertable for efficient time-series storage
  tsdb.partition_column   = 'time',              -- Partition data by the 'time' column
  tsdb.enable_columnstore = true,                -- Enable columnar storage for better compression and query performance
  tsdb.segmentby          = 'well_id',           -- Segment the hypertable by 'well_id' for faster per-well queries
  tsdb.orderby            = 'time DESC',         -- Order data by timestamp descending
  tsdb.sparse_index       = 'minmax(wellhead_pressure), minmax(oil_rate)'   -- Sparse indexes for efficient min/max queries on these columns
);
```

## Key Features Demonstrated

### 1. Hypertable Creation
TigerData partitions the telemetry table into weekly time-based chunks automatically. During time-range queries, irrelevant chunks are skipped entirely — no rows scanned, no I/O.

### 2. Data Generation
Configurable data volume via psql variable — adjust `history_days` to generate more or less history:

```sql
-- 90 days × 20 wells × 96 readings/day ≈ 172,800 rows

INSERT INTO well_production (time, well_id, oil_rate, gas_rate, ...)
SELECT time, well_id, ...
FROM generate_series(
    NOW() - (:history_days || ' days')::INTERVAL,
    NOW(),
    INTERVAL '15 minutes'
) AS g1(time),
generate_series(1, 20) AS g2(well_id);
```

Volume reference:

| history_days | Rows (20 wells, 15-min interval) |
|---|---|
| 30 | ~57,600 |
| 90 | ~172,800 |
| 365 | ~700,800 |

### 3. Columnar Compression
Automatically compress production telemetry older than 7 days:

```sql
CALL add_columnstore_policy('well_production', after => INTERVAL '7 days');
```

### 4. Continuous Aggregates
Pre-compute daily production summaries that auto-refresh as new telemetry arrives:

```sql
CREATE MATERIALIZED VIEW daily_well_production
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
  time_bucket('1 day', time) AS day,
  well_id,
  AVG(oil_rate)              AS avg_oil_bopd,
  AVG(gas_rate)              AS avg_gas_mcfd,
  SUM(oil_rate) / 96.0      AS total_oil_bbls,
  AVG(wellhead_pressure)     AS avg_whp_psi,
  ...
FROM well_production
GROUP BY day, well_id;
```

## Getting Started

### Using psql Command Line

```bash
psql "postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require" \
  -f Hands-on-workshop-well-production-monitoring-psql.sql
```

Or connect interactively and paste sections as you go:

```bash
psql "postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require"
```

## Workshop Highlights

- **Real-World Schema**: 20 wells across Permian Basin, Eagle Ford, Bakken, and Marcellus — with realistic production profiles, pressure ranges, and well statuses
- **Performance Comparison**: Run the same query on raw hypertable vs continuous aggregate and observe the difference
- **Storage Efficiency**: See compression ratios on real production telemetry (expect 66–90%+)
- **Automatic Updates**: Real-time continuous aggregate refresh vs PostgreSQL materialized view limitations
- **Production-Ready Policies**: Automatic compression, tiered storage, and data retention configured in minutes

## Why TigerData for Oil & Gas Production Monitoring and Optimization

| Challenge | TigerData Solution |
|---|---|
| Petabytes of production history | 90%+ compression + tiered S3 storage |
| 15-min readings from 1000's of wells | High-ingest hypertables with chunk auto-partitioning |
| Dashboards spanning years of data | Continuous aggregates — pre-computed, auto-refreshing |
| Complex joins with well/field metadata | Full PostgreSQL — joins, window functions, CTEs |
| SCADA and historian integration | Standard PostgreSQL wire protocol — no new connectors |
| Compliance and long-term retention | Tiered storage retains all data; retention policies control raw costs |


## License

MIT License

## Acknowledgments

This workshop was created by the TigerData team. Based on TigerData's oil and gas industry solutions — [https://www.tigerdata.com/oil-and-gas](https://www.tigerdata.com/oil-and-gas).
