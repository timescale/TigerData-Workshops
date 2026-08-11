# TigerData platform learnings

Durable, hard-won facts about TimescaleDB, Tiger Cloud, and PostGIS as they actually behave —
kept here so we stop rediscovering them. Read this before writing workshop SQL; see
[GRAFANA_PLATFORM.md](GRAFANA_PLATFORM.md) for anything Grafana-side and
[CLAUDE.md](CLAUDE.md) for repo conventions.

Every entry carries a confidence label:

| Label | Meaning |
|---|---|
| `VERIFIED` | Executed against a live Tiger Cloud service or local instance and observed. Date and version noted. |
| `DOCUMENTED` | Stated by Tiger/PostGIS/PostgreSQL docs or read directly in upstream source. Not executed by us. |
| `ASSUMED` | Inferred or version-dependent. Confirm before relying on it. |

Promote entries as they are proven. If you disprove one, correct it in place and say so — a
wrong entry here is worse than no entry.

**Reference environment** for everything marked `VERIFIED` below, unless stated otherwise: measured
2026-08-03/04 against `timescale/timescaledb-ha:pg17` — **PostgreSQL 17.10, TimescaleDB 2.29.0,
PostGIS 3.6.4**. Confirm against a live Tiger Cloud service before treating cloud behaviour as
identical.

---

## Continuous aggregates

### Row-level security is unusable on a modern hypertable — TWO barriers — `VERIFIED`

Measured 2026-08-03 on `timescale/timescaledb-ha:pg17` — TimescaleDB **2.29.0**, PostgreSQL 17.10,
PostGIS 3.6. Most write-ups mention only the second barrier; the first one is what you actually hit.

**Barrier 1 — RLS is incompatible with the columnstore, which is ON BY DEFAULT.**

```
ALTER TABLE positions ENABLE ROW LEVEL SECURITY;
ERROR:  operation not supported on hypertables that have columnstore enabled
```

A hypertable created with nothing but `WITH (tsdb.hypertable, tsdb.partition_column = 'time')`
already reports `compression_enabled = t`, so this fires on essentially every hypertable. Statement
order does not help: creating the continuous aggregates first and enabling RLS afterwards fails
identically. The only way through is to surrender columnar storage:

```sql
ALTER TABLE t SET (tsdb.enable_columnstore = false);
ALTER TABLE t ENABLE ROW LEVEL SECURITY;   -- now succeeds
```

**Barrier 2 — RLS is incompatible with continuous aggregates.** Having given up the columnstore:

```
CREATE MATERIALIZED VIEW c WITH (timescaledb.continuous) AS SELECT ... FROM t ...;
ERROR:  cannot create continuous aggregate on hypertable with row security
```

This is a catalog check on `pg_class.relrowsecurity || relforcerowsecurity`
(`tsl/src/continuous_aggs/common.c` → `ts_has_row_security()`), so it fires with **zero policies
defined** and **even for superusers**, who would otherwise bypass RLS entirely. A separate guard
rejects RLS on a *joined* plain table: `Row level security is not supported by continuous aggregate
views.`

**Consequence for design:** the real price of native RLS on a hypertable is *no columnar
compression AND no continuous aggregates*. For high-volume per-tenant time series that is not a
trade worth making. Use **`security_barrier` views plus `REVOKE` on the base tables** instead — the
boundary is the revoked privilege, not the view's WHERE clause. Worked example with a five-test
verification block: `SET ROLE` to the tenant role with the GUC set, then unset, then a
cross-tenant role — four assertions that fail loudly if the boundary is not where you think.

Do not try to sequence around barrier 2 either. A real-time aggregate
(`materialized_only = false`) UNIONs materialized rows against live raw rows; the materialized half
is computed by the refresh job and unfiltered, the live half would be RLS-filtered for the caller.
The view returns a blend of all-tenant history and one-tenant recent data.

### The informational views changed — two joins/columns that will bite you — `VERIFIED`

**1. `timescaledb_information.continuous_aggregates` has no `finalized` column.** Selecting it errors
with `column "finalized" does not exist`. Old-format aggregates could no longer be created from 2.14
and were removed in 2.25, so the flag is meaningless — but the docs still reference it, and so does a
lot of copied-around SQL. The current columns are: `hypertable_schema`, `hypertable_name`,
`view_schema`, `view_name`, `view_owner`, `materialized_only`, `compression_enabled`,
`materialization_hypertable_schema`, `materialization_hypertable_name`, `view_definition`.

**2. For a refresh policy, `jobs.hypertable_name` holds the USER-FACING VIEW NAME**, not the internal
materialization hypertable. This one is genuinely dangerous because the wrong version looks *more*
correct and fails silently — it reports every aggregate as unpolicied:

```sql
-- WRONG: always returns every aggregate
... AND j.hypertable_name = ca.materialization_hypertable_name   -- '_materialized_hypertable_13'

-- RIGHT
... AND j.hypertable_schema = ca.view_schema
    AND j.hypertable_name   = ca.view_name                       -- 'cagg_tenant_daily'
```

Verified: `jobs` shows `hypertable_name = 'cagg_device_hourly'` while
`continuous_aggregates` shows `materialization_hypertable_name = '_materialized_hypertable_13'`.

### `hypertable_columnstore_stats()` is the current name, and returns no table name — `VERIFIED`

`hypertable_compression_stats()` still works as an alias. Neither returns the hypertable's name, so
`SELECT hypertable_name, ... FROM hypertable_columnstore_stats('t')` fails with
`column "hypertable_name" does not exist`. Supply the label as a literal. Returned columns:
`total_chunks`, `number_compressed_chunks`, and `before_`/`after_compression_` ×
`table_`/`index_`/`toast_`/`total_bytes`.

### All PostgreSQL aggregates work in caggs since 2.7 — including PostGIS ones — `VERIFIED`

Since 2.7, caggs store the **finalized** value of the whole target expression rather than
aggregate partials. Two useful consequences:

1. **Non-parallelizable aggregates are legal.** This is why `ST_Collect` works despite having
   *no* `combinefunc` (it is declared `parallel = safe`, which only means safe to *run* inside a
   worker — not partial-aggregatable). Pre-2.7 it would have been rejected.
2. **You can wrap an aggregate in a non-aggregate function.** The materialization column takes the
   type of the outermost expression, so this is a single `geometry` column:

```sql
ST_Centroid(ST_Collect(location::geometry))   AS activity_centroid,
ST_ConvexHull(ST_Collect(location::geometry)) AS activity_footprint
```

`ST_Centroid`, `ST_ConvexHull`, and the `geography → geometry` cast are all
`IMMUTABLE STRICT PARALLEL SAFE`, satisfying the cagg immutability rule. Store the *hull*, not the
raw collection — a day of 10-second pings collects into a very large geometry.

Caveat: a hierarchical cagg stacked on top aggregates the **final** geometries, not the original
points, which is not the same thing semantically.

`ST_Union` and `ST_Extent` do have combine functions and are parallelizable; `ST_Union` gained its
parallel machinery in PostGIS 3.3.

### Aggregate a bearing by storing unit-vector component SUMS, never the angle — `VERIFIED`

A compass bearing is circular, so `AVG(wind_direction_deg)` is not merely imprecise — it is wrong
in a way that looks fine. Average 350° and 10° and you get 180°: due south, when the answer is due
north. Nothing errors, and the value is in range.

The fix is to leave angle space. Store the two component **sums**, which are ordinary additive
aggregates and therefore compose up a cagg hierarchy:

```sql
-- hourly, over the raw hypertable
SUM(SIN(RADIANS(wind_direction_deg))) AS dir_sin_sum,
SUM(COS(RADIANS(wind_direction_deg))) AS dir_cos_sum,
COUNT(*)                             AS readings

-- daily, over the hourly cagg: plain SUMs, because sums of sums are sums
SUM(dir_sin_sum) AS dir_sin_sum,
SUM(dir_cos_sum) AS dir_cos_sum,
SUM(readings)    AS readings
```

Recover the bearing at read time, in a view over the cagg rather than in the cagg itself:

```sql
CASE WHEN SQRT(dir_sin_sum^2 + dir_cos_sum^2) < 0.01 * readings THEN NULL
     ELSE MOD((DEGREES(ATAN2(dir_sin_sum, dir_cos_sum)) + 360.0)::numeric, 360.0)::DOUBLE PRECISION
END AS wind_direction_deg,
SQRT(dir_sin_sum^2 + dir_cos_sum^2) / NULLIF(readings, 0) AS dir_consistency
```

Four things this buys, and one it demands:

- **`ATAN2(sin, cos)`, in that argument order.** A bearing is `(east, north) = (sin θ, cos θ)`, the
  transpose of the mathematical convention — see the bearing-convention note under PostGIS below.
  Swap the arguments and every bearing reflects about 45°.
- **`+ 360` before `MOD`**, because `ATAN2` returns −π…π and PostgreSQL's `MOD` keeps the sign of
  the dividend, so a bare `MOD` leaves negative bearings.
- **The mean resultant length comes free.** `SQRT(sin²+cos²)/readings` is 0–1: near 1 the readings
  agreed on a direction, near 0 they boxed the compass. That is a genuinely useful metric
  (steadiness) that an angle column cannot express.
- **Guard the degenerate case.** When the resultant collapses, `ATAN2(0, 0)` returns 0 — a
  confident-looking due north. Return NULL instead; the threshold above is 1% of the reading count.
- **It demands the raw angle at the bottom.** You cannot retrofit this over a cagg that already
  stored an averaged bearing; the information is gone.

Verified: over an identical row set the raw hypertable, the hourly cagg and the daily cagg stacked
on it all return `245.9176853179` — agreeing to **1e-12**, i.e. exact to float rounding, two tiers
of `SUM`-of-`SUM` deep. And the wrap case executed: `AVG` of 350° and 10° returns **180.0** (due
south) where the circular mean returns **0.0** (due north).

**When you check this yourself, align the window first, or the arithmetic will look broken.**
Comparing `MAX()`-to-`MAX()` across tiers gave a 0.4956° discrepancy that had nothing to do with
the math — the trailing partial buckets are not materialized, so the tiers covered *different rows*
(25972 raw / 25932 hourly / 25856 daily). Constrain every tier to a bucket-aligned, fully
materialized interior window and assert the reading counts match **before** comparing the values:

```sql
WITH w AS (SELECT MIN(day) + INTERVAL '1 day' AS lo,
                  MAX(day) - INTERVAL '1 day' AS hi FROM cagg_readings_daily)
-- then filter raw on time, hourly on bucket, daily on day, all against w
-- and confirm COUNT(*) = SUM(readings) = SUM(readings) = 23664 first
```

This applies to validating *any* cagg against its source, not just circular quantities.

### Real-time aggregation is OFF by default since 2.13 — `DOCUMENTED`

Always state it explicitly rather than inheriting a default that changed:

```sql
WITH (timescaledb.continuous, timescaledb.materialized_only = false)
```

Omit it on 2.13+ and queries return only materialized data, so "now" panels sit stale until the
next refresh. The tradeoff is real: real-time aggregation unions against the raw hypertable on
**every** query.

### `timescaledb.finalized` and `timescaledb.invalidate_using` no longer exist — `DOCUMENTED`

The docs still mention them. The option list in
`src/with_clause/create_materialized_view_with_clause.c` is now exactly: `continuous`,
`materialized_only`, `create_group_indexes`, `columnstore`, `chunk_interval`, `segmentby`,
`orderby`, `compress_chunk_interval`, `enable_granular_refresh`. Old-format caggs could not be
*created* from 2.14 and were removed entirely in 2.25. Don't design around `finalized => false`.

### cagg JOINs never invalidate on dimension-table edits — `DOCUMENTED`

JOINs in caggs are supported since **2.10** (INNER, one hypertable + one plain table, single
equality condition), broadened in **2.16** (LEFT, LATERAL, multiple plain tables, arbitrary
conditions). Permanent limits: only INNER/LEFT/LATERAL, exactly one hypertable, no `FROM ONLY`,
no joining another cagg's materialization.

**The footgun:** only changes to the *hypertable* are tracked. Update the joined dimension table
and the cagg keeps serving stale joined values until a full manual re-refresh.

**Therefore:** for a dimension that a cagg groups by, **denormalize the column into the
hypertable at insert time** instead of joining. It removes the join, removes the staleness trap,
and is faster. Denormalise the dimension column onto the fact rows at insert time.

### Other cagg restrictions worth remembering — `DOCUMENTED`

No `DISTINCT`/`DISTINCT ON` in the query body (fine *inside* an aggregate), no CTEs, no sublinks
(subqueries only via `LATERAL`), no `UNION`/`EXCEPT`/`INTERSECT`, no `GROUPING SETS`/`ROLLUP`/`CUBE`,
no `LIMIT`/`OFFSET`, and `GROUP BY` must include `time_bucket` on the hypertable's time dimension.
Window functions are behind an experimental GUC (off by default). Non-immutable functions became a
WARNING rather than an ERROR in 2.22.

Hierarchical caggs: the parent bucket must be an integer multiple of the child's, and you cannot
put a fixed-width bucket (seconds…days) on top of a variable-width one (months, years) — nor
months/years on top of weeks.

---

## Hypercore, compression, and late-arriving data

### Columnstore chunks accept INSERT, UPDATE, DELETE and upserts — `VERIFIED`

This corrects widely-repeated folklore. Tiger's docs are explicit: *"Once a chunk is in the
columnstore, it still supports inserts, updates, deletes, and upserts. Hypercore, the underlying
storage engine, handles this transparently."*

Tested directly: an `INSERT` into a chunk confirmed compressed
(`timescaledb_information.chunks.is_compressed = true`) succeeded with no error and no manual
decompression step, and a `DELETE` against the same chunk also succeeded.

So a late-arriving write into an already-compressed chunk is **not** rejected and **not**
corrupting. If you are writing workshop prose, do not claim otherwise.

The real reasons to keep `compress_after` beyond your late-arrival horizon are:

1. **Lock contention.** Conversion contends with concurrent writes to the same chunk; a backfill
   racing a columnstore policy can stall or fail. Documented remedy — pause, backfill, convert,
   resume:
   ```sql
   SELECT job_id FROM timescaledb_information.jobs
    WHERE proc_name = 'policy_compression' AND hypertable_name = 'my_table';
   SELECT alter_job(<JOB_ID>, scheduled => false);
   -- backfill here
   SELECT alter_job(<JOB_ID>, scheduled => true);
   ```
2. **Write cost.** Columnstore writes are more expensive than rowstore writes.
3. **Keep the hot window in the rowstore**, where high-frequency inserts land cheapest.

### A chunk must be ENTIRELY older than `compress_after` to be eligible — `VERIFIED`

Non-obvious, and it silently produces a 0% compression ratio. A columnstore policy converts a chunk
only when the chunk's whole range clears the threshold — effectively when `range_end` is older than
`now() - compress_after`, not `range_start`.

Consequence: with the **default 7-day chunk interval** and an 8-day compression window, a chunk is not
eligible until its newest possible row is 8 days old — so roughly 15 days of history are needed before
anything compresses at all. On a 12-day dataset, `number_compressed_chunks` was **0** and the
compression demo showed nothing.

Setting `tsdb.chunk_interval = '1 day'` on the high-rate table fixed it: 4 of 13 chunks compressed,
**88.1% saved** (20 MB → 2440 kB) on the same data. Sizing chunks so several fit inside the
compression window is worth doing deliberately, not just for the ratio but because it is the
recommended sizing anyway (recent chunks plus indexes should fit in memory).

### `add_columnstore_policy` can race your own manual conversion — `VERIFIED`

Adding a columnstore policy registers a background job, and TimescaleDB's scheduler may start it
within seconds. If the same script then converts chunks by hand — a normal thing to do in a demo, so
the compression numbers are visible immediately — the two race:

```
ERROR:  chunk "_hyper_2_3_chunk" is already compressed
```

`if_not_columnstore` already **defaults to true and does not save you**, because the flag is
evaluated when the call begins; a chunk the policy compresses microseconds later still raises. Handle
it per chunk:

```sql
DO $$
DECLARE v_chunk REGCLASS;
BEGIN
  FOR v_chunk IN SELECT show_chunks('my_table', older_than => INTERVAL '7 days') LOOP
    BEGIN
      PERFORM convert_to_columnstore(v_chunk, if_not_columnstore => true);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '% already handled (%)', v_chunk, SQLERRM;
    END;
  END LOOP;
END $$;
```

`convert_to_columnstore(chunk, if_not_columnstore, recompress)` is the current name;
`compress_chunk(uncompressed_chunk, if_not_compressed, recompress)` remains as an alias. This is the
same conversion-versus-concurrent-work contention that justifies keeping `compress_after` beyond any
window in which writes are still expected.

### `enable_columnstore = true` without a policy is silent and permanent — `VERIFIED`

Enabling the columnstore on a continuous aggregate and adding a policy that acts on it are
two separate steps, and skipping the second fails invisibly:

```sql
ALTER MATERIALIZED VIEW cagg_site_daily
  SET (timescaledb.enable_columnstore = true,
       timescaledb.segmentby = 'site_id', timescaledb.orderby = 'day');
-- looks configured. Nothing will ever convert it.
```

`timescaledb_information.continuous_aggregates.compression_enabled` reports `t`, and
`compression_settings` shows the segmentby and orderby you asked for — so every catalog
view you would naturally check says "configured". But with no `policy_compression` job the
aggregate simply grows uncompressed forever. Found exactly this on two of eight aggregates
here: the enable-block had been updated when they were added, a hand-written policy array
had not.

Two things follow:

- **Enumerate the catalog, never a literal list.** Any hand-maintained array of aggregate
  names will drift the moment someone adds one:
  ```sql
  FOR v_cagg IN SELECT view_name FROM timescaledb_information.continuous_aggregates
                 WHERE view_schema = 'public' AND compression_enabled ORDER BY view_name
  ```
- **Assert the pairing.** The check is cheap and catches the drift at build time. Note that
  for these policies `jobs.hypertable_name` holds the **user-facing view name**, not the
  materialization hypertable — getting that wrong reports every aggregate as unpolicied
  (see the informational-views entry above):
  ```sql
  SELECT ca.view_name FROM timescaledb_information.continuous_aggregates ca
   WHERE ca.compression_enabled
     AND NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs j
                      WHERE j.proc_name = 'policy_compression'
                        AND j.hypertable_name = ca.view_name);   -- must be empty
  ```

The same split exists on plain hypertables, but there it is harder to miss because
declaring `segmentby`/`orderby` at `CREATE TABLE` time auto-creates a default policy (next
entry). Aggregates get no such default.

### Declaring `segmentby`/`orderby` auto-creates a columnstore policy — `DOCUMENTED`

*"When you create a hypertable with `segmentby` and `orderby` options, TimescaleDB automatically
creates a columnstore policy."* A later `add_columnstore_policy` therefore raises
`ERROR 42710: policy already exists`. Always remove first:

```sql
CALL remove_columnstore_policy('my_table', if_exists => true);
CALL add_columnstore_policy('my_table', after => INTERVAL '7 days');
```

### Segment by tenant; do not add a space dimension for it — `DOCUMENTED`

For per-tenant time-series (every tenant, every few seconds), partition on **time only** and get
tenant locality from:

- `btree (tenant_id, time DESC)` for the uncompressed hot window, and
- `tsdb.segmentby = 'tenant_id'` + `tsdb.orderby = 'time DESC'` for compressed chunks.

A `tenant_id` space dimension multiplies chunk count — and therefore planning cost and per-chunk
overhead — without improving per-tenant scans.

### `add_tiering_policy` requires tiered storage on the service — `DOCUMENTED`

Several workshops here call it. It is a Tiger Cloud feature that needs object-storage
tiering enabled, so it **fails on a free/dev service**. Don't put it on the critical path of a
workshop; comment it out with a note, or gate it behind an explicit "if your service has tiering
enabled" instruction.

### Direct compress is a tech preview — `DOCUMENTED`

`timescaledb.enable_direct_compress_insert` / `_copy`, and the per-table
`timescaledb.direct_compress` option (2.29+), compress during ingestion. Explicitly labelled
**not production-ready**, and it can regress query performance or compression ratio when rows
arrive unsorted relative to `orderby` or the data is very high cardinality. Don't teach it as a
default.

---

## Tiger Cloud: what is actually available

### Extension inventory — `DOCUMENTED`

From the Tiger Cloud extensions page (AWS and Azure lists match):

- **Tiger Data:** `timescaledb`, `timescaledb_toolkit`, `pgvector`, `pgvectorscale`,
  `pg_textsearch`, `pgai`.
- **Third-party:** `postgis`, `postgis_raster`, `postgis_sfcgal`, `postgis_topology`,
  `postgis_tiger_geocoder`, `h3`, `pgrouting`, `pgaudit`, `pgpcre`, `pg_repack`, `pg_cron`, `unit`.
- **Contrib:** the usual set — `postgres_fdw`, `pg_stat_statements`, `pg_trgm`, `hstore`, `ltree`,
  `pgcrypto`, `tablefunc`, `earthdistance`, `cube`, `uuid-ossp`, `plperl`, and others.

**Not available:** `http` (pgsql-http), `pg_net`, `plpython3u`.

### There is no way to make an HTTP request from SQL on Tiger Cloud — `DOCUMENTED`

`http` and `pg_net` are both absent, and `plpython3u` is not offered. If a workshop idea depends
on calling an external API from inside the database, either generate the data natively in
PL/pgSQL or move the fetch outside the database. A deterministic in-database model
took the first route, and documents Open-Meteo as an optional swap for self-hosted setups.

For self-hosted Docker (`timescale/timescaledb-ha`), `pgsql-http` is also **not** bundled, but the
image is Ubuntu 22.04 with the PGDG repo already configured, so
`apt-get install postgresql-16-http` in a derived image works. `pg_net` is not in PGDG apt at all.

**And do not route around it by self-hosting `pgsql-http`.** The availability gap is the smaller
reason; the larger one is that giving the database engine outbound network access is a security
posture worth refusing on purpose:

- any SQL injection becomes **server-side request forgery**, issued from inside the database
- the engine gains reach into internal endpoints and cloud instance-metadata services
- API credentials end up stored in the database, and are therefore carried by every dump
- an unbounded, blocking network call runs inside a transaction, holding its locks and snapshot
  for as long as the remote host takes to answer

Fetch from outside the database instead — a small script, scheduled or run by hand — and let SQL
do only the derivation. That keeps the ingest boundary where it can be reviewed and the
credentials where they belong.

### `pg_cron` is listed but support-gated — `DOCUMENTED`

The extensions page annotates it: *"(contact support@tigerdata.com to enable)"*. Treat it as
unavailable for any workshop an attendee self-provisions. Use **`add_job()`** instead — see below.

On self-hosted `timescaledb-ha`, `pg_cron` is installed but **not preloaded**, so
`CREATE EXTENSION pg_cron` fails until you start Postgres with
`-c shared_preload_libraries=timescaledb,pg_cron`. `cron.database_name` is `PGC_POSTMASTER` and
cannot be `SET` at runtime; pg_cron may only be installed in one database per cluster, and jobs
registered elsewhere are recorded but silently never run — use `cron.schedule_in_database()` to
target another database. Sub-minute (`'30 seconds'`, N in 1–59) schedules need pg_cron ≥ 1.5.
A job never overlaps itself, but queued runs accumulate.

### In-database scheduling: use `add_job()` — `DOCUMENTED`

Available everywhere, no preload, no ticket, and what most workshops here already rely on
via policies. The procedure must take `(job_id INT, config JSONB)`:

```sql
CREATE PROCEDURE job_do_the_thing(job_id INT, config JSONB) LANGUAGE plpgsql AS $$
BEGIN
  PERFORM do_the_thing();
END $$;

SELECT add_job('job_do_the_thing', '15 minutes');
```

Observe with `timescaledb_information.jobs` (registered jobs and `next_start`),
`timescaledb_information.job_history` (per-run success and error, since 2.12), and
`timescaledb_information.job_stats` (aggregate stats). Manually trigger with `run_job(job_id)`;
pause with `alter_job(job_id, scheduled => false)`.

On Tiger Cloud, jobs are owned by `tsdbadmin`, and a trigger on
`_timescaledb_config.bgw_job` prevents any user creating or modifying jobs owned by another user.

### `tsdbadmin` is not a superuser — `DOCUMENTED`

It has `CREATEROLE` (so multi-tenant role demos work) but cannot disable triggers in internal
schemas, and cannot set `PGC_POSTMASTER` GUCs. Design workshops so nothing needs superuser.

### Prefer non-`-oss` images when self-hosting — `DOCUMENTED`

Continuous aggregates are TSL-licensed and live in `tsl/`. A `timescaledb-ha:*-oss` image cannot
create them. Also note `-all` tags mean *additional PostgreSQL major versions* for `pg_upgrade`,
not additional extensions.

---

## Idempotent data generation

### Parallel backfill works — but only if the chunks already exist — `VERIFIED`

A chunk-aligned parallel backfill looks obviously correct: split the range into disjoint
windows, give each worker whole chunks, no two workers touch the same chunk. Run it and you get
**1.09x on four workers**. The reason is a lock, and it is not the one you would guess from the
symptom.

**Creating a chunk takes `ShareUpdateExclusiveLock` on the PARENT hypertable, and PostgreSQL
holds locks until the transaction commits.** SUE self-conflicts, so the first worker to create a
chunk holds the parent for its *entire* transaction and every other worker queues behind it.
Sampled mid-run with 4 workers: 3 of 4 backends on `Lock / relation`, every ungranted lock
`ShareUpdateExclusiveLock on derived_metrics`, `pg_blocking_pids()` showing a clean chain
`{482} <- {482,483} <- {482,483,484}`, and container CPU pinned at **100% of a 400% ceiling**.

**Pre-create the chunks in one cheap serial pass and the same fan-out scales.** Use
[`create_chunk()`](https://www.tigerdata.com/docs/reference/timescaledb/hypertables/create_chunk),
which takes the range explicitly and creates the chunk with zero rows:

```sql
SELECT (_timescaledb_functions.create_chunk(
          'readings'::regclass,
          jsonb_build_object('time', jsonb_build_array(
            (EXTRACT(EPOCH FROM lo) * 1000000)::BIGINT,     -- epoch MICROSECONDS
            (EXTRACT(EPOCH FROM hi) * 1000000)::BIGINT)))).created;
```

Verified on 2.29.0: it is **idempotent** — an existing chunk returns `created => false` rather
than raising, so no exception handler is needed — the chunk is created with zero rows and **zero
dead tuples**, and subsequent inserts route into it without creating another. Pass the bounds as
epoch microseconds rather than ISO strings to sidestep any question of timezone interpretation,
and round the window start down to a multiple of the interval **since the epoch**, because that is
where TimescaleDB places boundaries — a range that is not on a real boundary creates a chunk the
inserts then do not use.

Measured, 20 devices x 730 days (1.4M rows/hypertable), 4 CPU / 8 GiB:

| | 1 worker | 4 workers | speed-up |
|---|---|---|---|
| workers create their own chunks | 34.3 s | 31.2 s | **1.09x** |
| chunks pre-created | 34.3 s | **9.3 s** | **3.67x** |

With pre-creation, all four backends sample as `RUNNING` with **zero** wait events and CPU sits at
**384% of 400%**. Pre-creation costs one single-row insert per chunk (105 for a two-year history),
then `DELETE` them — **not** `TRUNCATE`, which drops the chunks again and undoes the point.

**This is not in the documentation.** The published backfill guidance says to use parallel
workers but "ensure time ranges across workers do not overlap, to prevent contention" — which is
exactly the 1.09x row above. Non-overlapping ranges are necessary but not sufficient; each worker
still creates its own chunks, and that is the serialisation. This entry rests on our own
measurements alone, so re-check it against a live service before quoting it externally.

Things that are NOT the cause, each ruled out by measurement rather than reasoning:

- **Not the read side.** The generator reads five dimension tables on every row
  (`devices`, `sites`, `regions`, `device_neighbors`, `device_faults`). All take
  `AccessShareLock`, which is shared and conflicts only with `AccessExclusiveLock`; all four
  workers held all five simultaneously, all granted. Replacing the two read-heavy functions with
  constants moved 1.07x to only 1.22x, while pre-creating chunks moved it to 3.67x.
- **Not direct compress.** `enable_direct_compress_insert = on` scaled 2.2x on its own.
- **Not writing two hypertables from one CTE.** That shape scaled 2.55x.
- **Not transaction scope.** One transaction per chunk instead of per window bought 14%.

### The continuous-aggregate initial fill parallelises too — by WINDOW, not by aggregate — `VERIFIED`

`refresh_continuous_aggregate()` can run **concurrently on the same aggregate over disjoint
windows**. Measured on `cagg_readings_hourly`, 12 windows of 70 days: 3105 ms serial, **1258 ms on 4
workers (2.47x)**, no errors. The error people remember —
`could not refresh continuous aggregate due to a concurrent refresh` — comes from a manual
refresh overlapping a refresh **policy's** window, not from disjoint manual windows. Register the
policies after the initial fill and leave them paused, and the conflict cannot arise.

Two axes are available, and they are not equally good. Measured over all eight aggregates of a
four-deep hierarchy, 20 devices x 730 days, 4 CPU:

| strategy | time | speed-up |
|---|---|---|
| fully serial | 13590 ms | — |
| **4 window workers per aggregate, aggregates in dependency order** | **4805 ms** | **2.83x** |
| aggregates within a dependency level run concurrently | 9119 ms | 1.49x |
| both combined | 5664 ms | 2.40x |

**Parallelise the windows, not the aggregates.** Window-parallelism is both faster and simpler —
it needs no dependency-level bookkeeping beyond the ordering correctness already demands.
Combining the two oversubscribes the CPUs and loses ground.

Two things to get right:

- **Order is a correctness constraint, not a performance one.** In a hierarchy, refreshing a
  child before its parent is materialised yields an **empty child, silently**. Derive the order in
  SQL from the actual chain rather than trusting a hand-kept list, and never sort the aggregate
  names alphabetically — `cagg_site_daily` sorts before `cagg_site_hourly`, which is
  exactly backwards.
- **Align windows to the MATERIALIZATION hypertable's `chunk_interval`, not the bucket width.**
  TimescaleDB defaults it to 10x the bucket, so an hourly aggregate over 7-day source chunks gets
  **70-day** materialization chunks:
  ```sql
  SELECT d.time_interval FROM timescaledb_information.continuous_aggregates ca
    JOIN timescaledb_information.dimensions d
      ON d.hypertable_name = ca.materialization_hypertable_name
   WHERE ca.view_name = 'cagg_readings_hourly';     -- 70 days
  ```
  Same reason as the raw backfill: workers that straddle a materialization chunk boundary contend
  to create it, and chunk creation holds `ShareUpdateExclusiveLock` on the parent until commit.

Verified lossless: after a parallel fill, the hourly aggregate's `SUM(readings)` equalled the raw
row count exactly (1,120,992 = 1,120,992) with a **0.00000000%** difference in summed power.

Worth knowing for the serial path too: **since TimescaleDB 2.28.0 `refresh_continuous_aggregate()`
already refreshes incrementally**, `buckets_per_batch` defaulting to 10, each batch in its own
transaction. Hand-rolled month-at-a-time windowing purely to bound memory is now partly redundant;
`options => '{"buckets_per_batch": 0}'` restores the old single-transaction behaviour.

### A single load session cannot use more than one core — `VERIFIED`

Do not size compute expecting a serial load to use it. PostgreSQL's rule:
*"If a query contains a data-modifying operation either at the top level or within a CTE, no
parallel plans for that query will be generated"* — the only exceptions being `CREATE TABLE AS`,
`SELECT INTO`, `CREATE MATERIALIZED VIEW` and `REFRESH MATERIALIZED VIEW`. So `INSERT .. SELECT`
runs in one backend on one core no matter how many CPUs the service has, and marking the
generator functions `PARALLEL SAFE` changes nothing.

Measured single-session throughput, both hypertables, on cgroup-limited containers:

| resources | total rows/s |
|---|---|
| 0.5 CPU / 2 GiB | 21,400 |
| 1 CPU / 4 GiB | 40,300 |
| 2 CPU / 8 GiB | 54,600 |
| 4 CPU / 16 GiB | 57,700 |

Flat past ~2 CPU. **Buy CPU for a load only if the loader is parallel; otherwise buy memory**,
which is what the continuous-aggregate fill actually needs.

### `COPY` is not faster than `INSERT .. SELECT` when the rows are generated in SQL — `VERIFIED`

The advice to prefer `COPY` over `INSERT` is about bulk loading **from a client or file**, where
the alternative is many single-row `INSERT` statements and per-statement overhead dominates. It
does not transfer to a generated load. Measured on identical generation logic, 27 chunk windows:

| | 1 worker | 4 workers |
|---|---|---|
| `INSERT .. SELECT` | 7295 ms | 2102 ms |
| `COPY (SELECT ...) TO STDOUT` piped to `COPY ... FROM STDIN` (binary) | 7294 ms | 2133 ms |

A dead heat, because the insert is not the cost:

```
SELECT only, rows discarded   6012 ms   (85%)
SELECT + INSERT               7045 ms   -> insert accounts for 1033 ms (15%)
```

Generation dominates. `COPY` optimises the 15% and adds a serialise/pipe/deserialise round trip
through the client to do it. `ORDER BY time` within a window bought ~4%, at the edge of noise;
ordering by `(segmentby, orderby)` to match the columnstore added nothing.

There is also a correctness reason not to reach for it here: `COPY` writes one table, so a
generator that must populate two hypertables from ONE `MATERIALIZED` source — guaranteeing both
get identical values including the random sensor noise — cannot be expressed as a single `COPY`
without staging. Generating twice would give the two tables different noise.

`COPY` remains the right tool when the rows come from outside the database:
`timescaledb-parallel-copy --workers <cores>` is the documented path for file-based bulk loads.

### Derive the insert window from the data, not from `ON CONFLICT` — `DOCUMENTED`

Attendees re-run scripts. The robust pattern for a re-runnable generator:

```sql
SELECT COALESCE(MAX(time), now() - INTERVAL '30 days') INTO v_from FROM my_hypertable;
-- generate strictly after v_from, up to now()
```

A second run finds nothing to do. Prefer this over unique constraints plus upserts, because a
unique index on a hypertable **must include the partitioning column**, and upserts against
columnstore chunks add complexity for no benefit here.

### PostgreSQL type traps that bite generator SQL — `VERIFIED`

Four that each cost a debugging cycle here. None are TimescaleDB-specific,
but generator SQL hits all of them.

**`mod()` has no double-precision overload.** Only `smallint`, `int`, `bigint`, `numeric`. Wrapping a
computed heading or hour to a range needs a numeric round trip:

```sql
MOD((expr)::numeric, 360.0)::DOUBLE PRECISION       -- not MOD(expr, 360.0)
```

**`round(double precision, integer)` does not exist.** `round(double)` (no digits) and
`round(numeric, int)` do. `ROUND(SUM(x) / 1000.0, 1)` on a double column fails with
`function round(double precision, integer) does not exist` — cast to `::numeric` first.

**Untyped decimal literals are `numeric`, not `double precision`.** So `260.0 + 45.0 * sin(...)`
yields double (sin dominates), but `CASE WHEN ... THEN 260.0 ELSE 100.0 END` yields *numeric*. Mixed
expressions silently change result type and then fail at the next function call.

**`EXTRACT(HOUR FROM timestamptz)` depends on the session `TimeZone`.** This quietly breaks
`IMMUTABLE`: two sessions with different `TimeZone` settings get different answers from what you
declared to be a pure function, so generated history is not reproducible. `EXTRACT(EPOCH FROM ...)` is
absolute and safe. Normalise first for anything calendar-shaped:

```sql
EXTRACT(DOY  FROM (ts AT TIME ZONE 'UTC'))
EXTRACT(HOUR FROM (ts AT TIME ZONE 'UTC'))
```

PostgreSQL does not verify volatility declarations — it trusts you, then punishes the lie with cached
plans that reuse a stale value.

### psql: `\gset` fails on an empty result set — `VERIFIED`

`\gset command failed: no rows returned`, which aborts the script under `-v ON_ERROR_STOP=1`. If a
file might run before its data is seeded, make the query always return exactly one row:

```sql
SELECT COALESCE((SELECT id::text FROM t ORDER BY name LIMIT 1), '00000000-0000-0000-0000-000000000000')
         AS demo_id
\gset
```

### `DROP SCHEMA public CASCADE` destroys TimescaleDB — `VERIFIED`

TimescaleDB installs its objects into `public`, so this apparently-clean reset takes the extension with
it. Everything then fails with `unrecognized parameter namespace "tsdb"` and
`procedure remove_columnstore_policy(...) does not exist`, which looks like a version problem rather
than self-inflicted damage. To reset a workshop, drop the specific tables — or recreate the container.

### Make the generator a pure function of (entity, timestamp) — `DOCUMENTED`

If your model function is `IMMUTABLE` and takes the timestamp as an argument, historical backfill
and incremental "live" generation become the *same code path* differing only in window, and
history is reproducible. Add stochastic noise in the **caller**, not inside the immutable
function.

`random_normal(mean, stddev)` is **new in PostgreSQL 16** — use it for Gaussian noise instead of
hand-rolling Box-Muller. Note `random(min, max)` did *not* arrive until PG 17.

---

## PostGIS

### geography vs geometry — `DOCUMENTED`

Store GPS/global data as `geography(Point, 4326)`: distances come back in metres and are true
spheroidal. Cast to `::geometry` only for operations geography lacks, and cast back before
measuring. GiST is the only index type for geography. Use `ST_DWithin(col, point, metres)` for
radius filters — filtering on `ST_Distance(...) < x` cannot use the index.

### Use `ST_Project` for metre offsets, never degree arithmetic — `VERIFIED`

`ST_Project(geography, distance_m, azimuth_radians)` walks a true geodesic on the spheroid and
returns a geography. Verified exact: `ST_Distance(g, ST_Project(g, 750, radians(45)))` returns
750.00.

This is the correct way to place points at known metre offsets — building a sensor grid, a survey
pattern, an equipment layout. The tempting alternative is to divide metres by 111,320 to get degrees.
That is right for latitude and **wrong for longitude by a factor of 1/cos(latitude)** — 1.7x at 55°N,
2x at 60°N. A grid built that way is stretched east-west and looks entirely plausible.

Measured on a 96-device layout spanning 8°N to 56°N: nearest-neighbour spacing matched the intended
value to within a metre at every latitude. Verify it by measuring nearest-neighbour spacing at several latitudes against the intended
figure — a degree-arithmetic layout passes at the equator and fails progressively towards the
poles.

**Bearing convention trap.** A compass bearing θ as an (east, north) unit vector is
`(sin θ, cos θ)` — the transpose of the mathematical convention. So rotating an offset to a bearing
is:

```
east  = dx·cos θ + dy·sin θ
north = dy·cos θ - dx·sin θ
```

Using the textbook rotation matrix rotates by **−θ**, mirroring the layout. Spacing checks still
pass; only an orientation check catches it. And `ST_Azimuth` returns **radians**, so wrap it in
`DEGREES()` before comparing against a bearing in degrees.

**`ST_Project`'s azimuth is periodic, so do not wrap it.** `RADIANS(bearing + 180.0)` and
`RADIANS(bearing - 180.0)` land on the same point — measured **0 m** apart for 380° against 20°. Two
consequences: reaching for `MOD` here is pointless, and it is actively harmful because
`MOD(double precision, numeric)` has no overload (see the type-traps entry above), so the wrap you
did not need is what breaks the query. Note that `ST_Equals` on the two results still returns false —
they differ in the last floating-point bit — so assert with `ST_Distance(...) = 0`, not `ST_Equals`.

**`ST_Azimuth` is undefined for coincident points** and returns NULL, which then propagates through
every downstream `COS`/`SIN`/`MAX`. When decomposing device offsets about a site centre, one
device may sit exactly on that centre:

```sql
LEFT JOIN devices t ON t.site_id = p.site_id
                    AND ST_Distance(p.center_location, t.location) > 0   -- drop the coincident one
...
COALESCE(MAX(ABS(...)), 400.0) AS along_m    -- and give the all-coincident case a floor
```

Without both halves a single-device site yields NULL extents and the overlay silently vanishes —
no error, just nothing drawn. Verified by forcing the no-off-centre-device case: the `COALESCE`
fires and the geometry still builds three non-NULL points.

### `ST_DWithin` in a LATERAL is index-assisted; `ST_Distance` in a WHERE is not — `VERIFIED`

The difference between a linear and a quadratic neighbour search, and both spellings look equally
reasonable.

```sql
-- QUADRATIC: no index. Planner materialises every pair, then filters.
FROM devices a JOIN devices b ON b.site_id = a.site_id
 WHERE ST_Distance(a.location, b.location) <= 12 * p.rotor_diameter_m
-- plan: Merge Join ... Join Filter: (st_distance(...) <= ...)

-- LINEAR: GiST index prunes per outer row.
FROM devices a
CROSS JOIN LATERAL (
  SELECT b.device_id FROM devices b
   WHERE b.site_id = a.site_id
     AND ST_DWithin(b.location, a.location, 12 * p.rotor_diameter_m)
) nb
-- plan: Nested Loop -> Index Scan using idx_devices_location
--       Index Cond: (location && _st_expand(a.location, ...))
```

Measured on a device layout, 6 sites: the quadratic form examined 336 pairs to keep 228 at 8
devices per site (1.5x waste) and 59,400 to keep 5,016 at 100 (12x) — the waste ratio grows
linearly with group size, so total work is O(n²). The indexed form produced **identical output** with
each doubling of rows costing under 2x the time, and marginal cost per row *falling* (0.391 →
0.147 ms) as fixed overhead amortised. 3,072 rows of layout plus 28,548 neighbour pairs built in
451 ms.

Note the radius may be a per-row expression — it does not need to be a literal. That is different
from the KNN `<->` operator, which only gets index assistance when one operand is a **constant**.

Also worth checking your *verification* queries: a `MIN(ST_Distance(...))` nearest-neighbour check
over the same group is itself O(n²) and can end up more expensive than the thing it verifies. Reuse
the precomputed neighbour table instead.

### `LPAD` truncates — it does not just fail to pad — `VERIFIED`

```sql
SELECT LPAD('99', 2, '0'), LPAD('100', 2, '0');   -- '99', '10'
```

`LPAD(value, n, ...)` returns *exactly* n characters, so a value wider than n is **cut from the
right**. Zero-padding an identifier to a hard-coded width therefore silently collides once the
counter passes that width: `T100` became `T10`, duplicating `T10`, and an `ON CONFLICT DO NOTHING`
insert discarded it without a word. A request for 150 devices per site produced 99.

Pad to a width derived from the maximum:

```sql
LPAD(n::text, GREATEST(2, LENGTH(max_n::text)), '0')
```

The general lesson: `ON CONFLICT DO NOTHING` plus a generated key is a silent-data-loss combination.
If a generator is supposed to produce a known number of rows, assert the count.

### `ST_MakeLine` is geometry-only, and needs an explicit ORDER BY — `DOCUMENTED`

There is no geography overload of the aggregate. Row order is not guaranteed without `ORDER BY`
inside the aggregate call, and getting it wrong yields self-crossing spaghetti:

```sql
ST_MakeLine(location::geometry ORDER BY sequence)::geography
```

The cast is safe here because `ST_MakeLine` only assembles vertices — no distance math.

### `ST_LineInterpolatePoint` on geography needs PostGIS ≥ 3.4 — `VERIFIED` on 3.6

Confirmed present on PostGIS 3.6.4 as `st_lineinterpolatepoint(geography, double precision, boolean)`
— the third argument is `use_spheroid`, defaulted, so two-argument calls work. Also confirmed:
`st_azimuth(geography, geography)` exists, and **`st_makeline` is geometry-only** (overloads are
`geometry[]`, `(geometry, geometry)` and the `geometry` aggregate — no geography form).

The ≥ 3.4 lower bound remains inference: the geography overload appears in the 3.4 manual and not the
3.3 one, and the sibling `ST_LineSubstring` explicitly documents "Geography support was introduced in
version 3.4.0". No direct changelog line found. Check with `SELECT postgis_version();` if you might be
on 3.3 or older, and use the `ST_Transform`-to-UTM fallback if so.

**Why it matters:** the geometry overload interpolates in **degree space**. On a multi-vertex route
mixing north–south and east–west legs, fraction `0.5` is *not* the midpoint by true distance — at
52°N a degree of longitude is ~68 km against ~111 km for latitude. Fallback for older PostGIS is
to project to a local UTM zone, interpolate, and transform back. Do not use SRID 3857 for distance
work; its scale error is `1/cos(lat)`.

### KNN `<->` measures sphere on geography, while `ST_Distance` measures spheroid — `DOCUMENTED`

True (exact) KNN for geometry *and* geography arrived in PostGIS 2.2. But the docs note geography
KNN "is based on sphere rather than spheroid", so `<->` and `ST_Distance` disagree by up to ~0.3%.
Order with `<->`, then report the distance with `ST_Distance`.

**The index is only used when one operand is a constant** — not a subquery, CTE, or column
reference. A lateral join against a column silently degrades to a full scan. Always `EXPLAIN` KNN
demos and look for `Index Scan ... ORDER BY (col <-> '...'::geography)`.

---

## Open questions to resolve

- Whether Tiger Cloud ships the same versions as the reference environment above (PG 17.10 /
  TimescaleDB 2.29.0 / PostGIS 3.6.4). The RLS, columnstore-write and informational-view findings are
  version-sensitive; re-check them on a live service before quoting them externally.
- Whether `add_job` reliably honours schedule intervals below one minute.
- Whether the `ALTER TABLE … ENABLE ROW LEVEL SECURITY` / columnstore incompatibility is a deliberate
  permanent restriction or a current implementation limit. It is worth asking upstream, because it
  removes native RLS as an option for essentially every hypertable.
