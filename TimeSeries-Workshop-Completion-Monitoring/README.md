# Oil & Gas Well Completion Monitoring - Hydraulic Fracturing Stage Analytics

## Overview

Hydraulic fracturing (completions) generates thousands of high-frequency sensor readings — treating pressure, slurry pump rate, proppant concentration, and downhole pressure — at 5-second intervals from surface treating iron and downhole gauges.

A completions engineer monitors these signals in real time against the engineered pump schedule (the "design"), watching for screenouts, pressure anomalies, or rate deviations that require immediate field decisions. After the job, the same data drives post-job completion analysis, design optimization, and reservoir characterization.

TigerData handles this workload natively: sub-second ingest during active pumping, columnar compression on completed stage history, continuous aggregates for 1-minute trend dashboards, and full SQL joins across the stage hierarchy, pump schedule design tables, and multi-job completion records.

## What You'll Learn

- **Hypertables**: Time-partitioned tables optimised for high-frequency frac telemetry (5-second intervals)
- **Columnar Compression**: 90%+ storage reduction on completed stage data that improves, not degrades, query performance
- **Continuous Aggregates**: Pre-computed 1-minute rollups that auto-refresh as live pump data arrives
- **Real-Time Updates**: Materialized views that reflect live telemetry without manual refresh
- **Tiered Storage**: Hot/warm/cold tier management on S3 for multi-job, multi-year completion history
- **Data Retention**: Automated lifecycle policies balancing raw telemetry cost vs long-term record keeping
- **Design vs Actual**: JOIN pump schedule design tables to live telemetry for execution adherence monitoring

## Contents

- **`Hands-on-workshop-completion-monitoring-psql.sql`**: Complete workshop for psql command-line interface

## Prerequisites

- Create a TigerData Cloud service with time-series and analytics enabled at [https://console.cloud.timescale.com/signup](https://console.cloud.timescale.com/signup)
- Install psql CLI (recommended): [https://www.tigerdata.com/blog/how-to-install-psql-on-mac-ubuntu-debian-windows](https://www.tigerdata.com/blog/how-to-install-psql-on-mac-ubuntu-debian-windows)
- Connection string from the TigerData Console: `postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require`
- Basic SQL knowledge

## Sample Architecture with TigerData

![Sample Architecture with TigerData](https://imgur.com/j1H6zxv.png)

## Architecture Highlights

**Unified Data Flow**: Ingest real-time pump data from treating iron instrumentation, surface data units (SDUs), and downhole gauges directly into TigerData Cloud — no intermediate pipeline required.

**Stage-Scoped Storage**: All telemetry partitioned and segmented by `stage_id` — the natural unit of frac operations. Per-stage queries touch only the relevant compressed segment, not the full job history.

**Real-Time Dashboards**: Live treating pressure, slurry rate, and proppant concentration trends using Grafana, Power BI, or any PostgreSQL-compatible visualization tool — connected directly to the continuous aggregate.

**Post-Job Analytics**: Design vs actual comparison, screenout analysis, and inter-well completion optimization using standard SQL across the full job hierarchy.

## Data Structure

### Four-Table Schema

```
completion_jobs          ←  one row per frac job (well + service company + job metadata)
    │
    └── frac_stages      ←  one row per stage (depths, design, actuals, result)
            │
            ├── frac_telemetry  ←  HYPERTABLE: 5-second pump data (treating pressure,
            │                      slurry rate, proppant concentration, BHP, hydrostatic)
            │
            └── pump_schedule   ←  engineered sub-stage sequence (design volumes,
                                   rates, proppant targets for each pumping step)
```

### completion_jobs — Job-Level Metadata

```sql
CREATE TABLE completion_jobs (
  id                       SERIAL        PRIMARY KEY,
  job_identifier           VARCHAR(20)   NOT NULL,    -- anonymised job code
  pad_identifier           VARCHAR(20)   NOT NULL,
  formation                VARCHAR(50)   NOT NULL,    -- target zone (e.g. 'Bakken', 'Wolfcamp A')
  basin                    VARCHAR(50)   NOT NULL,
  operator                 VARCHAR(100)  NOT NULL,
  service_company          VARCHAR(100),
  wireline_company         VARCHAR(100),
  latitude                 DOUBLE PRECISION,
  longitude                DOUBLE PRECISION,
  total_stages             INTEGER       NOT NULL,
  job_start_date           DATE          NOT NULL,
  max_working_pressure_psi INTEGER       NOT NULL     -- surface pressure limit
);
```

### frac_stages — Per-Stage Geometry and Results

```sql
CREATE TABLE frac_stages (
  id                         SERIAL         PRIMARY KEY,
  job_id                     INTEGER        NOT NULL REFERENCES completion_jobs (id),
  stage_number               INTEGER        NOT NULL,
  stage_start_time           TIMESTAMPTZ,
  stage_end_time             TIMESTAMPTZ,
  perf_top_ft                INTEGER,                 -- top perforation, measured depth
  perf_bottom_ft             INTEGER,                 -- bottom perforation, measured depth
  plug_depth_ft              INTEGER,                 -- frac plug set depth
  design_fluid_bbl           DOUBLE PRECISION,
  design_proppant_lbs        DOUBLE PRECISION,
  actual_fluid_bbl           DOUBLE PRECISION,
  actual_proppant_lbs        DOUBLE PRECISION,
  fluid_efficiency_pct       DOUBLE PRECISION,        -- actual / design × 100
  proppant_efficiency_pct    DOUBLE PRECISION,
  pump_time_minutes          DOUBLE PRECISION,
  avg_treating_pressure_psi  DOUBLE PRECISION,
  max_treating_pressure_psi  DOUBLE PRECISION,
  stage_result               VARCHAR(20)    DEFAULT 'Completed'
                             CHECK (stage_result IN ('Completed', 'Screenout', 'Abandoned', 'In Progress'))
);
```

### frac_telemetry — Real-Time Pump Data (Hypertable)

```sql
CREATE TABLE frac_telemetry (
  time                        TIMESTAMPTZ      NOT NULL,
  stage_id                    INTEGER          NOT NULL,
  treating_pressure_psi       DOUBLE PRECISION,        -- surface treating pressure
  slurry_rate_bpm             DOUBLE PRECISION,        -- pump rate, barrels per minute
  proppant_concentration_ppg  DOUBLE PRECISION,        -- downhole prop concentration, lb/gal
  bottomhole_pressure_psi     DOUBLE PRECISION,        -- BHP (calculated or measured)
  hydrostatic_pressure_psi    DOUBLE PRECISION,        -- hydrostatic column pressure
  slurry_density_ppg          DOUBLE PRECISION,        -- slurry density, lb/gal
  FOREIGN KEY (stage_id) REFERENCES frac_stages (id)
) WITH (
  tsdb.hypertable,
  tsdb.partition_column   = 'time',
  tsdb.enable_columnstore = true,
  tsdb.segmentby          = 'stage_id',         -- segment by stage, not well
  tsdb.orderby            = 'time DESC',
  tsdb.sparse_index       = 'minmax(treating_pressure_psi), minmax(slurry_rate_bpm)'
);
```

### pump_schedule — Engineered Sub-Stage Design

```sql
CREATE TABLE pump_schedule (
  id                         SERIAL         PRIMARY KEY,
  stage_id                   INTEGER        NOT NULL REFERENCES frac_stages (id),
  substage_number            INTEGER        NOT NULL,
  fluid_type                 VARCHAR(50),             -- 'Slickwater', 'Linear Gel'
  proppant_type              VARCHAR(50),             -- '100 Mesh', '40/70 Mesh', 'None'
  design_volume_bbl          DOUBLE PRECISION,
  design_rate_bpm            DOUBLE PRECISION,        -- target pump rate
  design_proppant_lbs        DOUBLE PRECISION,
  design_concentration_ppg   DOUBLE PRECISION,        -- proppant target, lb/gal
  max_pressure_psi           INTEGER
);
```

## Key Features Demonstrated

### 1. Stage-Scoped Hypertable Partitioning
TigerData partitions `frac_telemetry` into weekly chunks and segments by `stage_id`. A query replaying one stage never touches data from other stages — critical when a job has 20–35 stages and thousands of stages exist across a multi-job dataset.

### 2. High-Frequency Data Generation
Configurable data volume — each stage generates 5-second telemetry for its full pump duration:

```sql
-- 125 stages × 120 min × 12 readings/min (5-sec) ≈ 180,000 rows

INSERT INTO frac_telemetry (time, stage_id, treating_pressure_psi, ...)
SELECT
  fs.stage_start_time + (g.n * INTERVAL '5 seconds'),
  fs.id,
  ...
FROM frac_stages fs
JOIN completion_jobs cj ON fs.job_id = cj.id
CROSS JOIN generate_series(0, (fs.pump_time_minutes * 12 - 1)) AS g(n);
```

Volume reference:

| Configuration | Rows |
|---|---|
| 1 stage × 120 min | ~1,440 |
| 1 job × 25 stages | ~36,000 |
| 5 jobs × 125 stages (default) | ~180,000 |
| 20 jobs × 500 stages | ~720,000 |

### 3. Columnar Compression
Compress completed stage telemetry automatically after the active pumping buffer:

```sql
CALL add_columnstore_policy('frac_telemetry', after => INTERVAL '12 hours');
```

### 4. Continuous Aggregates at 1-Minute Granularity
Pre-compute per-minute stage summaries that auto-refresh as new pump data arrives:

```sql
CREATE MATERIALIZED VIEW stage_minute_summary
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
  time_bucket('1 minute', time)   AS minute,
  stage_id,
  AVG(treating_pressure_psi)      AS avg_tp_psi,
  MAX(treating_pressure_psi)      AS max_tp_psi,
  AVG(slurry_rate_bpm)            AS avg_rate_bpm,
  AVG(proppant_concentration_ppg) AS avg_conc_ppg,
  AVG(bottomhole_pressure_psi)    AS avg_bhp_psi,
  ...
FROM frac_telemetry
GROUP BY minute, stage_id;
```

### 5. Design vs Actual Queries
JOIN the engineered pump schedule to actual telemetry to evaluate execution adherence:

```sql
SELECT
  ps.substage_number,
  ps.proppant_type,
  ps.design_concentration_ppg,
  AVG(ft.proppant_concentration_ppg) AS actual_conc_ppg,
  ps.design_rate_bpm,
  AVG(ft.slurry_rate_bpm)            AS actual_rate_bpm
FROM pump_schedule ps
JOIN frac_stages fs    ON ps.stage_id = fs.id
JOIN frac_telemetry ft ON ft.stage_id = fs.id
  AND ft.time BETWEEN fs.stage_start_time + sub_stage_window
  ...
GROUP BY ps.substage_number, ...;
```

## Getting Started

### Using psql Command Line

```bash
psql "postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require" \
  -f Hands-on-workshop-well-completion-monitoring-psql.sql
```

Or connect interactively and run sections one at a time:

```bash
psql "postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require"
```

## Workshop Highlights

- **Real-World Schema**: 5 frac jobs across Williston Basin (Bakken/Three Forks), Permian Basin (Wolfcamp A/Spraberry), and Eagle Ford — with realistic pressure ranges, stage depths, and pump rate profiles by basin
- **Frac Curve Simulation**: Each stage simulates a characteristic pad → proppant ramp → flush pressure and rate profile — not random noise
- **Performance Comparison**: Run the stage replay query on raw `frac_telemetry` vs `stage_minute_summary` and observe the execution time difference
- **Storage Efficiency**: See compression ratios on high-frequency frac telemetry (expect 88–92%)
- **Design vs Actual**: Query `pump_schedule` joined to stage actuals to evaluate execution quality
- **Automatic Refresh**: Real-time continuous aggregate refresh vs PostgreSQL materialized view limitations

## Why TigerData for Completion Monitoring

| Challenge | TigerData Solution |
|---|---|
| 5-second telemetry from dozens of simultaneous frac jobs | High-ingest hypertables with automatic chunk partitioning |
| Stage replay across 30+ stages per job | `segmentby = 'stage_id'` — per-stage queries skip all other segments |
| Live pressure alerts during pumping | Real-time continuous aggregates — no manual REFRESH required |
| Post-job analysis across full job history | Columnar compression + tiered S3 storage for multi-year completion records |
| Design vs actual execution queries | Full PostgreSQL — JOIN pump\_schedule to live frac\_telemetry |
| Screenout detection across thousands of stages | Sparse indexes skip segments — `WHERE treating_pressure_psi > 9000` never decompresses irrelevant data |

## License

MIT License

## Acknowledgments

This workshop was created by the TigerData team. Based on TigerData's oil and gas industry solutions — [https://www.tigerdata.com/oil-and-gas](https://www.tigerdata.com/oil-and-gas).

