# Grafana platform learnings

Durable, hard-won facts about **Grafana** as it actually behaves when pointed at a Tiger Cloud
service — panel JSON, provisioning, geomaps, and the SQL those panels have to contain. Read this
before authoring or editing a dashboard; see [TIGER_PLATFORM.md](TIGER_PLATFORM.md) for the
database side and [CLAUDE.md](CLAUDE.md) for repo conventions.

Every entry carries a confidence label:

| Label | Meaning |
|---|---|
| `VERIFIED` | Executed or provisioned against a running Grafana, or read directly in upstream Grafana source, and observed. Version noted. |
| `DOCUMENTED` | Stated by Grafana's docs. Not executed by us. |
| `ASSUMED` | Inferred or version-dependent. Confirm before relying on it. |

Promote entries as they are proven. If you disprove one, correct it in place and say so — a
wrong entry here is worse than no entry.

**Reference environment** for everything marked `VERIFIED` below, unless stated otherwise:
**Grafana 13.1.1** in Docker, provisioned from `shared/grafana-provisioning/`, with panel models
read back from `/api/dashboards/uid/<uid>`; upstream source quoted from `grafana/grafana` `main`.
Dashboard SQL was executed against `timescale/timescaledb-ha:pg17` (PostgreSQL 17.10,
TimescaleDB 2.29.0, PostGIS 3.6.4).

---


## Grafana

### Provisioning files expand `${ENV}` — `DOCUMENTED`

So a datasource can be fully wired from `.env` with no hand-editing:

```yaml
url: ${PGHOST}:${PGPORT}
secureJsonData:
  password: ${PGPASSWORD}
```

This is a strict improvement on committing `<your-password>` placeholders and telling the attendee
to edit the yml.

Two provisioning gotchas worth carrying forward: `url` must be bare
`host:port` (a `postgres://` scheme gives "error parsing postgres url"), and the `database` field
may not take effect until one manual **Save & Test**.

### Do not nest a bind mount inside a named volume — `VERIFIED`

This combination hung `docker compose up -d` indefinitely on Docker Desktop for Mac; the container sat
in `Created` and never started, and `docker start` and `docker logs` both hung too:

```yaml
volumes:
  - ./shared/grafana:/var/lib/grafana/dashboards   # bind, INSIDE the volume below
  - grafana-data:/var/lib/grafana                  # named volume
```

Moving the bind mount out of the named volume's subtree fixed it — container healthy in 15 seconds:

```yaml
volumes:
  - ./shared/grafana-provisioning:/etc/grafana/provisioning:ro
  - ./shared/grafana:/etc/grafana/dashboards:ro    # sibling, not nested
  - grafana-data:/var/lib/grafana
```

Grafana does not care where the dashboard files live — point the provider's `options.path` at whatever
you mount. Keep the two mount trees disjoint.

### Dashboard JSON must use the CURRENT datasource plugin id — `VERIFIED`

Grafana 10 renamed the Postgres plugin `postgres` -> `grafana-postgresql-datasource`. The two places
that reference it behave differently, which makes this fail in a maximally confusing way:

- **Datasource provisioning YAML** accepts the old alias `postgres` and silently normalises it. The
  datasource works, tests green, and panels return data.
- **Dashboard JSON** does not. A template variable declaring `"type": "postgres"` cannot resolve its
  plugin, so the variable query never executes and the dropdown is **empty**.

Panels still run, because they resolve the datasource by `uid` and tolerate a stale `type`. So the
observable result is: dashboard loads, no errors anywhere, dropdowns blank, and every panel that
filters on the variable shows **"No Data"** — because `WHERE x LIKE '$var'` becomes `LIKE ''`.

Verified on Grafana 13.1.1: `/api/datasources` reported
`type = 'grafana-postgresql-datasource'` while the dashboard JSON said `postgres`. After correcting
every `datasource` block, the three variable queries returned 6 / 12 / 96 options.

Check what your Grafana calls it rather than assuming:

```bash
curl -s -u admin:PW http://localhost:3000/api/datasources \
  | python3 -c "import json,sys;[print(x['type']) for x in json.load(sys.stdin)]"
```

Two companions to the same problem:

**Variable queries for SQL datasources want the object form**, not a bare string:

```json
"query": { "rawSql": "SELECT ...", "format": "table", "editorMode": "code", "rawQuery": true }
```

**Provisioned dashboards need an explicit `current`.** With `"current": {}` an `includeAll` variable
can resolve to empty instead of All — the same `LIKE ''` symptom from a different direction. Pin
`{"selected": true, "text": "All", "value": "$__all"}` and set `allValue` to something SQL-safe such
as `%`.

### Docker containers reach outbound by default; `ports:` is inbound only — `VERIFIED`

Worth stating because it is a common wrong turn when a containerised Grafana cannot see a cloud
database. Publishing ports controls traffic *into* the container. Outbound connections work with no
configuration at all — verified from inside the Grafana container against a Tiger Cloud service:
DNS resolved, `nc -z host port` succeeded, and queries returned rows. If a container genuinely
cannot reach a managed database the cause is almost always credentials, `sslmode`, or an IP allow-list
on the service — not Docker networking.

Related: `env_file` is read when the container is **created**, so editing `.env` requires
`docker compose up -d --force-recreate`. It also performs no shell expansion and does not strip
quotes, so `PGHOST="host"` arrives with the quotes attached.

### Geomap cannot render polygons returned by a query — but a static file works — `VERIFIED`

The geomap panel's GeoJSON layer reads a **static file**; there is no query-driven polygon layer. Two
ways to live with that:

**For fixed geometry** (region boundaries, service areas), export it from PostGIS once and mount the
file into Grafana's public directory:

```sql
SELECT jsonb_build_object('type','FeatureCollection','features', jsonb_agg(
         jsonb_build_object('type','Feature',
           'properties', jsonb_build_object('region_name', r.region_name),
           'geometry',   ST_AsGeoJSON(r.boundary)::jsonb)))
  FROM regions r;
```

```yaml
volumes:
  - ./grafana-geojson:/usr/share/grafana/public/maps/workshop:ro
```

then reference `config.src: "public/maps/workshop/regions.geojson"` in a `geojson` layer, listed
BEFORE the markers layer so polygons draw underneath. Verified serving over HTTP and rendering.

**For per-query geometry** (a footprint that changes daily), return the centroid as numeric
`latitude`/`longitude` and encode area as point size, with the WKT in a table panel alongside.

Geomap point layers need numeric `latitude`/`longitude` fields with `format: "table"`.

---

---

## Grafana + Postgres specifics

### Dashboard variables interpolate as bare text, so cast deliberately — `VERIFIED`

`'$tenant_id'` in a panel query becomes `'3f2b…'` — an *unknown-typed literal*, which PostgreSQL
happily coerces to `uuid` in `WHERE tenant_id = '$tenant_id'`. That works. What does **not** work is
testing those queries by substituting a subquery: `tenant_id = (SELECT id::text …)` fails with
`operator does not exist: uuid = text`. When validating dashboard SQL outside Grafana, substitute
literal values, not expressions — otherwise you chase type errors that do not exist in production.

Query-type variables need `__text`/`__value` columns:

```sql
SELECT name AS __text, tenant_id::text AS __value FROM tenants ORDER BY name
```

For an "All" option that works inside SQL, set `allValue` to `%` and compare with `LIKE '$region'`
rather than `= '$region'`.

### Every panel must answer as of the dashboard's time range, including the "current" ones — `VERIFIED`

The bug is easy to write and invisible in review: a point-in-time panel anchored to the DATA
rather than to the selected window.

```sql
-- WRONG: always the newest bucket in the table, whatever range the user picked
WHERE h.bucket = (SELECT MAX(bucket) FROM cagg_readings_hourly)
WHERE h.bucket > (SELECT MAX(bucket) FROM cagg_readings_hourly) - INTERVAL '3 hours'
WHERE day >= now() - INTERVAL '7 days'
WHERE f.resolved_at IS NULL                      -- "open now", not "open then"
```

Every one of those renders fine, returns data, and silently ignores the time picker. Pan back a
month and the stat panels, the geomaps and the fault counts still show this instant. Audited
across six dashboards here: **51 of them**, every stat panel and every geomap, while the
timelines were correct because they used `$__timeFilter`.

**"Current" means the END of the selected range.** `$__timeTo()` is the anchor:

```sql
-- the latest available bucket, but never later than the window's end
(SELECT MAX(bucket) FROM cagg_readings_hourly WHERE bucket <= $__timeTo()::timestamptz)

-- a trailing window trailing from the window's end, not from wall clock
WHERE h.bucket > (SELECT MAX(bucket) FROM cagg_readings_hourly
                   WHERE bucket <= $__timeTo()::timestamptz) - INTERVAL '3 hours'

-- state that was true THEN, from an interval-typed table
WHERE f.started_at <= $__timeTo()::timestamptz
  AND (f.resolved_at IS NULL OR f.resolved_at > $__timeTo()::timestamptz)
```

Four things that matter in the mechanics:

- **`$__timeTo()` expands to a QUOTED RFC3339 STRING with no cast** — `'2020-07-13T20:19:09.254Z'`.
  A comparison against a `timestamptz` column coerces fine, but **any arithmetic needs an
  explicit `::timestamptz`**: `$__timeTo() - INTERVAL '3 hours'` is an unknown-typed literal minus
  an interval. Always write `$__timeTo()::timestamptz`.
- **Prefer `<= $__timeTo()` over `$__timeFilter()` for "last known value".** A short window in
  which the entity did not report would return nothing under `$__timeFilter`, blanking the panel;
  `<= $__timeTo()` gives the last known state without ever showing data from after the window.
  Use `$__timeFilter` for anything that is genuinely a range (a trail, a leaderboard, a total).
- **A function that hardcodes `now()` internally cannot be made range-aware from the panel.**
  Give it an as-of parameter: `tenant_state(uuid, TIMESTAMPTZ DEFAULT now())`. Then check the
  answer actually changes — ours went 0.454 to 0.778 for a 2-day-earlier as-of, which is the proof
  the parameter is threaded all the way through rather than accepted and ignored.
- **Adding a defaulted parameter creates an OVERLOAD, it does not replace.** `CREATE OR REPLACE`
  with an extra argument leaves the old signature in place, and every one-argument call then fails
  with `function tenant_state(uuid) is not unique`. Drop **both** signatures in the file's
  reset block.

Finally, **retitle anything whose title hardcodes a window** once it follows the picker. "Miles —
last 7d" is a lie the moment the query respects the range; it becomes "Miles". Same for panels
titled "— now", which become "— as of window end".

Mimic the macros exactly when validating outside Grafana. Substituting `now()` for `$__timeTo()`
hides precisely the cast bug above, because `now() - INTERVAL '3 hours'` is valid where the real
expansion is not.

### Validate a dashboard by *executing* every `rawSql`, not by reading the JSON — `VERIFIED`

Two ways this check quietly under-tests, both learned the hard way:

**Do not wrap the query in `COUNT(*)`.** `WITH q AS (<panel sql>) SELECT COUNT(*) FROM q`
lets the planner prune expressions the count does not reference — so a scalar subquery
that raises `more than one row returned by a subquery used as an expression` is never
evaluated and the harness reports a cheerful row count. The same query, selecting its
actual columns, errors immediately. Execute the query **as written**.

**Render each query three ways, not one.** A dashboard variable can hold a real value,
the All wildcard, or — on a provisioned dashboard whose variable options have not resolved
yet — **empty**. Zero rows is an acceptable outcome; an ERROR is not. Derive the wildcard
per dashboard from each variable's own `includeAll`/`allValue`, or the harness invents
failures by feeding `%` to a single-select uuid variable.

A hand-authored dashboard can be structurally perfect JSON, load without complaint, and still be
broken. Observed here: ten panels across three dashboards had their `description` and
`targets[].rawSql` values **swapped**, so Grafana was sending English prose to the server. Grafana
reports this as a per-panel SQL error at render time and nothing earlier — not at provisioning, not
in the logs, not in any JSON schema check.

The cheap check that catches it: parse each dashboard, pull every `templating[].query.rawSql` and
every `panels[].targets[].rawSql`, and assert each one begins with `SELECT` or `WITH`. Then actually
run them. Two substitution traps when doing so:

- Substitute a **consistent** set of variable values. A region drawn independently of a site yields
  a `region = X AND site = Y` pair that matches nothing, and the 0 rows looks like a query bug.
- Region names contain spaces (`Iberian Meseta`), so `read -r A B C <<< "$(psql -tA -F' ' …)"`
  silently splits one field into two. Use an explicit non-space delimiter and `IFS`.

Zero rows is not automatically a defect: with 18 faults over 12 sites, 4 sites legitimately have an
empty fault-history table. Confirm against the data before "fixing" the SQL.

### The zoom-selected timeline: one query, three tiers, two branches pruned — `VERIFIED`

**Use this shape for every dashboard timeline panel.** It is the standard form in this
repo, and write every timeline panel this way.

A timeline panel has to serve a six-hour window and a five-year window from the same
query. Reading raw always is correct but the cost grows with the window; reading the
coarsest rollup always is cheap but throws away the detail that makes zooming in
worth doing. So let the query pick its own source from how far the user has zoomed.

#### The general form

```sql
    SELECT <entities>, <time bucket>, <aggregations>
      FROM <coarsest tier>
     WHERE <grafana time filter on THIS tier's time column>
       AND <interval_ms gate for the grain this tier serves>
       AND <entity filters from dashboard variables>
     GROUP BY <entities>, <time bucket>
    UNION ALL
     -- the same shape at the next finer grain, gated to its own interval_ms band
    UNION ALL
     -- the finest tier reads the raw hypertable
     ORDER BY time
```

Concretely, for a region-grain production timeline:

```sql
  -- One point per day or coarser: the daily rollup already has it.
  SELECT region_name AS metric,
         day         AS time,
         ROUND((AVG(region_power_kw)/1000.0)::numeric, 2) AS value
    FROM cagg_region_daily
   WHERE $__timeFilter(day)
       AND region_name LIKE '$region'
       AND $__interval_ms >= 86400000
   GROUP BY region_name, day
  UNION ALL
  -- One point per hour or coarser: the hourly rollup is fine enough.
  SELECT region_name, bucket,
         ROUND((AVG(region_power_kw)/1000.0)::numeric, 2)
    FROM cagg_region_hourly
   WHERE $__timeFilter(bucket)
       AND region_name LIKE '$region'
       AND $__interval_ms >= 3600000
       AND $__interval_ms <  86400000
   GROUP BY region_name, bucket
  UNION ALL
  -- Finer than an hour: only the raw samples carry more detail.
  SELECT region_name, time_bucket('15 minutes', time),
         ROUND((SUM(power_kw)/1000.0)::numeric, 2)
    FROM derived_metrics
   WHERE $__timeFilter(time)
       AND region_name LIKE '$region'
       AND $__interval_ms <  3600000
   GROUP BY region_name, time_bucket('15 minutes', time)
 ORDER BY time;
```

Standard gates, matching the tiers' own bucket widths so the rule is self-evident
rather than tuned:

| Gate | Tier |
| --- | --- |
| `$__interval_ms >= 86400000` | daily rollup |
| `$__interval_ms >= 3600000 AND < 86400000` | hourly rollup |
| `$__interval_ms < 3600000` | raw hypertable |

`$__interval_ms` is a Grafana **global built-in variable**: the width of one plotted
point in milliseconds, derived from the time range, growing as you zoom out.
Documented at
`grafana.com/docs/grafana/latest/visualizations/dashboards/variables/global-variables/`.

#### Why the untaken branches cost nothing

The gates are constants by the time the planner sees them, so PostgreSQL folds them,
proves two branches empty, and **removes them from the plan entirely** — not a scan
with a false filter. Verified per tier on the query above:

```
  interval -> raw     reads: derived_metrics
  interval -> hourly  reads: cagg_region_hourly, derived_metrics
  interval -> daily   reads: cagg_region_daily
```

The raw hypertable also appearing at the hourly tier is correct, not a leak: the
aggregates are `materialized_only = false`, so each is a union of materialised
buckets plus a live aggregate over rows too recent to be materialised.

#### Seven things that bite

1. **Filter each branch on ITS OWN time column** — `day`, `bucket`, `time`. That is
   what lets TimescaleDB do chunk exclusion inside each branch. A single outer
   `WHERE` on the union's output column cannot.
2. **Pin `maxDataPoints`** on every panel using this. Left unset, `interval_ms`
   derives from the panel's PIXEL WIDTH, so a narrow panel and a wide one pick
   different tiers at the same zoom — and a full-width panel at 30 days lands on raw,
   drawing 2,880 points into 1,100 pixels.

   Note carefully what it does and does not affect. The gates are fixed at the tiers'
   own bucket widths (3,600,000 and 86,400,000 ms) and never change. maxDataPoints
   only feeds the arithmetic producing the value being compared:

   ```
   interval_ms = time_range_ms / maxDataPoints
   ```

   so it decides at what WINDOW SIZE each fixed threshold is crossed. This repo uses
   **100**, which reaches the hourly tier at a ~4.2-day window and the daily tier at
   100 days. At 400 the same thresholds needed 16.7 days and 400 days. Fewer
   requested points means coarser buckets for a given window, hence a cheaper tier
   sooner — the rule is untouched, only its input.
3. **You need a tier at every ENTITY grain, not just every time grain.** A region
   timeline wants a region-grain daily rollup; without one it falls back to hourly at
   every zoom. Adding `cagg_site_daily` and `cagg_region_daily` cost
   ~13,000 rows between them and removed 17,520-row-per-region scans.
4. **Ratios must be ratios of sums at every tier.** `100.0 * SUM(actual) /
   SUM(expected)` survives rollup; an average of per-bucket ratios does not.
5. **Averages need reading-count weighting** when a coarser tier aggregates a finer
   one — `SUM(x * readings) / SUM(readings)`. Unweighted, a partial bucket counts as
   much as a full one, and the partial buckets sit at both ends of every window.
6. **Rolling up entities inside the query is fine**; rolling them up inside a cagg is
   not. The weather aggregates are device-grain, so the region timelines aggregate
   to region in the panel query, joining `sites` there. A continuous aggregate that
   joined `sites` would never invalidate when a site was edited.
7. **Multiple metrics multiply the branches.** An expected-vs-actual panel is
   3 tiers × 2 metrics = 6 branches. The gates still leave exactly two alive.

#### When it does not apply

Only when a single grain exists. A panel plotting one point per discrete event
event, not per time bucket, and its cost views are daily-only — there is nothing to
select between, and forcing the shape would add branches that can never fire. Add the
tiers first, or leave the query flat and say why.

### Geomap "fit to data" defaults to ALL layers, so one static overlay pins you to the world — `VERIFIED`

Symptom: every geomap shows the whole world and snaps back to the world the instant a
template variable changes, however narrow the filtered data is.

Cause is a default. From Grafana's own `panelcfg.gen.ts`:

```typescript
export const defaultMapViewConfig: Partial<MapViewConfig> = {
  allLayers: true,          // <-- this
  id: 'zero', lat: 0, lon: 0, noRepeat: false, zoom: 1,
};
```

So `"view": {"id": "fit", "padding": 20}` means *fit to the union of every layer*. Add a
static GeoJSON overlay — region outlines, country borders, anything covering more than
the filtered data — and the union is permanently as wide as that file. Measured on this
a continent-spanning GeoJSON overlay measured **211 degrees of longitude**, against a filtered
site marker extent of 0 to a few degrees. "Fit" was working correctly and fitting to
the overlay.

The fix is to name the layer to fit:

```json
"view": { "id": "fit", "allLayers": false, "layer": "Sites",
          "padding": 18, "maxZoom": 9, "noRepeat": true }
```

`layer` takes the layer's **name** string as it appears in `options.layers[].name`. Get
it wrong and there is no error — fit silently falls back, and you are back to a world
view wondering why. Assert it when generating dashboards:

```python
names = [l.get('name') for l in panel['options']['layers']]
assert view['layer'] in names, f"view.layer={view['layer']!r} not in {names}"
```

Four more things worth knowing:

- **An empty extent silently skips the fit altogether.** `initViewExtent` guards with
  `if (!isEmpty(extent))` using `isEmpty` from **`ol/extent`**, and OpenLayers represents
  an empty extent as `[Infinity, Infinity, -Infinity, -Infinity]` — which is also exactly
  what `createEmpty()` returns and what `getSource().getExtent()` returns for a source
  with no features. So when the queries return **zero rows**, the fit does not run at all
  and the map sits at whatever the `View` was constructed with: centre 0,0 zoom 1, i.e.
  the world. It looks identical to "fit is broken". Before blaming the view config,
  confirm the panel actually got rows — a dashboard variable that has not resolved yet
  interpolates as empty, and `WHERE x LIKE ''` matches nothing.
  (One thing this is NOT: a single empty layer among several does not poison a
  multi-layer union. OL's `extend` treats the infinite extent as the identity, so
  `extend(real, empty)` is `real`.)
- **`maxZoom` is not optional in practice.** A filtered marker layer often reduces to a
  SINGLE point — one site in a region, one device in a site — and a zero-extent fit
  zooms to maximum, landing on a blank tile. Measured extents here: a one-site region
  is 0.00 degrees, a whole site is 0.01–0.02 degrees (~1–2 km). Cap it: 9 for
  region scale, 15 for site scale. It only binds in the degenerate case.
- **A `zoom` key on a `fit` panel silently overrides `maxZoom`.** `initViewExtent` reads
  `const maxZoom = config.zoom ?? config.maxZoom;` — `zoom` wins. So a panel edited from
  a fixed view to `fit` that still carries its old `zoom: 1.4` caps the fit at zoom 1.4,
  i.e. locks it to the world, and `maxZoom: 9` sitting right beside it does nothing. When
  writing `fit`, emit `maxZoom` and **no `zoom` key at all**. Assert it:
  ```python
  if view['id'] == 'fit': assert 'zoom' not in view, 'zoom overrides maxZoom on a fit view'
  ```
- **For a fixed view the id must be `coords`, NOT `zero`** — `zero` discards your
  lat/lon. Both are valid ids, but `initViewExtent` gates on the CENTRE REGISTRY entry,
  not on the panel config:
  ```typescript
  if (v.lat == null) {
    if (v.id === MapCenterID.Coordinates) { coord = [config.lon ?? 0, config.lat ?? 0]; }
    else if (v.id === MapCenterID.Fit)    { /* extent fitting */ }
  } else { coord = [v.lon ?? 0, v.lat ?? 0]; }   // <-- registry values, not yours
  ```
  The `zero` registry entry is `{id: 'zero', name: '(0°, 0°)', lat: 0, lon: 0}`. `lat` is
  `0`, so `v.lat == null` is **false** and control falls to the final `else`, which takes
  the centre from the registry — a panel saved as
  `{"id": "zero", "lat": 25, "lon": 10}` centres on 0°N 0°E, in the Gulf of Guinea, and
  reports nothing. Only the `coords` entry (`{id: 'coords', name: 'Coordinates'}`, no
  lat/lon) leaves `v.lat` undefined, which is what lets the `Coordinates` branch read
  your `config.lat` / `config.lon`. Enum values are `Zero = 'zero'`,
  `Coordinates = 'coords'`, `Fit = 'fit'`. `config.zoom` IS honoured here, because the
  `zoom`-as-fit-cap line above only applies when the id is `fit`.
  Named regions (`north-america`, `europe`, …) also exist and are the same shape as
  `zero` — they carry their own lat/lon and ignore yours. There is no `world` id, so a
  fixed world view is `coords` with a low zoom.
- **`noRepeat: true`** stops the basemap tiling horizontally at low zoom, which
  otherwise renders three copies of the world side by side.
- Fit does recalculate on data change — the docs say it "updates when data changes" —
  so a correct fit really does follow a template variable. If yours does not, it is the
  layer selection, not the refresh.
- **Do NOT reach for `allLayers: true`, even when a derived overlay needs framing.**
  This entry previously advised the opposite and it was wrong — the advice broke a working
  panel. [grafana/grafana#89777](https://github.com/grafana/grafana/issues/89777) reports
  that a geomap with a basemap **and at least one additional layer** (a route layer, for
  instance) using fit-to-data "stays zoomed out to the baselayer instead of zooming to fit
  data". Observed exactly that on **13.1.1** with basemap + markers + two route layers:
  `allLayers: false, layer: "Devices"` fits; flipping the same panel to
  `allLayers: true` does not. The issue is closed against an earlier release, so treat the
  all-layers path as unreliable regardless of version and do not build on it.

  The consequence is a design constraint, not a config choice: **pin the fit to one
  always-populated layer, then make every overlay live inside that layer's extent.**
  Overlays parked outside it cannot be rescued with padding — sweeping an arrow through
  all 36 bearings from an anchor offset beyond the array left 9–11 of 38 sample points
  outside the viewport at *every* padding from 20 to 60, because padding scales an
  elongated bounding box proportionally rather than adding a uniform margin. Re-anchoring
  the same overlay *inside* the array footprint gave 38/38 containment at padding 25.
  Verify containment numerically against the pinned layer's bounding box; do not eyeball
  it at one direction.

Verified against Grafana **13.1.1** by provisioning the dashboards and reading the
stored panel model back from `/api/dashboards/uid/<uid>`.

### Geomap "fit to data" does not apply on initial load — `VERIFIED` symptom, `ASSUMED` cause

A geomap whose `view` is `{id: 'fit', allLayers: false, layer: '<markers layer>'}` can load at the
default world view and never fit. Manually selecting "Fit to data" in the panel editor and saving
fixes it — **without changing the `view` block in the JSON at all**. That last detail is the
diagnosis: if the configuration were wrong, editing it would change the JSON. A no-op edit that
changes behaviour can only be runtime state.

Reproduced on **13.1.1 and 13.1.3**, with a basemap + a markers `LayerGroup` + two `route` layers,
provisioned from a file.

The configuration is provably not at fault:

- `id: 'fit'` is the correct value (`MapCenterID.Fit = 'fit'`).
- `getLayersExtent()`'s `VectorLayer`/`VectorImage` branch does check `layer === layerName`, and a
  markers layer is a `LayerGroup` (holding `WebGLPointsLayer` and/or `VectorImage`), which routes to
  `getLayerGroupExtent()` — so it is not silently filtered out on current versions.

**History — this began as a regression in 11.1.** [#89777](https://github.com/grafana/grafana/issues/89777)
is "Fit to data not working following recent update", working in 11.0. The documented cause: a
performance change moved geomap layers from `VectorLayer` to `VectorImage`, and the extent
calculation still filtered for the old classes. It has been fixed **piecemeal per layer type** —
[#89248](https://github.com/grafana/grafana/pull/89248) for the 11.1 heatmap case (reported
incomplete in [#91693](https://github.com/grafana/grafana/issues/91693)), and
[#101391](https://github.com/grafana/grafana/pull/101391) for route layers, milestone 11.6.x,
`no-changelog` and `no-backport`. So there is **no release that can be described as clean for an
arbitrary layer mix**, and reverting is not viable: 11.0 predates the route-layer handling that
directional overlays depend on.

What remains is most likely an initial-load ordering problem rather than the original class-filter
bug. [#76599](https://github.com/grafana/grafana/issues/76599) describes the geomap "initially
zooming out to show the entire world before transformations are applied, and only then zooming into
the fit data". Two community threads report the same shape with no resolution
([one](https://community.grafana.com/t/geomap-initial-view-set-to-fit-data-layers-but-wont-automatically-zoom/66607),
[two](https://community.grafana.com/t/geomap-panel-automatic-zoom/75840)).

Cause labelled `ASSUMED` deliberately. Two candidate mechanisms fit the symptom and neither is
proven, because both require browser instrumentation:

- `componentDidUpdate` gates the recovery path on `if (this.map && this.props.data !== prevProps.data)`,
  with no catch-up if the data transition happened before the map existed.
- `initViewExtent` sizes the fit with `view.getResolutionForExtent(extent, this.map?.getSize())`;
  a map div with no laid-out size yet would produce a meaningless resolution.

Working through both orderings on paper, each one *succeeds* — so source reading alone does not
settle it. Do not quote a mechanism here as fact.

A no-op `organize` transformation is under test as a workaround, on the theory that the second data
delivery it induces re-triggers the fit. If it works, it needs a comment naming the issue, because
an unexplained transformation costs a reader more than the cosmetic bug does.

### Directional overlays on a geomap: a rotated marker, or a route — `VERIFIED`

There are two ways to draw a direction vector on a geomap — a heading, a flow, a wind, any
bearing — and
they fail differently. A **rotated marker** encodes the bearing as an angle and the speed
as marker size; a **route layer** encodes the bearing as actual geometry and the speed as
the line's LENGTH. The route is more honest — it is a real geodesic on the map — but it is
capped at **one entity per layer**, which decides the choice for you:

| | Rotated marker | Route |
|---|---|---|
| Entities per layer | **all rows of the frame** | **one** (first frame only, joined into one line) |
| Needs a custom SVG glyph | **yes** — silently renders a square if it 404s | no asset at all |
| Bearing shown as | rotation of a glyph | actual geometry |
| Speed shown as | marker size (pixels) | line length (metres) |
| Length is meaningful on the map | no | yes |
| Scales to an unbounded entity count | yes | no |

**The markers route is tempting and it is a trap in practice.** A rotated marker needs a
custom SVG glyph, because Grafana ships no arrow symbol — and if that glyph fails to
resolve, the layer silently falls back to a plain square. Nothing errors; you get a grid
of squares sitting on your markers and no clue why. That is exactly what happened here,
and it is the strongest argument for the route: **a route has no asset dependency at
all**, so it cannot fail this way. It also gets you a length that means something in
metres rather than pixels.

So in practice: **prefer routes, and keep the entity count per panel small** — ideally one.
Two route arrows on a site-scale panel (an axis and a vector over it) and one per site on a
region-scale panel are comfortable; a layer per row of an unbounded query is not. Reach for markers only
when the entity count is genuinely unbounded AND you have verified the glyph resolves.

**The one-layer-per-entity tax is a design signal, not just a cost.** Per-device route
arrows meant one layer and one query per device, and a fixed ceiling that had to be
declared in the panel. Collapsing to a single site-level arrow removed the ceiling
outright and made the picture say something sharper — the angle between the array's axis
and the measured direction — because two arrows sharing a vertex read as a comparison in a way twelve
parallel arrows do not. When a layer budget starts forcing caps and coverage caveats, that
is worth reading as a hint that the visual is carrying more entities than it needs.

Two corollaries:

- **If you do fan out, make the ceiling visible.** A layer cap must never read as "there
  was no data". Where a panel ships a fixed 16 per-device layers against a
  `devices_per_site` that goes to 100, the entity query carried a field that said so —
  `overlay_drawn = 'NO — site has >16 devices; add more layers'` — surfacing
  in the tooltip. Prefer removing the cap by drawing fewer entities.
- **Marker glyphs are sized in pixels, not metres**, so per-entity arrows of either kind
  collapse into a pile once entities are closer together than the glyph is wide. A device
  array is 1–2 km across; on a region view spanning hundreds of km, per-device arrows are
  a blob. Per-entity arrows are a *site-zoom* device — that is why the region view stays
  one arrow per site.

#### As a rotated marker

Three things that are each easy to get wrong silently.

**1. Rotation is a bindable dimension.** From `geomap/style/types.ts`, `StyleConfig`
carries `rotation?: ScalarDimensionConfig`, so it takes a field:

```json
"rotation": { "field": "bearing_deg", "fixed": 0,
              "mode": "mod", "min": -360, "max": 360 }
```

`mode: "mod"` matters — `ScalarDimensionMode` is `'clamped' | 'mod'`, and clamped
would pin every bearing above `max` to `max` instead of wrapping it.

**2. A second layer needs a second query, bound by `filterData`.** `MapLayerOptions`
has `filterData?: unknown`, documented as "a frame MatcherConfig that may filter data
for the given layer". Add a target with `refId: 'B'` and pin each layer:

```json
{ "name": "Sites",      "filterData": { "id": "byRefId", "options": "A" } }
{ "name": "Vector",  "filterData": { "id": "byRefId", "options": "B" } }
```

Pin the EXISTING layer to `A` at the same time. Add a second frame and leave the first
layer unfiltered and it will try to render both frames.

**3. Grafana ships no arrow symbol.** `public/img/icons/marker/` contains exactly
`circle, cross, plane, square, star, triangle, x-mark`. A custom glyph must be mounted
inside Grafana's public directory, the same constraint as GeoJSON overlays:

```yaml
- ./grafana-icons:/usr/share/grafana/public/img/icons/workshop:ro
```

and referenced as `img/icons/workshop/arrow.svg`. **Verify the path resolves**,
because a wrong one renders nothing and reports nothing:

```
curl -s -o /dev/null -w '%{http_code}' \
  http://localhost:3000/public/img/icons/workshop/arrow.svg     # want 200
```

Draw the glyph pointing **north (straight up) at rotation 0** and set
`symbolAlign: {horizontal: center, vertical: center}` so it pivots about its middle
rather than swinging around its tail. Rotation is clockwise degrees, so with a
north-pointing glyph `rotation = compass bearing` puts the head on that bearing.

#### As a route — and the one-frame limit that shapes the whole design

A `route` layer joins the points of a frame into a line and can put an arrowhead on the
end, so three points — tail upwind, entity centre, head downwind — draw a vector whose
length is a real distance:

```sql
CROSS JOIN LATERAL (VALUES (1), (2), (3)) s(seq)
CROSS JOIN LATERAL (
  SELECT CASE s.seq
           WHEN 1 THEN ST_Project(v.center_location, v.magnitude * 2000.0, RADIANS(v.bearing_from_deg))
           WHEN 2 THEN v.center_location
           ELSE        ST_Project(v.center_location, v.magnitude * 2000.0, RADIANS(v.bearing_deg))
         END AS pt
) g
 ORDER BY s.seq;      -- the layer consumes row order as vertex order; without this it is undefined
```

```json
{ "type": "route", "name": "Vector",
  "filterData": { "id": "byRefId", "options": "B" },
  "config": { "style": { "color": {"fixed": "super-light-blue"}, "lineWidth": 4 },
              "arrow": 1 } }
```

`arrow` is a **sibling of `style`, not a style property** — `RouteConfig` is
`{ style: StyleConfig; arrow?: 0 | 1 | -1 }`. Nest it inside `style` and it is ignored,
falling back to the default `arrow: 0`, which draws a plain line with no head: the panel
renders, so nothing tells you the direction cue is missing. `1` is forward, `-1` reverses,
`0` is none.

**One arrowhead is drawn PER SEGMENT, not one per line.** `routeLayer.tsx` loops
`for (let i = 0; i < coordinates.length - 1; i++)`, building a separate `FlowLine` per
segment and calling `setArrow(config.arrow)` on each. So an N-point route gets N−1
arrowheads: the obvious three-point vector (tail, centre, head) grows a **second
arrowhead halfway down its own shaft**, which reads as two short arrows rather than one.
Use **two points** for a single clean head, and put the entity at the midpoint if you want
the arrow centred on it:

```sql
CROSS JOIN LATERAL (VALUES (1), (2)) s(seq)      -- 2 points => 1 arrowhead
... WHEN 1 THEN ST_Project(loc, len/2.0, RADIANS(from_deg))   -- tail, upwind
    ELSE        ST_Project(loc, len/2.0, RADIANS(toward_deg))  -- head, downwind

**The limit: a route layer renders only the FIRST frame.** From `routeLayer.tsx`:

```typescript
for (const frame of data.series) {
  ...
  break; // Only the first frame for now!
}
```

This kills the two obvious ways to draw one arrow per entity:

- **`GROUP BY site_id` does not work.** It is still one frame, so every point from every
  site is strung into a single zig-zagging polyline that wanders between sites.
- **Partitioning into one frame per entity does not work either** — frames 2..N are
  dropped on the floor, so you get the first site's arrow and silently nothing else.

The workaround is one layer per entity, which is only viable when the count is small and
bounded. Here a region holds at most six sites (36 sites / 6 regions), so: six route
layers on refIds `B`–`G`, each query returning exactly one site —

```sql
ORDER BY s.site_name OFFSET 3 LIMIT 1     -- layer "Vector 4"
```

Layers past the actual site count return zero rows and draw nothing, so the panel
degrades quietly on a small data set rather than erroring. Verified at 3 sites: refIds
`B`/`C`/`D` each returned 3 points for one distinct site, `E`/`F`/`G` returned 0 rows.

Two things to check when generating this, because neither reports an error:

- **Scale the length to the panel's zoom.** The length is the speed, so the constant is
  per-panel, not global. Measured here: at regional zoom 2000 m per m/s gives 9.5–70 km
  arrows across a 2–18 unit magnitude range; at site zoom that same constant draws a 70 km arrow
  across a 2 km site. Site-scale panels use 40 m per m/s → 191–1408 m against a 2108 m extent.
- **Assert the geometry, don't eyeball it.** `ST_Azimuth(tail, head)` must equal
  `bearing_deg`, and the three points must be collinear:
  `ST_Distance(p1,p2) + ST_Distance(p2,p3) - ST_Distance(p1,p3)` measured 0.000 m.

Because the fit-to-data extent can include these layers, keep `allLayers: false` with the
marker layer named — a 70 km arrow otherwise widens the extent and zooms the map out.

#### An AXIS is not a heading: pick the sense, or overlays double back

If one of your two vectors is a **bidirectional axis** — a runway, a street grid, a
device array's rows, any "orientation" — do not draw it at its stored bearing and hope.
Rows spaced along 290° are equally spaced along 110°, so a stored `axis_bearing_deg` of
290 and a measured direction of 96 puts the two arrows **194° apart and overlapping**: the
second arrow doubles back over the first and the angle between them is unreadable. This is
not a rendering bug; both arrows are correct. The comparison is what breaks.

Draw the axis in whichever of its two senses faces the other vector:

```sql
CASE
  WHEN bearing_deg IS NULL THEN axis_bearing_deg           -- nothing to face
  WHEN LEAST(ABS(bearing_deg - axis_bearing_deg),
             360.0 - ABS(bearing_deg - axis_bearing_deg)) <= 90.0
    THEN axis_bearing_deg
  ELSE MOD((axis_bearing_deg + 180.0)::numeric, 360.0)::float8
END AS axis_drawn_deg
```

Then the on-screen angle is bounded by 90° and equals the true misalignment, so the
picture cannot mislead. Verify it exhaustively rather than on today's data, which will
sample a narrow band of bearings — a `generate_series` cross join covers every case in one
query:

```sql
WITH g AS (SELECT generate_series(0,355,5)::float8 gb),
     v AS (SELECT generate_series(0,355,5)::float8 wt)
-- assert: on-screen angle <= 90, equals axis misalignment, and axis_drawn is always
-- one of (gb, gb+180) -- never an invented bearing.  5184 combinations, 0 failures.
```

Expose BOTH bearings in the tooltip — the canonical one and the one drawn
(`axis_bearing_deg` and `axis_drawn_deg`). Otherwise the arrow appears to flip for no
reason and the reader has no way to tell a deliberate choice from a bug.

Two related placement notes:

- **Give the two arrows one shared vertex.** Springing the second from a short way past
  the first's tip (14% of the axis length here) keeps the shafts from overlapping while
  holding the vertex in one place, which is what makes the angle legible.
- **Let the axis draw when the other vector is missing.** `LEFT JOIN` the measurement and
  fall back to the stored bearing, but gate the *second* arrow on `IS NOT NULL` so it
  vanishes entirely rather than rendering a zero-length stub. Verified: with no direction rows
  the axis still returns its 2 points and the vector returns 0.

#### The domain trap, which is worse than either of the above

A direction column may be stored in the **FROM** convention rather than the TOWARD one —
meteorological wind direction is the classic case. An
arrow showing flow must point the other way:

```sql
MOD((DEGREES(ATAN2(SUM(dir_sin_sum), SUM(dir_cos_sum))) + 540.0)::numeric, 360.0)  -- toward
MOD((DEGREES(ATAN2(SUM(dir_sin_sum), SUM(dir_cos_sum))) + 360.0)::numeric, 360.0)  -- from
```

`+540` rather than `+180` folds the 180-degree flip and the ATAN2 wrap into one
expression. Expose both in the tooltip: a reader cannot tell which convention an
arrow follows by looking at it, and a vector drawn 180 degrees out is completely
plausible.

Aggregating a bearing across entities needs the circular mean, so this only works if
the aggregate stores unit-vector component SUMS rather than an angle — see
[TIGER_PLATFORM.md](TIGER_PLATFORM.md) “Aggregate a bearing by storing unit-vector
component SUMS”. Carry the mean resultant length too, and suppress the arrow when it
collapses:

```sql
HAVING SQRT(SUM(dir_sin_sum)^2 + SUM(dir_cos_sum)^2) >= 0.01 * SUM(readings)
```

Otherwise an entity whose direction boxed the compass gets a confident arrow pointing at
whatever `ATAN2(0, 0)` returns, which is 0 — due north.

Verified on Grafana **13.1.1**: icon served 200 and byte-identical, and `filterData`,
`rotation` and the custom `symbol` path all survived provisioning intact when read
back from `/api/dashboards/uid/<uid>`. The route form was verified by executing all six
region-view vector queries plus the site and device ones, checking point count, site
distinctness, `ST_Azimuth` against `bearing_deg`, and collinearity.

### The grid is exactly 24 columns; overlapping `gridPos` silently reflows — `VERIFIED`

Same failure mode, visual instead of SQL. A row of five stat panels was written at
`x = 0, 5, 10, 15, 20` — stride 5 — but each carried `w: 6`, left over from the four-panel rows on
the sibling dashboards where `24 / 4 = 6` is right. That sums to 28 columns in a 24-column grid, so
every panel overlapped its neighbour by one column and Grafana silently rearranged the row. The JSON
is valid and the dashboard loads; it just does not look like what you wrote.

Check it by painting the occupancy grid: for every panel mark cells `x … x+w-1` by `y … y+h-1`, then
assert no cell is claimed twice, no panel reaches past `x+w > 24`, and no row is partially filled
(a partial row usually means an unintended gap). For N panels sharing a row, widths must sum to
exactly 24 — for 5 that is `5,5,5,5,4`, not `6,6,6,6,4`.

---
