# Well Production Monitoring — Grafana Dashboard

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
| `url` | Tiger Cloud endpoint in `host:port` format — **no** `postgres://` prefix |
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
| Dashboard not visible | `well-production.json` placed in `provisioning/dashboards/` instead of `dashboards/` | File must be in `grafana/dashboards/`, not inside the `provisioning/` tree 
