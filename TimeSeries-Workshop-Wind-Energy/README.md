# Wind Energy — Spatial Time Series on Fixed Assets

## Overview

A wind portfolio has a natural hierarchy — **region → plant → turbine** — and every level is both a
*place* and a *time series*. A region is a polygon and an hourly output curve. A plant is a point and
a power purchase agreement. A turbine is a coordinate in a grid and a reading every fifteen minutes.

This part is about how to model that in one database so that both halves of every question stay
cheap: *where* answered by PostGIS, *when* answered by hypertables, and the combination answered
without a second system or a nightly export.

Two design decisions carry most of the weight:

**Geometry lives where it is stable.** Turbine coordinates are set when the foundation is poured, so
they belong on dimension tables where one GiST index serves every spatial query. Anything derived
from geometry that will not change — region membership, the pairwise distances between neighbouring
turbines — is computed **once at seed time** and stored, so the hot path only ever compares numbers.
the Fleet Tracking workshop inverts this completely, because a delivery van's location is a time series rather than an
attribute.

**Aggregates are a rollup chain shaped like the drill-down.** Four continuous aggregates form a
three-level chain, and each dashboard tier reads exactly the level matching its own cardinality. A
fleet overview reads six rows an hour, not ninety-six. Measured below: the fleet view returns in
**0.38 ms** against **6.78 ms** for the same figures computed from raw.

For how the rows are produced — the site catalogue, the geodesic grid, the wind and wake models, the
configuration knobs — see **[DATA-GENERATION.md](DATA-GENERATION.md)**.

## What You'll Learn

- **Where to put geometry**: `geography` on dimension tables vs on fact rows, and how that choice
  follows from whether the thing moves
- **Denormalizing for groupability**: why `plant_id` and `region_name` sit on the fact table, and the
  continuous-aggregate trap that forces it
- **Precomputing spatial relationships**: splitting fixed geometry from the dynamic predicate so the
  per-reading cost is a single angle comparison
- **Designing a cagg hierarchy for a UI**: one level per drill-down tier, each built on the level
  below
- **Aggregating physical quantities correctly**: why plant output is `SUM(AVG(...))` and never
  `SUM(power_kw)`, and why every average needs a weight to survive a rollup
- **Reading the plans**: index-assisted `ST_DWithin`, KNN with `<->`, and when the index silently is
  not used
- **Detecting degradation**: storing expected *and* actual power so a failing turbine is visible,
  and why capacity factor cannot substitute for a performance ratio
- **ACID across asset tables and hypertables**: one transaction covering relational rows, PostGIS
  geometry and time-series chunks — and what a split architecture costs you instead
- **Lifecycle policies**: the columnstore/retention/refresh interactions that quietly destroy data

## Contents

| File | What it does |
| --- | --- |
| `01_extensions.sql` | Verify `timescaledb`, create `postgis`, seed `workshop_config` |
| `02_schema.sql` | `regions`, `plants`, `turbines`, `turbine_neighbors`, `turbine_faults`, `turbine_health()` |
| `03_hypertables.sql` | `wind_measurements`, `power_generation` — declarative, with denormalized dimensions |
| `04_seed_turbines.sql` | Regions, site catalogue, plants, geodesic grids, wake geometry, GeoJSON export |
| `05_power_curve_function.sql` | `power_from_wind_speed()` — an `IMMUTABLE` derived metric |
| `06_wind_model_functions.sql` | `wind_at()`, `apply_wake()`, `backfill_wind()`, `advance_wind()` |
| `07_backfill_historical.sql` | **2 years** of 15-minute history, loaded in chunk-aligned batches |
| `08_continuous_aggregates.sql` | **The rollup chains** — six aggregates (four power, two weather), filled incrementally with a reconnect between each |
| `09_compression_retention.sql` | Columnstore after 7 days, retention after 1 year |
| `10_advance_simulation.sql` | Re-run to append new data |
| `11_geospatial_queries.sql` | Spatial query gallery, plant layout, wake analysis, **underperformance detection** |
| `12_acid_expand_plant.sql` | **ACID across assets and telemetry** — expand a plant in one transaction |
| `13_turbine_history.sql` | **Source selection by zoom level** — creates nothing; explains the inline union the turbine dashboard carries and proves with `EXPLAIN` that branches are pruned |
| `14_tiered_storage.sql` | **Scattered tiering to object storage** — a per-object threshold derived from each dashboard's read pattern (raw 26 weeks, hourly aggregates 52, daily aggregates 104). Opt-in, and skips cleanly where tiering is unavailable |

## Prerequisites

1. A TigerData Cloud service — <https://console.cloud.timescale.com/signup>
2. Connection string: `postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require`
3. `psql` — [install guide](https://www.tigerdata.com/blog/how-to-install-psql-on-mac-ubuntu-debian-windows)
4. Basic SQL knowledge

```bash
cd TimeSeries-Workshop-Wind-Energy
set -a && source .env && set +a
for f in sql/*.sql; do echo "── $f"; psql -v ON_ERROR_STOP=1 -f "$f" || break; done
```

---

## Getting Started

This workshop is self-contained: its own `sql/`, its own `reset_demo.sh`, its own
Grafana dashboards. It shares nothing with the other workshops in this repo except the
database you point it at, and even that is optional — see *Sharing a database* below.

### 1. Point it at a Tiger Cloud service

Connection settings live in **one file at the repository root**, shared by every workshop here:

```bash
cd ..                      # the repo root
cp .env.example .env
$EDITOR .env               # host, database, user, password from the service's Connect panel
cd -                       # back to this workshop
```

`PGSSLMODE` must be `require` for a Tiger Cloud service. Both `psql` and Grafana read this same
file, so credentials are entered once however many workshops you run. A workshop-local `.env`
still takes precedence if you create one — the escape hatch for pointing a single workshop at a
different service.

### 2. Build the data

```bash
./reset_demo.sh --yes --plants 6 --turbines-per-plant 8 --days 730
```

The script reads the root `.env`, drops this workshop's objects, runs every file in `sql/` in order,
and prints verification counts. Before it touches anything it reads the service's own memory
and CPU, projects the row count, estimates the build time and warns only if the volume is too
large for **that** service. `./reset_demo.sh --help` documents every flag.

To run the files by hand instead — which is the point, if you are reading them:

```bash
set -a; . ../.env; set +a
for f in sql/*.sql; do echo "── $f"; psql -v ON_ERROR_STOP=1 -f "$f" || break; done
```

### 3. Start Grafana

```bash
docker compose --env-file ../.env up -d
open http://localhost:3000          # admin / GF_SECURITY_ADMIN_PASSWORD from the root .env
```

`--env-file ../.env` is what lets the root file set `GRAFANA_PORT`. Compose reads
variables used *inside* a compose file from its own `--env-file`, not from the `env_file:` key —
`env_file:` supplies the container, which is what Grafana needs to interpolate `${PGHOST}` in
`datasources/datasource.yml`. Without the flag it still starts, on the default port 3000.

Grafana expands `${VAR}` inside provisioning files, so the datasource is wired from the
root `.env` with no hand-editing. The dashboards in `grafana/` are provisioned automatically.

<details>
<summary><code>docker-compose.yml</code>, inlined</summary>

```yaml
# Grafana only.
#
# The database for this workshop is a Tiger Cloud service, not a container —
# fill in your connection details in the REPO-ROOT .env (copy ../.env.example) and
# both psql and Grafana read the same credentials.
#
#   docker compose --env-file ../.env up -d    then open http://localhost:3000  (admin / see .env)

services:
  grafana:
    image: grafana/grafana:latest
    # Named per workshop. The workshops are meant to be run ONE AT A TIME, so this
    # is not about running them concurrently — it is that a container name is
    # global to the daemon and is held even by a STOPPED container. Sharing one
    # would make `up` fail with "container name already in use" when you move to
    # the next workshop without a `docker compose down` first.
    container_name: wind-workshop-grafana
    ports:
      - "${GRAFANA_PORT:-3000}:3000"
    # Grafana expands ${VAR} inside provisioning files, so the datasource is wired
    # straight from the root .env — no hand-editing of datasource.yml required.
    #
    # `env_file:` puts these in the CONTAINER. It does NOT feed the ${...}
    # substitutions in this file, such as GRAFANA_PORT above — compose reads
    # those from its own --env-file only. Verified: without --env-file the port
    # falls back to the default below, which is why the documented command
    # passes `--env-file ../.env`. The default means it also works without it.
    env_file: ../.env
    environment:
      GF_SECURITY_ADMIN_PASSWORD: ${GF_SECURITY_ADMIN_PASSWORD:-admin}
      # The dashboards ship read-only geomap panels; allow anonymous viewing so
      # a workshop room can follow along without each person logging in.
      GF_AUTH_ANONYMOUS_ENABLED: "true"
      GF_AUTH_ANONYMOUS_ORG_ROLE: Viewer
    volumes:
      # Provisioning: datasource + dashboard provider definitions.
      - ./grafana-provisioning:/etc/grafana/provisioning:ro
      # The dashboard JSON files. Deliberately NOT under /var/lib/grafana — that
      # path is a named volume below, and nesting a bind mount inside a named
      # volume is fragile (it can hang container start on Docker Desktop). Keep
      # the two mount trees separate; dashboards.yml points here.
      - ./grafana:/etc/grafana/dashboards:ro
      # Region boundary polygons for the geomap overlay. Grafana's geomap can only
      # read GeoJSON from a STATIC FILE under its public directory — there is no
      # query-driven polygon layer — so the region boundaries are exported from
      # PostGIS once (step 04 has the query) and mounted here.
      - ./grafana-geojson:/usr/share/grafana/public/maps/workshop:ro
      # Custom marker symbols. Same constraint as the GeoJSON: the geomap resolves
      # `symbol` paths relative to Grafana's public directory, so a custom glyph has
      # to live inside it. Referenced as `img/icons/workshop/wind-arrow.svg`.
      # Not used by the shipped dashboards any more — the wind arrows are route
      # layers, which need no asset. Kept because GRAFANA_PLATFORM.md documents
      # the rotated-marker alternative, which does need it.
      - ./grafana-icons:/usr/share/grafana/public/img/icons/workshop:ro
      # Grafana's own state, so preferences survive `docker compose down`. No need to
    # name this per workshop: compose prefixes named volumes with the project
    # (directory) name, so each workshop gets its own `<project>_grafana-data`.
      - grafana-data:/var/lib/grafana
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O- http://localhost:3000/api/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 12
    restart: unless-stopped

volumes:
  grafana-data:
```
</details>

### Sharing a database

Every workshop in this repo can run against the same Tiger Cloud service. Table names do not
collide, and `workshop_config` — the tunables table — is created with `IF NOT EXISTS` by each
workshop, which seeds only its own keys. `reset_demo.sh --hard` deletes only the keys carrying
this workshop's `Wind Energy: ` description prefix and drops the table only once nothing is left, so
hard-resetting one workshop never resets another's tunables.

They also share the root `.env`, deliberately — one set of credentials for all of them.

These workshops are designed to be run **one at a time**, so Grafana uses a single
`GRAFANA_PORT` (3000) for all of them and there is nothing to keep apart. The container is
still named per workshop, though: a container name is global to the Docker daemon and is
held even by a *stopped* container, so a shared one would make `up` fail with
"container name already in use" the next time you move to a different workshop without a
`docker compose down` first. Named volumes need no such care — compose already prefixes
them with the project directory name.

# Part A — Combining Geometry and Time Series

## Where geometry goes, and why

```
regions            boundary  GEOMETRY(Polygon, 4326)     polygon, never moves
  └── plants       center_location  GEOGRAPHY(Point, 4326)   point, never moves
        └── turbines  location  GEOGRAPHY(Point, 4326)       point, never moves
              │
              ├── wind_measurements   time, turbine_id, plant_id, ...     NO geometry
              └── power_generation    time, turbine_id, plant_id, ...     NO geometry
```

Neither hypertable has a geometry column. That is the defining feature of the fixed-location
pattern: because a turbine never moves, storing its coordinates on 69,000 fact rows would be 69,000
copies of one immutable value. Every spatial question is answered by joining the fact rows to a
dimension table that has exactly 96 rows and one GiST index.

The cost of that choice is a join for spatial queries. The benefit is that the join is against a tiny
table, the index is tiny enough to stay cached, and the fact rows compress better without a
geometry column in them.

`geography` rather than `geometry` for points, because this fleet spans 220° of longitude:

| | `geometry` | `geography` |
| --- | --- | --- |
| Distance units | degrees — not a unit of length | **metres, on the spheroid** |
| A degree of longitude | 111 km at equator, 64 km at 55°N | n/a |
| Index | GiST, BRIN, SP-GiST | GiST only |
| Function coverage | ~300 | ~40 |

Region *boundaries* are `geometry` instead, because containment is a topological test with no distance
in it, and `ST_MakeEnvelope`/`ST_Contains` are geometry-side functions. The rule of thumb throughout:
**store `geography` and measure in it; cast to `geometry` only for the operations geography lacks,
and cast back before measuring anything.**

## Denormalizing dimensions onto fact rows

`power_generation` carries `plant_id` and `region_name` even though both are reachable through
`turbines`. This is not a shortcut — it is forced by how continuous aggregates work.

Continuous aggregates *can* join a hypertable to a plain table (TimescaleDB 2.10+). But **only
changes to the hypertable are tracked for invalidation.** Redraw a region boundary or move a turbine
between plants, and a joined aggregate keeps serving the old grouping indefinitely with nothing to
signal it is stale. There is no error, no warning, and no way to notice short of a full manual
re-refresh.

Writing the dimension onto the fact row at insert time removes the trap and makes the whole rollup
chain in Part B possible, since hierarchical aggregates cannot join at all.

The tradeoff is the usual one: historical rows keep the label they were assigned. For portfolio
reporting that is arguably the behaviour you want — last March's output *was* produced by the plant
as it was configured last March.

## Computing spatial relationships once

`turbine_neighbors` is the clearest expression of the fixed-location pattern. Whether turbine A wakes
turbine B depends on two things with completely different lifetimes:

| | Changes | Where it lives |
| --- | --- | --- |
| Distance, bearing, wake deficit, wake half-angle | never | `turbine_neighbors`, computed at seed |
| "Is the wind coming from that neighbour *now*?" | every reading | `apply_wake()`, one angle comparison |

So the expensive spatial mathematics — pairwise distances and azimuths across every turbine in a
plant — runs once. The per-reading cost is `angular_diff_deg(wind_direction, bearing) <= half_angle`
against ~9 indexed rows.

Getting the neighbour search itself to scale mattered too:

```sql
-- QUADRATIC: ST_Distance in a WHERE clause cannot use an index. The planner
-- materialises all n² same-plant pairs and discards most of them.
WHERE ST_Distance(a.location, b.location) <= 12 * p.rotor_diameter_m

-- LINEAR: ST_DWithin inside a LATERAL. Plan shows
--   Index Scan using idx_turbines_location
--   Index Cond: (location && _st_expand(a.location, ...))
CROSS JOIN LATERAL (
  SELECT b.turbine_id FROM turbines b
   WHERE b.plant_id = a.plant_id
     AND ST_DWithin(b.location, a.location, 12 * p.rotor_diameter_m)
) nb
```

Identical output; only the cost differs. Note the radius may be a per-row expression — unlike the KNN
`<->` operator, which only gets index assistance when one operand is a **constant**. Put the
reference point in a subquery or a column reference and the planner silently falls back to a
sequential scan: same answers, wrong performance, no warning. Always `EXPLAIN` a KNN query.

## Spatial questions against a time series

The queries in `sql/11_geospatial_queries.sql`, and the shape each one demonstrates:

| Question | Verb | Pattern |
| --- | --- | --- |
| "Substation failed — what output is at risk?" | `ST_DWithin` | spatial filter on the dimension, `LATERAL` for latest reading per turbine |
| "Nearest turbines to a maintenance crew" | `<->` then `ST_Distance` | order with the operator, report with the function |
| "Map bounding box per region" | `ST_Extent`, `ST_Centroid` | geometry aggregates over the dimension table |
| "Which region would a new site belong to?" | `ST_Contains` | point-in-polygon as an ad-hoc lookup |
| "Do nearby turbines see the same weather?" | `ST_Distance` + cagg | **spatial and temporal in one query** |
| "Which turbine shades which, how often?" | precomputed geometry + cagg | fixed geometry joined to measured outcome |
| "Plant footprint and power density" | `ST_ConvexHull`, `ST_Buffer` | `::geography` before `ST_Area`, or you get square degrees |

Two recurring traps worth internalising:

- **`<->` on geography measures sphere; `ST_Distance` defaults to spheroid.** They disagree by up to
  0.3%. Order with `<->`, report with `ST_Distance`.
- **`ST_Area` on a 4326 geometry returns square degrees** — not a unit of area, and it varies with
  latitude. Cast to `::geography` first.

---

# Part B — The Continuous Aggregate Hierarchy

## One aggregate per drill-down tier

```
power_generation                      raw — 96 turbines × 4 readings/hour (15-minute)
     │                                      6.73 M rows over the 2-year default
     └── cagg_turbine_power_hourly    one row per TURBINE per hour
              ├── cagg_turbine_power_daily    one row per TURBINE per day
              └── cagg_plant_power_hourly     one row per PLANT per hour
                       └── cagg_regional_power_hourly
                                               one row per REGION per hour

wind_measurements                     raw — the weather the power was made in
     │
     └── cagg_wind_hourly             free + waked wind, temperature, per turbine/hour
              └── cagg_wind_daily     the same, per turbine/day
```

Two chains, not one, because they answer different questions: the power chain is
"what did the fleet produce", the weather chain is "what resource was there to
produce it from".

The weather chain carries wind **direction** as well — but not as an angle. A
bearing cannot be averaged arithmetically: the mean of 350° and 10° is 0°, while
`AVG()` returns 180°, the maximum possible error on a value that looks perfectly
reasonable in a table. So the aggregates store the **sum of each reading's
unit-vector components**:

```sql
SUM(SIN(RADIANS(wind_direction_deg))) AS dir_sin_sum,
SUM(COS(RADIANS(wind_direction_deg))) AS dir_cos_sum,
COUNT(*)                              AS readings
```

and the read views recover the bearing with `ATAN2(dir_sin_sum, dir_cos_sum)`.

Three properties make this the right representation rather than a workaround:

- **It is legal in a continuous aggregate.** `SIN`, `COS`, `RADIANS` and `SUM` are
  all `IMMUTABLE` and parallel-safe, and `SUM` has a combine function.
- **Component sums are additive**, so `cagg_wind_daily` simply adds the 24 hourly
  sums and lands on exactly the value the day's 96 raw readings would have given —
  verified to nine decimal places in `13_turbine_history.sql`. An angle would need
  the circular machinery again at every level, and a mean of means would be wrong
  at every level.
- **It carries more information than an angle.** The resultant's length over the
  reading count is the mean resultant length, 0–1: a direct measure of how steady
  the direction was, exposed as `dir_consistency`. That is the concentration half
  of a wind rose, and it is unrecoverable from a stored average.

One guard: when a bucket's readings oppose each other the vectors cancel, and
`ATAN2(0, 0)` returns 0 — a confident northerly out of nothing. The views return
`NULL` below a resultant of 1% of the readings.

The practical payoff is that the turbine dashboard's direction panel is
tier-selected like every other panel, instead of being permanently pinned to raw.

**How much data this is** is set by four `workshop_config` values, all of them
exposed by `reset_demo.sh`:

| Setting | Default | Flag |
| --- | --- | --- |
| `backfill_days` | 730 (2 years) | `--days N` |
| `num_plants` | 12 (two per region) | `--plants N` |
| `turbines_per_plant` | 8 | `--turbines-per-plant N` |
| `wind_step_minutes` | 15 | — |

At the defaults: 6.73 M rows in each of two hypertables, 886 MB all in, 199 s to
build both parts. `--days 90` brings that to 625 K rows and 18 s. Full table in
[DATA-GENERATION.md](DATA-GENERATION.md#expected-volumes-default-config).

Every level after the first is built on the level below it, never on the raw hypertable. Two payoffs:

**Refresh is cheap.** Rolling 96 pre-computed turbine rows into 12 plant rows costs far less than
re-reading the raw rows, and 12 plant rows into 6 region rows costs almost nothing. The expensive scan
happens once, at the bottom, and every level above reuses it.

**Reads are flat.** Each dashboard tier reads the level matching its own cardinality, so rows scanned
stays roughly constant however large the fleet grows.

## The tiers, measured

Rows returned for a 7-day window, and execution time for the query each tier actually
runs. Every figure is the **median of five runs** on a warm cache — a single sample is
worthless here, and an earlier version of this table reported a cold-cache outlier that
made the hourly tier look slower than raw.

| Tier | Reads | Rows | Exec |
| --- | --- | --- | --- |
| **1 — Fleet overview** | `v_region_hourly` → `cagg_regional_power_hourly` | 1,002 | **0.64 ms** |
| **2 — Drill into a region** | `v_plant_hourly` → `cagg_plant_power_hourly` | 334 | **0.41 ms** |
| **3 — Drill into a plant** | `v_turbine_hourly` → `cagg_turbine_power_hourly` | 1,336 | **1.19 ms** |
| *(the same fleet overview, from raw)* | `power_generation` — 65084 rows scanned | 1,008 | **11.50 ms** |

The fleet overview is **18× faster** from its own aggregate than computing the same six
lines from raw, and raw scans 65084 rows to produce 1,008. That gap widens with fleet
size, because the region aggregate stays at six rows an hour however many turbines exist
while the raw scan grows with every one of them.

Tier 3 is the slowest of the three and that is correct: it is the only one that legitimately needs
per-turbine detail. The design point is that you pay for that detail **only when you have drilled
down far enough to need it**.

## Tier 4: the same query, a different source per zoom level

The three tiers above each read one fixed aggregate, because each answers a question at one
granularity. The turbine detail view cannot work that way — it has to serve a six-hour ramp and a
five-year trend from the same panel. So it picks its source from the zoom level instead.

Grafana exposes `$__interval_ms`: the width of one plotted point in milliseconds, derived from the
time range. Every panel carries a three-branch `UNION ALL` **inline**, each branch gated on it:

```sql
WITH tiers AS (
  SELECT day    AS time, avg_power_kw, ... FROM cagg_turbine_power_daily
   WHERE turbine_id = ... AND $__timeFilter(day)
     AND $__interval_ms >= 86400000
  UNION ALL
  SELECT bucket AS time, avg_power_kw, ... FROM cagg_turbine_power_hourly
   WHERE turbine_id = ... AND $__timeFilter(bucket)
     AND $__interval_ms >= 3600000 AND $__interval_ms < 86400000
  UNION ALL
  SELECT time,           power_kw,     ... FROM power_generation
   WHERE turbine_id = ... AND $__timeFilter(time)
     AND $__interval_ms <  3600000
)
SELECT t.time, ... FROM tiers t ORDER BY t.time
```

There is no view and no helper function behind it: the whole mechanism is readable and editable in
Grafana's panel editor, and the dashboard depends on nothing but the two aggregates and the raw
hypertable. Note each branch filters on **its own** time column — that is what lets TimescaleDB
exclude chunks inside each branch, which a single outer `WHERE` on the union's output cannot do.

One turbine, a 30-day window, the identical query at three zoom levels — medians of
five warm runs. The `$__interval_ms` values are what Grafana sends at
`maxDataPoints: 100`, i.e. `range / 100`:

| Window | `$__interval_ms` | Tier chosen | Rows | Exec |
| --- | --- | --- | --- | --- |
| 6 hours | 216,000 | `power_generation` raw | 2,879 | **2.06 ms** |
| 30 days | 25,920,000 | `cagg_turbine_power_hourly` | 719 | **1.05 ms** |
| 5 years | 1,576,800,000 | `cagg_turbine_power_daily` | 30 | **0.20 ms** |

The gates themselves are fixed at the tiers' bucket widths — 3,600,000 ms and
86,400,000 ms — and do not depend on `maxDataPoints`. What `maxDataPoints` changes is
`interval_ms = range / maxDataPoints`, and therefore the window size at which each
fixed threshold is crossed: at 100 points the hourly tier engages from ~4.2 days and
the daily tier from 100 days.

10x between the ends, for a question whose *answer* is visually identical at 30 points or 2,880 — and the gap grows with the window, since the raw row count scales with it while the daily count does not.

The part that makes this worth doing rather than clever is that the untaken branches are **not read
and discarded**. By the time the planner sees `6480000 >= 86400000` it is a comparison of two
constants; it folds to `false`, proves that branch can return nothing, and deletes it from the plan.
The discarded branches do not appear as scans with a false condition — they are absent from the
`Append` node entirely, and nothing about those tiers is opened, locked or read.

This is also the design's one fragile point: the gates must stay **decidable before execution**. Wrap
a threshold in a volatile expression, or move the rule into a function that is not marked `IMMUTABLE`,
and all three branches get scanned — silently, and slower than just reading raw would have been.
[13_turbine_history.sql](sql/13_turbine_history.sql) proves the pruning with `EXPLAIN` and *asserts* it
in a `DO` block, so a future edit that breaks the folding fails loudly instead of getting slower.

`cagg_turbine_power_daily` earns its place here. Over 90 days a daily series is 90 points where
hourly would be 2,160 — a difference no chart can render but every query pays for.

### The measurement that has no aggregate

Wind direction is stored on the aggregates too, as the **sum of each reading's unit-vector
components** rather than as an angle — so the direction panel is tier-selected like every other panel.
The reason it cannot be a stored average is worth understanding: a bearing is circular, so the mean of
350° and 10° is 0°, while `AVG()` returns 180° — the maximum possible error, on a value that looks
entirely reasonable. `SUM(SIN(...))` and `SUM(COS(...))` are additive, which is what lets the daily
rollup add the hourly sums and match the raw circular mean exactly, and the resultant's length gives
`dir_consistency` (0–1 steadiness) for free. When readings oppose each other the resultant collapses
and the views return `NULL` rather than the spurious northerly `ATAN2(0, 0)` would produce.

Every region in this workshop happens to have a prevailing bearing between 190° and 305°, so no hour's
samples straddle 0°/360° and a naive average would in fact have been accurate. That is exactly the
trap: the bug is invisible until a plant is built at a northerly site, and then the stored history is
wrong with no error and no migration to blame. So the aggregates carry no direction column, and the
panel reads raw.

The rule generalises past wind. Anything stored as an angle, a modular counter, or a ratio of ratios
needs its combination rule chosen deliberately before it goes into a continuous aggregate. `AVG()` is
not always the answer, and a cagg will not warn you.

## Capacity factor: what the chain deliberately cannot carry

Capacity factor is output over **rated** capacity, and rated capacity lives on `plants` — a plain
table an aggregate must not join. So the aggregates store power, and three thin views divide it out at
read time:

```sql
v_region_hourly     → cagg_regional_power_hourly  + rated capacity per region
v_plant_hourly      → cagg_plant_power_hourly     + rated capacity per plant
v_turbine_hourly    → cagg_turbine_power_hourly   + rated capacity per turbine
```

That split is the right one rather than a compromise. Rated capacity is dimension data — it changes
when a machine is repowered. Baked into a materialized aggregate, historical rows would keep the old
denominator forever with no way to notice. Divided at read time, a corrected nameplate immediately
fixes every figure including the past.

These views are what the dashboard queries. The aggregates are an implementation detail behind them.

## Aggregating physical quantities correctly

Two arithmetic traps, both of which produce plausible-looking wrong numbers.

### Plant output is not `SUM(power_kw)`

Summing raw power readings inside a bucket sums across **both turbines and time**. With hourly
backfill each turbine contributes one reading, so the sum happens to equal plant output — and the
moment the live simulation starts writing every 15 minutes, each turbine contributes four and "plant
output" jumps 4× with no change in generation. Measured on this dataset while building it:
**32,909 kW became 67,275 kW** when readings per bucket went from 8 to 16.

Power is instantaneous. Aggregate it across turbines by summing; across time by averaging:

```sql
SUM(avg_power_kw)   -- sum of per-turbine hourly MEANS = plant mean output, kW
```

Reading-count independent. Rolling up a pre-averaged child level makes this natural rather than
fiddly — another reason the hierarchy earns its place. For energy, multiply by bucket width.

### Every average needs its weight

`AVG(avg_power_kw)` is only correct when every input bucket holds the same number of readings. Ours
do not — backfill writes hourly, live writes every 15 minutes — so:

```sql
SUM(avg_power_kw * readings) / NULLIF(SUM(readings), 0)
```

`MIN` and `MAX` compose without this caveat, which is why they roll up directly. `readings` is carried
at every level purely to be this weight.

Step 08 verifies the whole chain against the raw table:

```
 raw_avg_turbine_kw | from_turbine_cagg | from_plant_cagg | from_region_cagg
           1418.578 |          1418.578 |        1418.578 |         1418.578
```

## Design rules for the chain

**Carry every grouping column down to the bottom.** Hierarchical aggregates cannot join, so
`cagg_turbine_power_hourly` holds `plant_id` and `region_name` even though neither identifies a
turbine. A column absent from the bottom can never be grouped by above it.

**`materialized_only = false` on every level.** In a hierarchy real-time aggregation *recurses*: a
query against the region view blends materialized region rows with live aggregation reaching all the
way down to raw rows newer than the last refresh. One `true` anywhere in the chain stops the recursion
there and every level above silently goes stale between refreshes. It has also been off by default
since TimescaleDB 2.13, so it must be stated rather than assumed.

**`GROUP BY` the `time_bucket` expression, not the alias.** This one cost real debugging time. When
the output column is named `bucket` *and* the input column from the child aggregate is also named
`bucket`, PostgreSQL resolves the bare name against input columns first — so `GROUP BY bucket`
silently groups by the child's bucket instead of this level's `time_bucket()` call, and TimescaleDB
rejects the view with:

```
ERROR:  continuous aggregate view must include a valid time bucket function
```

which is a confusing message for what is really name shadowing. `cagg_turbine_power_daily` escapes it
only by accident, because it aliases to `day`.

**Bucket widths must be integer multiples.** 1 day over 1 hour is fine; so is 1 hour over 1 hour, a
1× multiple, which is how the grain-only rollups work. 90 minutes over 1 hour is rejected, and so is
a month over a week, because the number of weeks in a month is not an integer.

## Lifecycle interactions that destroy data

`sql/09_compression_retention.sql`. Three of these are silent failures.

**The declarative `WITH (tsdb.segmentby ...)` clause already created a columnstore policy.** Adding
another raises `ERROR 42710`. The repo pattern is remove-then-add, which is also idempotent.

**`add_columnstore_policy` races your own manual conversion.** The scheduler may start the job within
seconds, and `if_not_columnstore` defaults to true but does *not* save you — the flag is evaluated
when the call begins, so a chunk the policy compresses microseconds later still raises. Handle it per
chunk with an exception block.

**Retention versus refresh `start_offset`.** If an aggregate looks further back than retention keeps
raw data, a refresh recomputes buckets whose source rows are gone and rewrites them as **empty** —
destroying rolled-up history that looked safe. Here retention is 1 year against 7–10 day offsets, a
wide margin, but check it whenever you touch either number.

Columnstore chunks are **not** read-only, incidentally. Hypercore accepts inserts, updates and deletes
transparently; the Fleet Tracking workshop proves it in a transaction. Compression measured here: **77–82% saved**.

---

# Part C — Detecting Underperformance

## Why output alone cannot tell you

A turbine quietly making 8% less than it should is worth more to find than almost anything else in
this dataset — roughly 980 MWh a year on a 4 MW machine — and it is invisible in an output chart.
800 kW is excellent in a 6 m/s breeze and alarming in a gale.

So `power_generation` stores **two** power figures:

| Column | Meaning |
| --- | --- |
| `expected_power_kw` | what the power curve says the wind this turbine MEASURED should have produced |
| `power_kw` | what it actually produced |

Both are powers, so the ratio aggregates cleanly at any grain:

```sql
performance_ratio = SUM(power_kw) / SUM(expected_power_kw)
```

Storing the ratio instead would need a weight to survive a rollup. Storing two sums does not — which
is why the aggregate hierarchy carries `expected_power_kw` at every tier and the three read views
divide it out.

**Wake loss is accounted separately, and deliberately.** Expected output is computed at the wind the
turbine actually saw, wake included — a machine cannot be blamed for standing behind another one.
Wake is a property of grid *position*; degradation is a property of the *machine*. Keeping them apart
is what lets a monitoring system stop chasing the back row of every array.

## The fault model

`turbine_faults` is the **answer key**, and nothing in the telemetry references it. `turbine_health()`
applies it during generation; the detectors find underperformers statistically and only then check
their work.

Faults come in two shapes, and the difference is the whole difficulty of the problem:

| `ramp_days` | Shape | Examples | Detectability |
| --- | --- | --- | --- |
| 0 | step change | pitch/yaw misalignment, curtailment, thermal derate | a threshold catches it |
| > 0 | gradual ramp | blade soiling, leading-edge erosion, gearbox wear | no single reading looks wrong |

`detected_at` deliberately lags `started_at`, and some rows have it NULL — still undiagnosed. That
gap is what monitoring exists to close. One seeded row is a `grid_curtailment`, which looks exactly
like a fault in the data and is not one; telling those apart needs context the telemetry does not
carry.

## Three detectors, and their tradeoff

`sql/11_geospatial_queries.sql` builds them in increasing sensitivity:

1. **Threshold on performance ratio** — blunt, catches step faults.
2. **Trend** — compare a recent window against an older baseline for the same turbine. Catches the
   gradual ones a threshold cannot.
3. **Peer comparison within a plant** — the most sensitive, and the one that needs the geometry.
   Turbines in the same plant share weather and model, so compare each against its plant *median*
   and the residual is the machine. This is why the fleet is modelled as plants: the peer group is
   what makes a 3% anomaly detectable.

Then the file scores the simple threshold against the answer key. Measured on the shipped dataset:

| Outcome | Turbines |
| --- | --- |
| true positive (caught it) | 13 |
| false positive (wild goose chase) | 2 |
| **false negative (missed it)** | **3** |
| true negative | 78 |

The false negatives are the point. They are early-ramp erosion faults currently costing under 1% —
no threshold can see them, and lowering the threshold to catch them would flood the operations team
with false positives. Detectors 2 and 3 exist for exactly that case.

The clearest illustration in the data is `Albacete_0202-T01`: grid position 0,0 with **0% wake loss**
and yet **−15 percentage points** against its peers. Nothing about its position explains it.

---

# Part D — ACID Across Assets and Telemetry

`sql/12_acid_expand_plant.sql`. A repowering project adds four turbines to a plant. One business
event, six objects, three kinds of thing:

| Object | Change | Kind |
| --- | --- | --- |
| `plants` | `UPDATE turbine_count` | relational |
| `turbines` | `INSERT` × 4 on a geodesic grid | relational + PostGIS |
| `turbine_neighbors` | rebuilt for the **whole plant** | relational + PostGIS |
| `wind_measurements` | ~2,900 rows | **hypertable** |
| `power_generation` | ~2,900 rows | **hypertable** |
| 4 continuous aggregates | invalidated | materialized rollups |

In PostgreSQL that is one `BEGIN … COMMIT`. Either the plant has twelve turbines with complete
geometry, complete wake relationships and complete history, or it has eight and nothing changed.

Note the third row: the wake table is rebuilt for **every** turbine in the plant, not just the new
ones. An existing machine that stood in clean air may now have a new turbine directly upwind, so its
physics changed without anything about it being edited. Keeping geometry and telemetry consistent
through that is exactly the kind of thing that becomes an offline batch job — with a window of
inconsistency — when the two live in different systems.

The file demonstrates three things:

- **Rollback leaves nothing behind**, across relational rows, PostGIS geometry *and* time-series
  chunks. Inside the transaction: 12 turbines, 82 wake pairs, 8,652 telemetry rows. After
  `ROLLBACK`: byte-for-byte the original state.
- **A constraint violation after thousands of telemetry rows have landed takes the whole expansion
  with it.** In a two-system architecture the asset registry would have committed and you would own
  an inconsistency, discovered later, by someone else, on a dashboard.
- **After a real commit**, `plants.turbine_count` equals the actual turbine count, every new machine
  has geometry *and* wake pairs *and* history, and both orphan checks return zero. The new turbines
  produce 651 kW against 717 kW for the incumbents at identical 100% performance ratio — lower
  because they sit in the newly added grid row and are more waked, which is correct.

**The one thing not in the transaction** is the aggregate refresh, because
`refresh_continuous_aggregate()` cannot run inside a transaction block. That is not a gap: every
aggregate uses `materialized_only = false`, so real-time aggregation includes the new turbines the
instant the transaction commits, before any refresh runs.

**A note on foreign keys.** The hypertables deliberately have *no* FK to `turbines` — an index probe
plus a parent row lock per row is a real cost on a high-ingest table, for a guarantee the writer
already has. The orphan check runs as a periodic assertion instead. That is a decision about the FK
specifically; atomicity across assets and telemetry holds either way.

---

## What to Look At in Grafana

Three dashboards, one per tier, wired together by drill-through links. Each reads the aggregate
matching its own cardinality, which is what keeps every view fast regardless of fleet size.

### 1. Global Fleet  (`/d/wind-global`)

Reads `cagg_regional_power_hourly` — six rows an hour for the whole world.

- **Worldwide production map.** Region shapes are the **convex hull of each region's turbines,
  buffered 60 km** — the actual operating territory. They replaced bounding-box rectangles, which
  covered 10–25× more ground than the assets occupy (measured: footprints are 3.7–11.8% of the
  envelope area). Markers sit at each region's asset centroid, sized by output and coloured by
  performance ratio, so a degrading region turns orange while still producing well.
- **Region metrics table** — current-hour figures. **Click a region name to drill through**, carrying
  the time range with it.
- **Production timeline** stacked by region, and a **performance ratio timeline** beneath it. Compare
  the two: output can rise while health falls.

Grafana's geomap has no query-driven polygon layer, so the footprints come from a static GeoJSON file
exported by step 04 and the live values ride on the marker layer.

### 2. Region  (`/d/wind-region`)

Reads `cagg_plant_power_hourly`. Arrives with `$region` set by the drill-through.

- **Plant map**, auto-zoomed to the region (`view: fit`), one marker per plant.
- **Plant metrics table** — **click a plant name to drill into it**.
- **Production and wind timelines** side by side. They are not the same shape: power goes as the
  *cube* of wind speed, so a 10% wind change is a ~33% power change.

### 3. Plant  (`/d/wind-plant`)

Reads `cagg_turbine_power_hourly` — the only tier that needs per-machine detail, and the only one
that pays for it. Filter for a single turbine with `$turbine`.

- **Turbine layout map**, auto-zoomed to the plant, so you see the actual grid: rows 8 rotor
  diameters along the prevailing wind, columns 5 across it, odd rows staggered half a
  spacing so no machine sits directly behind another. Markers sized by output and coloured by
  performance ratio — a faulted machine shows up red in an otherwise green array, with its grid
  position right there.
- **Turbine detail table.** Sort by `performance_ratio_pct` to rank suspects, then read `active_fault`
  to see whether the ranking was right. Note `grid_row` correlates with `wake_loss_pct` but **not**
  with `performance_ratio_pct`.
- **Expected vs actual output** — two traces that sit on top of each other for a healthy turbine. The
  gap *is* the fault: gradual opening is soiling or wear, a step is a pitch fault or curtailment.
- **Fault history** — the answer key, including `days_to_detect`.

Click a turbine name in the table, or a marker on the map, to reach the turbine view.

### 4. Turbine  (`/d/wind-turbine`)

One machine, 30 days by default, panels stacked vertically: specification, position in the array,
wind speed against cut-in/cut-out, direction and temperature, generation against expectation, the
output range inside each bucket, health, wake loss, readings-per-point, fault history, and the
precomputed wake geometry from `turbine_neighbors`.

Unlike the three views above, this one has no fixed source — it reads raw, hourly or daily depending
on how far you have zoomed. Two panels make that visible:

- **Serving Tier** (top right) names the source answering right now: `RAW 15-min`, `HOURLY cagg` or
  `DAILY cagg`. Change the time range and watch it flip.
- **Readings behind each point** (bottom) plots `readings` per plotted point: flat at 1 on raw, 4 on
  hourly, 96 on daily. The first and last bars are lower because the edge buckets are partial — which
  is why the rollups store `readings` and weight by it instead of averaging averages.

- **Wind direction and temperature** is the exception that proves the rule: always raw, because a
  circular quantity has no correct `AVG()`. See above.

## Why TigerData for Spatial Time-Series

| Challenge | Solution |
| --- | --- |
| Location and telemetry live in separate systems | PostGIS and TimescaleDB are both PostgreSQL extensions — one `geography` column, one query language |
| Spatial relationships recomputed on every query | Fixed geometry precomputed once; the hot path compares a single angle against ~9 indexed rows |
| Dashboards recompute years of history per page load | A rollup chain shaped like the drill-down: 0.38 ms for a fleet view against 6.78 ms from raw |
| Dimension edits silently staling materialized rollups | Denormalize the grouping column onto the fact row; aggregates never join |
| Rollups quietly wrong after a rate change | Reading-count-independent power, readings-weighted averages, verified against raw at every level |
| Multi-year telemetry unaffordable to retain | Columnar compression at 77%+, with retention and optional tiering |


## How the backfill is built, and why

Loading two years of 15-minute telemetry for a fleet is the slowest thing this
workshop does, and nearly every decision in it was made by measuring rather than by
reading advice. The reasoning is worth more than the code, so it is spelled out here.

All figures below were measured on `timescale/timescaledb-ha:pg17` (TimescaleDB
2.29.0) in cgroup-limited containers.

### One load session can only use one core

This is the constraint everything else follows from. PostgreSQL's rule:

> If a query contains a data-modifying operation either at the top level or within a
> CTE, no parallel plans for that query will be generated.

The only exceptions are `CREATE TABLE AS`, `SELECT INTO`, `CREATE MATERIALIZED VIEW`
and `REFRESH MATERIALIZED VIEW`. So `INSERT .. SELECT` runs in **one backend on one
core**, and marking `wind_at()` `PARALLEL SAFE` changes nothing about that — that
marking only governs whether a *read* query may use workers.

Measured single-session throughput, counting rows across both hypertables:

| resources | total rows/s |
|---|---|
| 0.5 CPU / 2 GiB | 21,400 |
| 1 CPU / 4 GiB | 40,300 |
| 2 CPU / 8 GiB | 54,600 |
| 4 CPU / 16 GiB | 57,700 |

Flat past about 2 CPU. **Buy CPU for a load only if the loader is parallel**;
otherwise buy memory, which is what the aggregate fill actually needs.
`reset_demo.sh` reads the service's own memory and CPU and sizes its estimate and
its warning from that, rather than assuming a machine.

### Batching is aligned to chunk boundaries

`backfill_wind_window()` batches so that **one batch fills exactly one chunk**, with
the interval read from `timescaledb_information.dimensions` rather than hardcoded.
Batching on an arbitrary period straddles boundaries, so no batch ever completes a
chunk — which matters because of the next point.

Batches entirely older than `columnstore_after_days` are written **straight into the
columnstore** via `timescaledb.enable_direct_compress_insert`. Measured on a 180-day
load: 44 s and 392 MB via the rowstore then converting, against 37 s and 47 MB
writing columnar directly. Aligning the batches is what makes that clean — a chunk
written columnar in one pass never ends up partially compressed.

Note this is a deliberate departure from the general guidance to *disable* the
columnstore during a backfill. That advice targets the cost of writing to the
rowstore and converting afterwards; direct compress skips the conversion entirely,
so it does not apply here. The hot window is still excluded, because
`advance_wind()` writes into it repeatedly and 15-minute inserts land far more
cheaply in the rowstore.

### Chunks are pre-created, and that is the whole reason parallelism works

Splitting the range into disjoint, chunk-aligned windows and giving one to each
worker looks obviously correct. It buys almost nothing:

| | 1 worker | 4 workers | speed-up |
|---|---|---|---|
| workers create their own chunks | 34.3 s | 31.2 s | **1.09x** |
| chunks pre-created first | 34.3 s | **9.3 s** | **3.67x** |

Creating a chunk takes `ShareUpdateExclusiveLock` on the **parent** hypertable, and
PostgreSQL holds locks until the transaction commits. That lock self-conflicts, so
the first worker to create a chunk holds the parent for its *entire* transaction and
the others queue. Sampled mid-run without pre-creation: 3 of 4 backends parked on
`Lock / relation`, every ungranted lock `ShareUpdateExclusiveLock on
power_generation`, and container CPU pinned at 100% of a 400% ceiling. With
pre-creation: all four backends `RUNNING`, zero waits, CPU at 384% of 400%.

`precreate_wind_chunks()` does one cheap serial pass using
[`create_chunk()`](https://www.tigerdata.com/docs/reference/timescaledb/hypertables/create_chunk),
which takes the range explicitly and creates the chunk with zero rows. It is
idempotent — a chunk that already exists returns `created => false` rather than
raising — so re-running it is free.

**This step is not in the documentation.** The published backfill guidance says to
use parallel workers but "ensure time ranges across workers do not overlap, to
prevent contention", which is exactly what the 1.09x row above does. Non-overlapping
ranges are necessary but not sufficient: each worker still has to create its own
chunks, and that is the serialisation. Everything in this section rests on the
measurements above rather than on published advice.

### What is *not* the bottleneck

Ruled out by measurement, each of which seemed plausible first:

- **The read side.** The generator reads five dimension tables on every row
  (`turbines`, `plants`, `regions`, `turbine_neighbors`, `turbine_faults`). Those
  take `AccessShareLock`, which is shared, and all four workers held all five
  simultaneously and all granted. Replacing the two read-heavy functions with
  constants moved 1.07x to only 1.22x.
- **`COPY` instead of `INSERT .. SELECT`.** A dead heat: 7295 ms against 7294 ms.
  The advice to prefer `COPY` is about bulk loading from a client or file, where many
  single-row `INSERT`s pay per-statement overhead. Here the insert is not the cost —
  generating the rows is 85% of it (6012 ms of 7045 ms) — so `COPY` optimises the 15%
  and adds a serialise/pipe/deserialise round trip to do it. It also cannot write two
  hypertables from one `MATERIALIZED` source, which is what guarantees both tables
  get identical values including the sensor noise.
- **Transaction scope.** One transaction per chunk instead of per window: 14%.
- **Ordering the generated rows.** `ORDER BY time` inside a window: about 4%, at the
  edge of noise. Ordering to match `segmentby`/`orderby` added nothing.

### The aggregate fill is parallel by WINDOW, not by aggregate

The eight aggregates form a chain, not a flat set:

```
power_generation  -> turbine_hourly -> plant_hourly -> regional_hourly -> regional_daily
                                    \-> turbine_daily  \-> plant_daily
wind_measurements -> wind_hourly    -> wind_daily
```

Concurrent refreshes of the **same** aggregate over **disjoint** windows are
supported, and that is the axis that pays:

| strategy | time | speed-up |
|---|---|---|
| fully serial | 13590 ms | — |
| **windows of one aggregate concurrently, aggregates in order** | **4805 ms** | **2.83x** |
| aggregates within a dependency level concurrently | 9119 ms | 1.49x |
| both combined | 5664 ms | 2.40x |

Window-parallelism is both faster and simpler, and combining the two oversubscribes
the CPUs. Two things must be right: the windows are aligned to each aggregate's
**materialization** chunk interval (70 days here — TimescaleDB defaults it to 10x the
bucket width, not the bucket width itself), and the aggregates are processed in
dependency order. **Order is a correctness constraint, not a tuning choice**:
refreshing a child before its parent is materialised leaves the child *empty*, and
it does so silently. Do not sort these names alphabetically —
`cagg_plant_power_daily` sorts before `cagg_plant_power_hourly`, which is backwards.

### The fill needs no manual windowing any more

Step 08 used to refresh a month at a time with a `\c` reconnect between aggregates,
because on older versions a single refresh over two years was one operation and got
OOM-killed, and because memory then accumulated across calls in one session. Since
TimescaleDB **2.28.0** `refresh_continuous_aggregate()` refreshes incrementally by
default — `buckets_per_batch` is 10, and each batch runs in its own transaction — so
the engine now provides the bound that scaffolding was buying.

Measured at the volume that used to die (12 plants x 8 turbines x 730 days = 6.73M
rows per hypertable, 8 GiB / 4 CPU), all eight aggregates force-refreshed:

| | time | peak memory |
|---|---|---|
| monthly windows + reconnect per aggregate | 37 s | 2.25 GiB |
| one call per aggregate, fresh connection | 30 s | 2.24 GiB |
| one call per aggregate, one session | 33 s | 2.27 GiB |

Same memory to within noise, nothing OOM-kills, and the simple version is fastest.
`options => '{"buckets_per_batch": 0}'` restores the old single-transaction
behaviour, which is how you would reproduce the original failure.

One trap worth knowing: `psql -c "SET ...; CALL refresh_continuous_aggregate(...)"`
puts both statements in one implicit transaction and **every refresh fails** with
"cannot run inside a transaction block". Use `PGOPTIONS` for the setting, or a
separate invocation.

### Nothing competes with the load

No policy is running while any of this happens, and that falls out of the file order
rather than needing care: step 07 loads the raw data *before* steps 08 and 09 create
any aggregates or policies. Step 08 registers its refresh policies after its fill and
immediately pauses them; step 09 does the same for the columnstore and retention
policies; step 13 resumes everything once the workshop stops bulk-loading. Leaving a
refresh policy running would also break the parallel fill outright — a manual refresh
whose window overlaps a policy's is the one case that genuinely fails with
"could not refresh continuous aggregate due to a concurrent refresh".

### Net effect

| volume | serial | `--jobs 4` |
|---|---|---|
| 1.12M rows/hypertable | 41 s | **21 s** |
| 6.73M rows/hypertable (the old OOM case) | 190 s | **82 s** |

`--jobs` defaults to one worker per detected CPU, capped at 4. `--jobs 1` forces the
serial path, which is also what you get running the SQL files by hand.

## Related workshop

[TimeSeries-Workshop-Fleet-Tracking](../TimeSeries-Workshop-Fleet-Tracking) is the deliberate
counterpart: the same extensions applied to the opposite data shape. Run both against the same
service and the contrast is the lesson.

| | This workshop (fixed assets) | Fleet Tracking (moving entities) |
|---|---|---|
| Where location lives | on the dimension table, written once | on every fact row, 10 s apart |
| Spatial work | done once at seed time, reused forever | done per row, forever |
| Cardinality x rate | 48 turbines x 15 min | 12 drivers x 10 s |
| Tenancy | single-tenant | multi-tenant, per-driver isolation |
| Late data | none | up to 7 days |
| Geospatial verbs | `ST_Project`, `ST_DWithin`, point-in-polygon | `ST_MakeLine`, `ST_LineInterpolatePoint`, `<->` KNN |


## Swapping in Real Weather Data

the Wind Energy workshop's wind is a deterministic climatology model, not a feed. That is a consequence of the
platform: **Tiger Cloud offers neither `http` (pgsql-http) nor `pg_net`**, so SQL cannot make an
outbound request. It also turns out to be pedagogically better — history is reproducible, there is no
API key or rate limit, and the workshop runs on a locked-down conference network.

**This section is an illustration of a constraint, not a recommended path.** In-database HTTP is
not used anywhere in this repo, and the reason is not only that Tiger Cloud lacks the extension:
letting the database engine issue outbound requests turns any SQL injection into server-side
request forgery, gives it reach into internal endpoints and cloud metadata services, keeps API
credentials in the database where a dump carries them, and puts an unbounded blocking network call
inside a transaction. If you want real weather data, fetch it from **outside** the database — see
the Python approach under [TODO](#todo).

With that said, [Open-Meteo](https://open-meteo.com) is the natural data source either way: no API
key, free for non-commercial use, 10,000 calls/day. The `http` sketch below shows what the
in-database version would look like, so the tradeoff is concrete rather than asserted.

```sql
-- Requires pgsql-http, which is NOT on Tiger Cloud. On a self-hosted
-- timescale/timescaledb-ha image the PGDG repo is already configured:
--   FROM timescale/timescaledb-ha:pg17
--   USER root
--   RUN apt-get update && apt-get install -y --no-install-recommends postgresql-17-http
--   USER postgres
CREATE EXTENSION IF NOT EXISTS http;

CREATE OR REPLACE FUNCTION fetch_current_wind(p_turbine_id UUID, p_lat FLOAT8, p_lon FLOAT8)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE payload JSONB;
BEGIN
  SELECT content::jsonb INTO payload
    FROM http_get(format(
      'https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s'
      '&current=wind_speed_10m,wind_direction_10m,temperature_2m&wind_speed_unit=ms',
      p_lat, p_lon));

  INSERT INTO wind_measurements (time, turbine_id, wind_speed_ms, wind_direction_deg,
                                 temperature_c, source)
  VALUES (now(), p_turbine_id,
          (payload -> 'current' ->> 'wind_speed_10m')::FLOAT8,
          (payload -> 'current' ->> 'wind_direction_10m')::FLOAT8,
          (payload -> 'current' ->> 'temperature_2m')::FLOAT8,
          'weather_api');
END $$;
```

For historical backfill, the archive endpoint returns **parallel arrays** under `hourly.time`,
`hourly.wind_speed_10m`, … which you zip with `WITH ORDINALITY` and a lateral join on ordinal
position:

```sql
SELECT (t.value)::timestamptz AS time, (w.value)::FLOAT8 AS wind_speed_ms
  FROM jsonb_array_elements_text(payload -> 'hourly' -> 'time')          WITH ORDINALITY AS t(value, ord)
  JOIN jsonb_array_elements_text(payload -> 'hourly' -> 'wind_speed_10m') WITH ORDINALITY AS w(value, ord)
    ON w.ord = t.ord;
```

Four things worth knowing before you rely on it:

- **Do not pass `&models=era5`.** ERA5 reanalysis runs 5–8 days behind, so the tail of a
  "last 30 days" request comes back all `NULL`. The default `best_match` stitches ECMWF IFS over the
  recent gap and returns data right up to today.
- **Times have no timezone suffix** (`"2026-08-03T19:15"`) and are UTC unless you pass `&timezone=`.
  Attach UTC explicitly before inserting into a `timestamptz`.
- **Coordinates snap to the model grid** (~9 km for IFS, ~25 km for ERA5), so every turbine in one
  wind farm returns *identical* weather. Fetch per distinct grid cell and add per-turbine variation
  yourself — which is roughly what the built-in model already does.
- **Multiple locations per call** are supported (`&latitude=52.5,48.8`) and change the response to a
  JSON *array*. Note `location_id` is **absent on the first element**, so join on array index, not on
  that field.

Data is **CC BY 4.0** and attribution is mandatory, with placement requirements — a link next to any
displayed data, not just a footer. Paid alternatives with more control, all requiring an API key
(which is exactly why Open-Meteo is the default for a no-signup workshop):
[WeatherAPI.com](https://www.weatherapi.com), [Visual Crossing](https://www.visualcrossing.com),
[Windy API](https://api.windy.com).

> Licensing and attribution terms are a legal question, not a technical one. Before publishing
> material that redistributes third-party weather data or relies on its licence terms, confirm the
> approach with Leah Aviram, General Counsel.


## Tiered storage (optional)

`sql/14_tiered_storage.sql` adds **scattered tiering** — a separate
object-storage threshold per object, each derived from how the dashboards read it:

| Object | Size at defaults | Tiers after | Why that threshold |
| --- | --- | --- | --- |
| `wind_measurements` | 251 MB | 26 weeks | Raw is read only by the turbine view's raw tier, which fires at windows under ~7 days — recent failure forensics. |
| `power_generation` | 187 MB | 26 weeks | Same. |
| `cagg_wind_hourly` | 169 MB | 52 weeks | Turbine wind/temperature from a month to a year. |
| `cagg_turbine_power_hourly` | 140 MB | 52 weeks | Plant "now" metrics, turbine view 30 d–1 y. |
| `cagg_plant_power_hourly` | 21 MB | 52 weeks | Region view timelines. |
| `cagg_regional_power_hourly` | 10 MB | 52 weeks | Global production timeline. |
| `cagg_wind_daily` | 10 MB | 104 weeks | Global view's two-year seasonality panels, read on every page load. |
| `cagg_turbine_power_daily` | 9 MB | 104 weeks | Turbine view at multi-year zoom. |

Note the shape: **the smallest objects keep the longest local residency**, because
they are read across the widest windows. It costs 19 MB to keep both daily
aggregates local for two years, and it moves 438 MB of raw telemetry out first.

It is **off by default**:

```bash
./reset_demo.sh --part 1 --tiering
```

Three things to know before enabling it:

- It needs tiered storage switched on for the service (Console → your service →
  Explorer → Data tiering). Without that, step 14 reports what it *would* do and
  skips — tiering is not a workshop prerequisite.
- **`timescaledb.enable_tiered_reads` defaults to `false`.** With it off, queries
  silently return only the non-tiered chunks: no error, no warning, nothing in the
  plan. Panels just lose their older history. Step 14 sets it at the *database*
  level, because Grafana opens its own connections and would not inherit a session
  setting.
- Removing a policy is one call, but chunks already uploaded come back only one at
  a time via `untier_chunk()`, and a hypertable with tiered chunks restricts schema
  changes — which collides with the `DROP TABLE` in `02_schema.sql`. The reset
  sequence is documented at the end of step 14.


## Scheduling It for Real

The workshop has you run ``advance_simulation.sql`` by hand, which keeps the pace in your control and
means nothing happens off-screen. In production you would schedule it. Two options, in order of
portability:

**`add_job()` — TimescaleDB's own scheduler.** Available on every Tiger Cloud service, no preload, no
ticket. The procedure must take `(job_id INT, config JSONB)`:

```sql
CREATE PROCEDURE job_advance_fleet(job_id INT, config JSONB) LANGUAGE plpgsql AS $$
BEGIN
  PERFORM simulate_active_orders();
  PERFORM simulate_refuels_if_needed();
END $$;

SELECT add_job('job_advance_fleet', '1 minute');

-- Observe:
SELECT job_id, application_name, schedule_interval, next_start
  FROM timescaledb_information.jobs WHERE proc_name LIKE 'job_%';
SELECT proc_name, succeeded, err_message
  FROM timescaledb_information.job_history ORDER BY execution_start DESC LIMIT 20;
```

**`pg_cron`** — listed for Tiger Cloud but requires contacting support to enable, so it cannot be a
workshop prerequisite:

```sql
SELECT cron.schedule('advance-fleet', '* * * * *', $$SELECT simulate_active_orders()$$);
SELECT * FROM cron.job;
SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
```

Note that one call per minute inserts the six 10-second pings that arrived during that minute, in one
statement. That is the right pattern — do not schedule six separate per-10-second invocations.
`pg_cron`'s floor is one minute unless you are on 1.5+ with the `'N seconds'` syntax, and a bulk
insert beats six round trips regardless.


## Troubleshooting

### Dashboards show "No Data" and the filter dropdowns are empty

The single most likely cause, and it is not your connection.

Grafana 10 renamed the Postgres plugin from `postgres` to
`grafana-postgresql-datasource`. Datasource *provisioning* still accepts the old alias and silently
normalises it, so the datasource works — but **dashboard JSON does not**. A template variable
declaring `"type": "postgres"` cannot resolve its plugin, so its query never runs and the dropdown
comes up empty. Every panel filtering on `region_name LIKE '$region'` then gets `LIKE ''`, matches
nothing, and reports "No Data" with no error anywhere to explain it.

Check what your Grafana actually calls the plugin:

```bash
curl -s -u admin:$GF_SECURITY_ADMIN_PASSWORD http://localhost:3000/api/datasources \
  | python3 -c "import json,sys;[print(x['type']) for x in json.load(sys.stdin)]"
```

Every `"datasource"` block in `shared/grafana/*.json` must use that exact string. The shipped
dashboards use `grafana-postgresql-datasource`; if you are pinned to Grafana 9 or earlier, change them
to `postgres`.

Two related details in the same area:

- **Variable queries need the object form** for SQL datasources —
  `{"rawSql": "...", "format": "table", "editorMode": "code"}` — not a bare string.
- **Provisioned dashboards need an explicit `current`.** With `"current": {}` an `includeAll`
  variable can resolve to empty rather than to All, which produces the same `LIKE ''` symptom. The
  shipped dashboards pin `{"text": "All", "value": "$__all"}`.

### Is it the network? Almost certainly not

Docker containers make **outbound** connections by default; `ports:` only controls *inbound* access
to the container. Nothing needs opening for Grafana to reach Tiger Cloud. Prove it in one command:

```bash
docker exec wind-workshop-grafana sh -c 'nc -z -w5 $PGHOST $PGPORT && echo reachable'
```

If that succeeds, the problem is above the network layer.

### Distinguishing the failure modes

| Symptom | Meaning |
| --- | --- |
| Red triangle / error text on the panel | Datasource or SQL problem — read the error |
| "No Data", dropdowns **empty** | Variable queries not running — plugin-id mismatch, above |
| "No Data", dropdowns **populated** | Query genuinely returned zero rows — check the time range and that you ran step 07 (backfill) and step 08 (aggregates) |
| Panels fine, one panel "No Data" | That panel's single-select variable has no value yet — pick one |

### Verifying server-side in one query

```sql
SELECT (SELECT count(*) FROM regions)                     AS regions,
       (SELECT count(*) FROM plants)                      AS plants,
       (SELECT count(*) FROM turbines)                    AS turbines,
       (SELECT count(*) FROM power_generation)            AS power_rows,
       (SELECT count(*) FROM cagg_regional_power_hourly)  AS region_cagg_rows,
       (SELECT max(time) FROM power_generation)           AS newest_reading,
       now()                                             AS server_now;
```

At default config expect 6 / 12 / 96 / ~69,000 / ~4,300, with `newest_reading` within an hour of
`server_now`. If `power_rows` is 0 you have not run step 07. If the aggregates are 0 but raw rows
exist, re-run step 08.

### Editing the root `.env` after Grafana is already running

`env_file: ../.env` is read when the container is **created**, so a later edit has no effect
until you recreate it:

```bash
docker compose --env-file ../.env up -d --force-recreate
```

Confirm the values actually landed:

```bash
docker exec wind-workshop-grafana sh -c 'echo $PGHOST/$PGDATABASE; echo "pw set? ${PGPASSWORD:+yes}"'
```

Also note `env_file` does **no** shell expansion and strips no quotes — `PGHOST="host"` arrives with
the quotes included and the connection fails.

## TODO

### Next-hour power forecasting

Add a step that forecasts each turbine's output one hour ahead, and a dashboard panel that
shows the forecast against what actually happened once the hour closes.

The ingredients are already in place, which is why this is the natural next step rather than a
new workshop: two years of 15-minute wind and power history, `cagg_wind_hourly` carrying
per-turbine mean/min/max wind and the unit-vector direction components, and
`power_from_wind_speed()` to turn a predicted wind speed into a predicted kilowatt figure.

Worth deciding before writing any of it:

- **What the forecast is allowed to know.** `wind_at()` is a deterministic function of
  (turbine, timestamp), so "predicting" it is trivially exact and teaches nothing. The forecast
  has to work from the *stored history* — persistence, a seasonal-plus-diurnal fit, or a
  short-window trend — and be judged against the noisy measured series.
- **Whether it lives in SQL.** Data generation is SQL-only here, and a forecast is derived data,
  so the same rule should apply. A persistence or linear-trend model is comfortable in SQL; the
  moment it wants a regression it is worth checking whether a continuous aggregate over the
  history can carry the coefficients.
- **Where the forecast is stored.** A separate hypertable keyed (turbine_id, target_time,
  issued_at) keeps issue time distinct from target time, which is what makes honest error
  measurement possible. Storing only the latest forecast per target makes it impossible to ask
  "what did we think an hour beforehand?".
- **How error is reported.** MAE and bias per turbine and per region, bucketed by forecast
  horizon, over an aggregate rather than the raw table.

Two things this would exercise that nothing in the workshop currently does: a hypertable whose
rows are *written ahead of* their timestamp, and a query that joins a forecast to the actual on
`(turbine_id, time)` across two different time-indexed tables.

**Take the forecast from real weather data, fetched with a small Python script.** Not from the
`http` extension in the database — see below.

- **It dissolves the first decision above.** A numerical weather prediction is genuinely
  independent of `wind_at()`, so there is no way for the forecast to cheat by inverting the
  generator. That is a stronger position than any history-only model, and the main reason to
  prefer real data here.
- **The horizon and the issue time come for free.** A forecast endpoint returns an hourly series,
  so each fetch naturally yields many `(target_time, issued_at)` pairs — exactly the shape the
  forecast table wants, and something a persistence model has to fake.
- **NO in-database HTTP.** Do not reach for `pgsql-http` or `pg_net`, on Tiger Cloud or anywhere
  else in this repo. Beyond the fact that neither extension is available on Tiger Cloud, giving
  the database engine the ability to make outbound requests is a security posture we are not
  taking: it turns any SQL injection into server-side request forgery, lets the database reach
  internal endpoints and cloud metadata services, puts API credentials in the database where they
  are dumped with it, and moves an unbounded blocking network call inside a transaction. The
  `CREATE EXTENSION http` sketch in *Swapping in Real Weather Data* below is kept as an
  illustration of why the constraint exists, not as a path to follow.
- **Fetch in Python, derive in SQL.** A script — say `forecast/fetch_forecast.py` — reads the
  repo-root `.env`, calls the forecast API once per plant (not per turbine; a plant is a single
  grid point at this resolution), and writes raw forecast **wind** rows keyed
  `(plant_id, target_time, issued_at)`. Everything derived stays in the database: the hub-height
  shear correction and `power_from_wind_speed()` turn forecast wind into forecast kilowatts in
  SQL, exactly as the generator does for measured wind.
- **Correct to hub height.** Public forecasts report wind at 10 m; these turbines have
  `hub_height_m` around 150. Feeding a 10 m forecast straight into `power_from_wind_speed()`
  under-predicts badly and consistently. A log-law or power-law shear correction is needed, and it
  is a good lesson in its own right — the column is already there to use.
- **Make the fetch re-runnable.** Same rule as everything else here: `ON CONFLICT` on
  `(plant_id, target_time, issued_at)` so running the script twice in a workshop adds nothing, and
  a forecast re-issued for the same target is a new row rather than an overwrite.
- **Check the licence before publishing.** Whether a published workshop may ship fetched forecast
  data, or only the code that fetches it, turns on the provider's attribution and redistribution
  terms. Per the repo conventions that is a question for Leah Aviram, General Counsel — not one to
  settle in a pull request.

**Deferred deliberately:** whether a Python fetcher is compatible with this repo's "data
generation lives in SQL" rule. The honest reading is that it bends it — deleting the script would
change what lands in the table, because the values come from outside. The counter-argument is that
the script *transports* rather than *computes*: it invents no value, and every derivation stays in
SQL. Decide that before writing the step, and record the decision in CLAUDE.md either way.

## Resetting the Demo Data

```bash
./reset_demo.sh --yes                 # rebuild at whatever settings are in workshop_config
./reset_demo.sh --yes --plants 1 --turbines-per-plant 1 --days 30    # a small, fast rebuild for iterating
./reset_demo.sh --hard --yes          # also reset this workshop's tunables and drop its roles
./reset_demo.sh --keep-tables --yes   # re-run the SQL without dropping first
./reset_demo.sh --help                # every flag, with measured volumes and timings
```

The volume knobs persist in `workshop_config`, so a later run without them reuses whatever you
last chose. `--hard` is what puts them back to defaults.

## License

MIT License

## Acknowledgments

Created by the TigerData team. Sites, turbine models and spacing conventions are real; operator names
are illustrative. See [DATA-GENERATION.md](DATA-GENERATION.md) for the models behind the numbers and
an honest account of where they stop being physical.
