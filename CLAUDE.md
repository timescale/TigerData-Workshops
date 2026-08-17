# Working in TigerData-Workshops

This repo holds self-contained, hands-on workshops that teach TigerData (TimescaleDB on
Tiger Cloud) through a realistic domain problem. Each workshop is a teaching artifact first and
a codebase second: an attendee reads it top to bottom in `psql` and understands *why* every
statement is there.

Two companion files record platform behaviour that has already bitten us, each entry with a
confidence label. They are split by which system will punish you:

| Read this | Before you | Because it covers |
|---|---|---|
| **[TIGER_PLATFORM.md](TIGER_PLATFORM.md)** | write or change any SQL that runs *in* the database | hypertables, continuous aggregates, Hypercore/columnstore, retention and tiering, Tiger Cloud's real extension inventory and gated features, idempotent generation, PostGIS |
| **[GRAFANA_PLATFORM.md](GRAFANA_PLATFORM.md)** | author or edit a dashboard, a panel, or a provisioning file | panel JSON and the grid, provisioning and datasource wiring, geomaps (view/fit, layers, overlays), variable interpolation, and the SQL that has to live inside a panel |

Both will save you from shipping something that fails only on a real service or only once
provisioned. Anything touching *both* — a dashboard query against a cagg, say — needs both.

They are **read before** and **extended after**: whatever a new workshop teaches you about the
platform belongs in one of them, generalised so it outlives that workshop. See
*Maintaining the platform files* below for what an entry has to contain.

## Non-negotiables

1. **Verify platform claims; do not write from recall.** Use the Tiger MCP `search_docs` tool
   (sources: `tiger`, `postgres_*`, `postgis_*`) before relying on any assertion about
   TimescaleDB, Tiger Cloud, or PostGIS behaviour. Model recall about this platform is
   frequently a version or two out of date, and the public docs themselves are sometimes stale —
   when docs and the TimescaleDB source disagree, the source wins. The same rule applies to
   Grafana: confirm panel-model fields and defaults against Grafana's own source
   (`panelcfg.cue`, `panelcfg.gen.ts`, the layer `.tsx` files) rather than recall, because a
   wrong field name in panel JSON produces no error at all — the panel just renders wrong.
   Record what you learn in **`TIGER_PLATFORM.md`** (database) or **`GRAFANA_PLATFORM.md`**
   (dashboards), generalised away from the workshop that prompted it — see *Maintaining the
   platform files*.
2. **Everything must work self-service on a fresh Tiger Cloud service.** An attendee signs up,
   provisions a service, and starts within minutes. Anything requiring a support ticket, a
   paid tier, or a feature toggle is **not** a workshop prerequisite. See TIGER_PLATFORM.md for
   the current list of gated features (`pg_cron`, tiered storage, and others).
3. **Test at the SMALLEST data volume that exercises the change. Scale up only to confirm.**
   Every workshop that generates data must expose knobs for its volume, and the iteration loop
   must use the smallest setting that can reproduce the behaviour under test:

   ```bash
   # smallest useful data set: ~4 seconds, ~5,800 rows
   ./reset_demo.sh --yes --sites 1 --devices-per-site 1 --days 30
   # only once it passes, confirm at the defaults: ~1 minute, 3.4M rows/hypertable
   ./reset_demo.sh --yes
   ```

   This is a hard-won rule, not a preference. Syntax errors, wrong function signatures, missing
   columns, broken site/region lookups, policy-vs-script races and ordering bugs all reproduce
   at one device and one month. Only three classes of problem genuinely need volume: memory
   exhaustion during the initial aggregate fill, chunk-count effects (lazily-iterated
   `show_chunks` fails at 100+ chunks but not at 4), and query-plan changes. Reach for the full
   dataset when you are testing one of those, or for a final confirmation — never for the tenth
   iteration of a syntax fix.

   Small volumes also surface bugs the defaults hide: a one-site data set exposed a hardcoded
   site name, and a one-device fill raced a refresh policy precisely *because* it finished
   fast. Run the extremes of the knobs, not just the middle.
4. **Prefer the newest API surface.** Declarative `CREATE TABLE ... WITH (tsdb.hypertable, ...)`
   over `create_hypertable()`; `add_columnstore_policy` over `add_compression_policy`;
   `convert_to_columnstore` over `compress_chunk`.
5. **Every SQL file must be re-runnable.** An attendee will run a file twice, or run it after a
   typo halfway through. Start with a reset block, use `IF NOT EXISTS` / `CREATE OR REPLACE`, and
   make data generators derive their insert window from the data already present rather than
   assuming a clean table.
6. **Never commit credentials.** Connection strings go in `.env` (gitignored) or are pasted by
   the attendee. Committed config uses `${VAR}` interpolation or an obvious `<placeholder>`.
7. **Data generation lives in SQL. Full stop.** No Python, Node, Go or shell program may compute,
   synthesise, or transform a row that lands in a table — attendees have to be able to read the
   generator, and the generator being SQL is itself part of the lesson. Shell scripts are allowed
   for **orchestration only**: sourcing `.env`, invoking `psql -f`, checking connectivity,
   reporting counts. The test is whether deleting the script would change any data value. If it
   would, the logic belongs in a PL/pgSQL function. A `reset_demo.sh` that sources `.env`, runs the
   SQL files in order and prints verification counts is the shape to copy — nothing more than that.

## Maintaining the platform files

`TIGER_PLATFORM.md` and `GRAFANA_PLATFORM.md` are the accumulating asset of this repo. Workshops
come and go; those two files are what stops the next person paying again for something we already
learned. **Every workshop is an occasion to extend them, and adding a workshop without adding what
it taught you is an incomplete change.**

### They are platform files, not workshop files

An entry describes how **TimescaleDB, Tiger Cloud, PostGIS, PostgreSQL or Grafana** behaves. It
does not describe what one workshop did.

- **No workshop names, no workshop paths, no domain vocabulary.** Not `turbine_id`, not
  `location_pings`, not "the fleet workshop". Write the example in neutral terms — `devices`
  grouped into `sites`, a `readings` hypertable, `tenant_id` for a tenancy boundary — so it reads
  as guidance to anyone, in any domain.
- **The test:** would this entry still be true, and still useful, for a workshop about a completely
  different subject? If it only makes sense next to one domain's schema, generalise it or leave it
  in that workshop's own comments.
- Domain detail is allowed only as an *illustration of a general category* — "a bearing column may
  use the FROM convention rather than TOWARD; meteorological wind direction is the classic case"
  is fine, because the rule is about bearings, not about wind.

### What makes an entry worth having

Record the behaviour, the evidence, and the consequence. An entry that only asserts is not much
better than recall, which is what these files exist to replace.

- **Label the confidence, honestly.** `VERIFIED` means we executed it and observed the result —
  name the versions and, where it matters, the resource sizes. `DOCUMENTED` means the vendor docs
  or upstream source say so and we did not run it; cite the page or the file. `ASSUMED` means
  inferred, and says what would settle it. Promote entries as they are proven.
- **Prefer a measurement to an adjective.** "Slower" is not an entry; "34.3 s serial against 9.3 s
  on four workers" is. Give the conditions so someone can re-run it.
- **Say how to check it.** The query, the `EXPLAIN` line to look for, the catalog view, the
  upstream source file. The most valuable entries are the ones where the *symptom* points the wrong
  way, so include the diagnostic that actually settles it.
- **Lead with the failure mode when there is one.** Things that raise an error teach themselves.
  What belongs here is what fails silently: a default that changed, a field name that renders wrong
  rather than erroring, a catalog column that quietly reports the opposite of what you assumed.

### Extending rather than accreting

- **Extend the existing entry** instead of adding a near-duplicate beside it. If two entries
  disagree, one of them is wrong — resolve it, do not leave both.
- **Put an entry in one file only.** Database behaviour in `TIGER_PLATFORM.md`, Grafana behaviour
  in `GRAFANA_PLATFORM.md`, and cross-link when something genuinely spans both.
- **Correct in place, and say that you did.** If a later measurement disproves an entry, rewrite
  it and note what was wrong; leaving a comfortable falsehood in place is worse than having no
  entry at all, because the next person will trust it. The same goes for an entry whose *cause* was
  guessed — downgrade it to `ASSUMED` and record what was actually observed.

## Layout

One workshop per top-level directory. Naming: `TimeSeries-Workshop-<Domain>` for the
time-series family, `<Topic>-Workshop` otherwise.

**One teaching subject per top-level workshop. Never nest two workshops inside one
directory.** If a body of material has two subjects that an attendee could sensibly run
independently — a different domain, a different data shape, a different lesson — they are two
workshops at the repo root, not `01-`/`02-` parts of one. Each gets:

- its own `README.md`, complete on its own: setup, how to run, what to look at, how to reset.
  No "see the parent README" — an attendee opening one directory must never need another.
- its own `reset_demo.sh`, which builds only that workshop. No `--part` selector.
- its own `docker-compose.yml` and Grafana assets in that directory. **Not** its own
  `.env.example` — connection settings are one file at the repo root, see
  *Credentials and environment* below.
- its own root-README entry.

Nothing may live in a shared parent directory. This rule was written after splitting one: a
workshop that had grown two subjects into `01-`/`02-` subdirectories behind a `--part` flag became
two top-level workshops, which meant unpicking a `--part` selector threaded through ~900 lines of
shell and a `shared/` tree whose every file in fact belonged to exactly one of the two. Cheaper not
to combine them in the first place.

**Workshops must co-exist on one database, because attendees will point them all at the same
service.** Three rules follow, and each has already bitten us:

- **Table names must not collide**, and neither may role names.
- **Anything genuinely shared must be created defensively and torn down surgically.** These
  workshops share a `workshop_config` tunables table and its `cfg*()` accessors: each creates it
  with `CREATE TABLE IF NOT EXISTS` and seeds only its own keys, tagging every row with a
  `'<Workshop Name>: '` description prefix. `--hard` then deletes only rows matching *its* prefix
  and drops the table only once nothing is left. Deriving ownership from a prefix rather than a
  hand-written key list matters: a list silently goes stale the moment someone adds a key. And
  seed with `ON CONFLICT (key) DO UPDATE SET description = EXCLUDED.description` — `DO NOTHING`
  leaves a stale prefix behind on an existing database, which quietly breaks the `--hard`
  matching. Never overwrite `value` that way; values are tunables that persist on purpose.
- **Give each workshop its own Grafana `container_name`.** Not the port: the workshops are
  meant to be run one at a time, so a single `GRAFANA_PORT` (3000) serves all of them.
  Container names are different — a name is global to the Docker daemon and is held even
  by a stopped container, so sharing one makes `up` fail with "container name already in
  use" when moving between workshops without a `docker compose down`. Named volumes need
  nothing: compose already prefixes them with the project directory name.

Within a workshop, most are flat — a `README.md` plus one `.sql` file. Only use subdirectories
when the file count genuinely demands it (20+ SQL steps, or one shipping Grafana dashboards).
When you do, keep it shallow and numbered so run order is unambiguous: `sql/01_…`, `grafana/`.

Every new workshop must be appended to the root [README.md](README.md) under
`## Available Workshops` as the next `### N.` entry: two to four sentences, a note on how it
sources data ("Self-generating data." / "downloads its own data"), then the bolded link line
`**[>> Go to the X Workshop](./Dir)**`.

## SQL house style

Files are read by humans in a terminal. Follow the established shape — see
[Hands-on-workshop-well-production-monitoring-psql.sql](TimeSeries-Workshop-Well-Production-Monitoring/Hands-on-workshop-well-production-monitoring-psql.sql)
as the reference implementation.

- **78-character banner rules** delimit every section:
  ```sql
  -- ============================================================================
  -- ## Section Title
  -- ============================================================================
  ```
  The file opens with `-- # Workshop Title`, a prose overview, then `-- ## Prerequisites` and
  `-- ## What You'll Learn`.
- **A reset block comes first**, annotated
  `-- (highlight and run this block to reset the workshop environment)`, using
  `DROP ... IF EXISTS ... CASCADE` in dependency order.
- **Explain the settings, not the syntax.** Every non-obvious option gets a comment block above
  it saying what it does *and why it matters for this workload*. The `tsdb.segmentby` comment
  should talk about the query pattern it serves, not restate the option name.
- **Annotate units and ranges** on every generated column: `-- psi`, `-- bbl/day equivalent`.
- **Paste expected output as comments** below interesting queries, so an attendee can tell
  whether their run worked.
- Use `RAISE NOTICE` in generators to report what was inserted.
- Keep to plain `psql`. `\set` / `\echo` / `\copy` are fine; avoid depending on psql variables
  for values an attendee is meant to tune — make them edit a literal or a config table, and say
  so in a comment. (An earlier workshop documented a `:history_days` variable that its SQL never
  actually used; don't repeat that.)

### Patterns that must be used

**Columnstore policy — always remove then add.** Declaring `tsdb.segmentby` / `tsdb.orderby` at
`CREATE TABLE` time *auto-creates* a default columnstore policy, so a later
`add_columnstore_policy` raises `ERROR 42710: policy already exists`:

```sql
CALL remove_columnstore_policy('my_hypertable', if_exists => true);
CALL add_columnstore_policy('my_hypertable', after => INTERVAL '7 days');
```

**Continuous aggregates — always state `materialized_only` explicitly** and always attach a
refresh policy:

```sql
CREATE MATERIALIZED VIEW my_cagg
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket('1 hour', time) AS bucket, ... ;

SELECT add_continuous_aggregate_policy('my_cagg',
  start_offset      => INTERVAL '3 hours',
  end_offset        => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour');
```

Real-time aggregation has been **off by default since TimescaleDB 2.13** — omitting the option
silently gives you a stale view. Keep `start_offset` ≤ any retention window on the source, or
refreshes will blank buckets whose source rows were already dropped.

**PostGIS.** Store `geography(Point, 4326)` for GPS-style global data; cast to `::geometry` only
for operations geography lacks. GiST-index every spatial column. Use `ST_DWithin` (index-assisted)
rather than filtering on `ST_Distance`.

## Documentation style

Workshop READMEs follow the shared skeleton: `## Overview` → `## What You'll Learn` →
`## Contents` → `## Prerequisites` → `## Data Structure` → `## Key Features Demonstrated` →
`## Getting Started` → `## Why TigerData for <domain>` (a `| Challenge | TigerData Solution |`
table) → `## License` → `## Acknowledgments`.

Tone is professional and concrete: name real numbers ("90%+ compression", "~172,800 rows"), use
tables for anything comparative, and explain the industry problem before the technology. Note
that existing files mix British and American spellings (`optimised`, `Centralised`) — match the
file you are editing rather than normalising across the repo.

When a workshop ships config files (compose, Grafana provisioning), inline them verbatim in the
README as well, so the workshop is followable without switching between files.

## Credentials and environment

**One `.env` at the repository root serves every workshop.** It is gitignored;
[.env.example](.env.example) at the root is the committed template. No workshop ships its own
`.env.example`, and none should: credentials are entered once no matter how many workshops an
attendee runs, and a second template is a second thing to drift.

Each `reset_demo.sh` resolves it as `$SCRIPT_DIR/../.env`, preferring a workshop-local `.env` if
one exists — the escape hatch for pointing a single workshop at a different service, or for using
a workshop directory after copying it out of the repo. Reuse these key names rather than inventing
new ones:

```
TIMESCALE_SERVICE_URL   PGHOST   PGPORT   PGDATABASE   PGUSER   PGPASSWORD   PGSSLMODE
```

A workshop needing an extra setting adds it to the root `.env.example` with a comment naming
the workshop. Namespace a variable only when two workshops genuinely need different values
at the same time — which Grafana's port does not, since these run one at a time.

Two traps, both verified:

- **`docker compose` reads `env_file:` and `--env-file` from different places.** `env_file:` puts
  variables in the *container* — which is what Grafana needs to interpolate `${PGHOST}` inside
  `datasources/datasource.yml`. It does **not** feed `${...}` substitutions in the compose file
  itself; those come from compose's own `--env-file` (or the shell). So a port variable set in the
  root `.env` is ignored unless you run `docker compose --env-file ../.env up -d`. Always give
  such variables a default in the compose file so it works either way.
- **SQL cannot read environment variables.** If a generator needs a tunable, put it in the
  `workshop_config` table the SQL reads, and have `.env.example` point at that table rather than
  implying the variable is wired up.

## .gitignore

Root `.gitignore` covers `.env`, `.venv/`, `__pycache__/`, `_results/`, `_temp_data/`, and
root-anchored `/*.csv` / `/*.zip`. A committed corpus inside a workshop directory is fine, but
**anything a workshop generates or downloads needs an explicit per-path entry** under the
"Workshop-generated / downloaded data" block.

## Third-party data

If a workshop pulls from an external API or dataset, record the source, its licence, and the
required attribution in the workshop README. Licence terms often dictate *where* attribution has
to appear, not merely that it exists. Attribution and redistribution terms are a legal question,
not a technical one — before publishing a workshop that redistributes third-party data or relies
on its licence terms, confirm the approach with Leah Aviram, General Counsel.
