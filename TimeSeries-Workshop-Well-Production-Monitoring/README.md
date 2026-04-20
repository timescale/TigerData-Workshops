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



# Optional Instructions — Well Production Monitoring (Grafana Dashboard)

Local Grafana instance provisioned via Docker, backed by a [Tiger Cloud](https://tigerdata.com) TimescaleDB service. Visualizes 15-minute wellhead telemetry across 20 wells spanning four U.S. basins.


<img width="1495" height="896" alt="Screenshot 2026-04-16 at 12 41 25" src="https://github.com/user-attachments/assets/7f003b24-8e76-4077-9eac-9c440f2520bb" />

---

## Requirements

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) ≥ 4.x
- A running Tiger Cloud service with the well production schema loaded
- Network access to your Tiger Cloud endpoint from localhost

---

## Repository Layout

```
well-dashboard/
├── docker-compose.yml                          # Grafana service definition
└── grafana/
    ├── provisioning/
    │   ├── datasources/
    │   │   └── tigercloud.yml                  # Tiger Cloud datasource config
    │   └── dashboards/
    │       └── provider.yml                    # Dashboard file provider
    └── dashboards/
        └── well-production.json                # Pre-built dashboard definition
```

---

## Configuration

### Environment

All connection details are declared in `grafana/provisioning/datasources/tigercloud.yml`. Update the following fields to match your Tiger Cloud service before deploying:

| Field | Description |
|-------|-------------|
| `url` | Tiger Cloud endpoint in `host:port` format |
| `user` | Database username (default: `tsdbadmin`) |
| `secureJsonData.password` | Database password |
| `database` | Target database name (default: `tsdb`) |

> **Note:** Grafana's PostgreSQL datasource provisioning requires `url` to be `host:port` only. Full connection strings (`postgres://...`) will cause a parse error.

---

## Deployment

### 1. Clone / create the project directory

```bash
mkdir -p ~/well-dashboard/grafana/provisioning/datasources
mkdir -p ~/well-dashboard/grafana/provisioning/dashboards
mkdir -p ~/well-dashboard/grafana/dashboards
cd ~/well-dashboard
```

### 2. Create configuration files

**`docker-compose.yml`**
```yaml
services:
  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: admin
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning
      - ./grafana/dashboards:/var/lib/grafana/dashboards
```

---

**`grafana/provisioning/datasources/tigercloud.yml`**
```yaml
apiVersion: 1
datasources:
  - name: Tiger Cloud
    type: postgres
    uid: tigercloud
    url: <your-service-host>:<port>          # e.g. abc123.tsdb.cloud.timescale.com:34095
    database: tsdb
    user: tsdbadmin
    editable: true
    secureJsonData:
      password: <your-password>
    jsonData:
      sslmode: require
      postgresVersion: 1600
      timescaledb: true
```

---

**`grafana/provisioning/dashboards/provider.yml`**
```yaml
apiVersion: 1
providers:
  - name: default
    type: file
    options:
      path: /var/lib/grafana/dashboards
```

---

**`grafana/dashboards/well-production.json`**

Paste the JSON below into this file:

```json
{
  "title": "Well Production Monitoring",
  "uid": "well-production-v1",
  "timezone": "browser",
  "schemaVersion": 38,
  "refresh": "1m",
  "time": { "from": "now-7d", "to": "now" },
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "Active Wells",
      "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 },
      "datasource": { "type": "postgres", "uid": "tigercloud" },
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "reduceOptions": { "calcs": ["lastNotNull"] }
      },
      "fieldConfig": {
        "defaults": { "color": { "fixedColor": "green", "mode": "fixed" } }
      },
      "targets": [{
        "datasource": { "type": "postgres", "uid": "tigercloud" },
        "rawQuery": true,
        "rawSql": "SELECT COUNT(*) AS \"Active Wells\" FROM wells WHERE status = 'Active'",
        "format": "table",
        "refId": "A"
      }]
    },
    {
      "id": 2,
      "type": "stat",
      "title": "Avg Oil Rate — last 2h (BOPD)",
      "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 },
      "datasource": { "type": "postgres", "uid": "tigercloud" },
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "reduceOptions": { "calcs": ["lastNotNull"] }
      },
      "fieldConfig": {
        "defaults": {
          "color": { "fixedColor": "dark-green", "mode": "fixed" },
          "decimals": 1
        }
      },
      "targets": [{
        "datasource": { "type": "postgres", "uid": "tigercloud" },
        "rawQuery": true,
        "rawSql": "SELECT ROUND(AVG(oil_rate)::numeric, 1) AS \"Avg Oil (BOPD)\" FROM well_production WHERE time > NOW() - INTERVAL '2 hours'",
        "format": "table",
        "refId": "A"
      }]
    },
    {
      "id": 3,
      "type": "stat",
      "title": "Avg Gas Rate — last 2h (MCFD)",
      "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 },
      "datasource": { "type": "postgres", "uid": "tigercloud" },
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "reduceOptions": { "calcs": ["lastNotNull"] }
      },
      "fieldConfig": {
        "defaults": {
          "color": { "fixedColor": "blue", "mode": "fixed" },
          "decimals": 1
        }
      },
      "targets": [{
        "datasource": { "type": "postgres", "uid": "tigercloud" },
        "rawQuery": true,
        "rawSql": "SELECT ROUND(AVG(gas_rate)::numeric, 1) AS \"Avg Gas (MCFD)\" FROM well_production WHERE time > NOW() - INTERVAL '2 hours'",
        "format": "table",
        "refId": "A"
      }]
    },
    {
      "id": 4,
      "type": "stat",
      "title": "Avg Wellhead Pressure — last 2h (PSI)",
      "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 },
      "datasource": { "type": "postgres", "uid": "tigercloud" },
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "reduceOptions": { "calcs": ["lastNotNull"] }
      },
      "fieldConfig": {
        "defaults": {
          "color": { "fixedColor": "orange", "mode": "fixed" },
          "decimals": 0
        }
      },
      "targets": [{
        "datasource": { "type": "postgres", "uid": "tigercloud" },
        "rawQuery": true,
        "rawSql": "SELECT ROUND(AVG(wellhead_pressure)::numeric, 0) AS \"Avg WHP (PSI)\" FROM well_production WHERE time > NOW() - INTERVAL '2 hours'",
        "format": "table",
        "refId": "A"
      }]
    },
    {
      "id": 5,
      "type": "timeseries",
      "title": "Total Oil & Gas Production",
      "gridPos": { "h": 9, "w": 24, "x": 0, "y": 4 },
      "datasource": { "type": "postgres", "uid": "tigercloud" },
      "fieldConfig": {
        "defaults": { "custom": { "lineWidth": 2, "fillOpacity": 8 } },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "Gas (MCFD)" },
            "properties": [{ "id": "custom.axisPlacement", "value": "right" }]
          }
        ]
      },
      "options": {
        "tooltip": { "mode": "multi" },
        "legend": { "displayMode": "list", "placement": "bottom" }
      },
      "targets": [{
        "datasource": { "type": "postgres", "uid": "tigercloud" },
        "rawQuery": true,
        "rawSql": "SELECT time_bucket('4 hours', time) AS time, ROUND(SUM(oil_rate)::numeric, 0) AS \"Oil (BOPD)\", ROUND(SUM(gas_rate)::numeric, 0) AS \"Gas (MCFD)\" FROM well_production WHERE $__timeFilter(time) GROUP BY 1 ORDER BY 1",
        "format": "time_series",
        "refId": "A"
      }]
    },
    {
      "id": 6,
      "type": "timeseries",
      "title": "Avg Wellhead Pressure by Basin",
      "gridPos": { "h": 9, "w": 12, "x": 0, "y": 13 },
      "datasource": { "type": "postgres", "uid": "tigercloud" },
      "fieldConfig": {
        "defaults": {
          "custom": { "lineWidth": 2, "fillOpacity": 5 },
          "unit": "psi"
        }
      },
      "options": {
        "tooltip": { "mode": "multi" },
        "legend": { "displayMode": "list", "placement": "bottom" }
      },
      "targets": [{
        "datasource": { "type": "postgres", "uid": "tigercloud" },
        "rawQuery": true,
        "rawSql": "SELECT time_bucket('4 hours', wp.time) AS time, w.field_name AS metric, ROUND(AVG(wp.wellhead_pressure)::numeric, 0) AS value FROM well_production wp JOIN wells w ON wp.well_id = w.id WHERE $__timeFilter(wp.time) GROUP BY 1, 2 ORDER BY 1",
        "format": "time_series",
        "refId": "A"
      }]
    },
    {
      "id": 7,
      "type": "timeseries",
      "title": "Water Cut % Over Time",
      "gridPos": { "h": 9, "w": 12, "x": 12, "y": 13 },
      "datasource": { "type": "postgres", "uid": "tigercloud" },
      "fieldConfig": {
        "defaults": {
          "custom": { "lineWidth": 2, "fillOpacity": 8 },
          "unit": "percent",
          "min": 0,
          "max": 100
        }
      },
      "options": {
        "tooltip": { "mode": "single" },
        "legend": { "displayMode": "list", "placement": "bottom" }
      },
      "targets": [{
        "datasource": { "type": "postgres", "uid": "tigercloud" },
        "rawQuery": true,
        "rawSql": "SELECT time_bucket('4 hours', time) AS time, ROUND((SUM(water_rate) / NULLIF(SUM(oil_rate) + SUM(water_rate), 0) * 100)::numeric, 1) AS \"Water Cut %\" FROM well_production WHERE $__timeFilter(time) GROUP BY 1 ORDER BY 1",
        "format": "time_series",
        "refId": "A"
      }]
    },
    {
      "id": 8,
      "type": "bargauge",
      "title": "Top Wells by Avg Oil Rate",
      "gridPos": { "h": 9, "w": 12, "x": 0, "y": 22 },
      "datasource": { "type": "postgres", "uid": "tigercloud" },
      "options": {
        "orientation": "horizontal",
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "displayMode": "gradient"
      },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "continuous-GrYlRd" },
          "unit": "none"
        }
      },
      "targets": [{
        "datasource": { "type": "postgres", "uid": "tigercloud" },
        "rawQuery": true,
        "rawSql": "SELECT w.well_name AS \"metric\", ROUND(AVG(wp.oil_rate)::numeric, 1) AS \"value\" FROM well_production wp JOIN wells w ON wp.well_id = w.id WHERE $__timeFilter(wp.time) AND w.status = 'Active' GROUP BY w.well_name ORDER BY 2 DESC LIMIT 10",
        "format": "table",
        "refId": "A"
      }]
    },
    {
      "id": 9,
      "type": "table",
      "title": "Field Production Summary",
      "gridPos": { "h": 9, "w": 12, "x": 12, "y": 22 },
      "datasource": { "type": "postgres", "uid": "tigercloud" },
      "options": {
        "sortBy": [{ "displayName": "Avg Oil (BOPD)", "desc": true }],
        "footer": { "show": false }
      },
      "fieldConfig": {
        "defaults": { "custom": { "align": "left" } }
      },
      "targets": [{
        "datasource": { "type": "postgres", "uid": "tigercloud" },
        "rawQuery": true,
        "rawSql": "SELECT w.field_name AS \"Basin\", w.production_type AS \"Type\", COUNT(DISTINCT wp.well_id) AS \"Wells\", ROUND(AVG(wp.oil_rate)::numeric, 1) AS \"Avg Oil (BOPD)\", ROUND(AVG(wp.gas_rate)::numeric, 1) AS \"Avg Gas (MCFD)\", ROUND(AVG(wp.water_rate)::numeric, 1) AS \"Avg Water (BWPD)\", ROUND(AVG(wp.wellhead_pressure)::numeric, 0) AS \"Avg WHP (PSI)\" FROM well_production wp JOIN wells w ON wp.well_id = w.id WHERE $__timeFilter(wp.time) AND w.status = 'Active' GROUP BY 1, 2 ORDER BY 4 DESC NULLS LAST",
        "format": "table",
        "refId": "A"
      }]
    }
  ]
}
```

---

## Running

**Start**
```bash
cd ~/well-dashboard
docker compose up -d
```

**First-run datasource activation** (required once due to a Grafana provisioning quirk with the PostgreSQL `database` field):

1. Navigate to **Connections → Data Sources → Tiger Cloud**
2. Confirm the **Database** field is set to `tsdb`
3. Click **Save & Test** — expect `Database Connection OK`

**Access**
```
http://localhost:3000
```
Credentials: `admin` / `admin`

The **Well Production Monitoring** dashboard is available immediately under **Dashboards**.

**Stop**
```bash
docker compose down
```

---

## Dashboard Panels

| Panel | Type | Query window | Description |
|-------|------|-------------|-------------|
| Active Wells | Stat | — | Count of wells with `status = Active` |
| Avg Oil Rate | Stat | Last 2h | Fleet-wide average oil rate (BOPD) |
| Avg Gas Rate | Stat | Last 2h | Fleet-wide average gas rate (MCFD) |
| Avg Wellhead Pressure | Stat | Last 2h | Fleet-wide average WHP (PSI) |
| Total Oil & Gas Production | Time series | Time picker | Aggregated oil (left axis) and gas (right axis), 4h buckets |
| Avg Wellhead Pressure by Basin | Time series | Time picker | Per-basin WHP trend, 4h buckets |
| Water Cut % | Time series | Time picker | `water / (oil + water)` ratio across all wells |
| Top Wells by Avg Oil Rate | Bar gauge | Time picker | Top 10 active wells ranked by average oil rate |
| Field Production Summary | Table | Time picker | Per-basin breakdown: wells, oil, gas, water, pressure |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `error parsing postgres url` | `url` field contains a `postgres://` connection string | Set `url` to `host:port` only — no scheme or credentials |
| `no default database configured` | Grafana provisioning doesn't persist the `database` field on first load | Open the datasource in the UI, set **Database** to `tsdb`, click **Save & Test** |
| Panels show "No data" | Time range doesn't overlap with loaded data | Expand the time picker; data runs 90 days back from the load date |


## License

MIT License

## Acknowledgments

This workshop was created by the TigerData team. Based on TigerData's oil and gas industry solutions — [https://www.tigerdata.com/oil-and-gas](https://www.tigerdata.com/oil-and-gas).
