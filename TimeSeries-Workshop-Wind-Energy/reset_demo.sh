#!/usr/bin/env bash
#
# reset_demo.sh — tear down and rebuild the PostGIS workshop demo data.
#
# Reads connection details from ./.env (the same file Grafana uses), drops the
# workshop's own tables, and re-runs every SQL step in order.
#
# This utility exists so a reset is one command. It does NOT generate any data —
# every row still comes from the SQL functions in sql and
# sql. Keeping generation entirely in SQL is a deliberate
# property of this workshop; this script only orchestrates psql.
#
#   ./reset_demo.sh                 # rebuild both parts (prompts first)
#   ./reset_demo.sh --days 90       # shallower history, much smaller and faster
#   ./reset_demo.sh --plants 12 --turbines-per-plant 4
#   ./reset_demo.sh --hard --yes    # also drop workshop_config and the roles
#   ./reset_demo.sh --help
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Connection settings come from the REPO-ROOT .env, shared by every workshop, so
# credentials are entered once however many workshops you run. A workshop-local
# .env still wins if one exists — that is the escape hatch for pointing a single
# workshop at a different service, or for using this directory on its own after
# copying it out of the repo.
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  ENV_FILE="$SCRIPT_DIR/.env"
else
  ENV_FILE="$REPO_ROOT/.env"
fi

HARD="no"
ASSUME_YES="no"
KEEP_TABLES="no"
SKIP_GEOJSON="no"
HISTORY_DAYS=""
PLANTS=""
TURBINES_PER_PLANT=""
TIERING="no"
JOBS=""            # parallel backfill workers; empty = one per detected CPU, max 4

# --------------------------------------------------------------------------
# Pretty output. Colour only when stdout is a terminal.
# --------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi
say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
ok()   { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
die()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

usage() {
  cat <<'EOF'
reset_demo.sh — tear down and rebuild the PostGIS workshop demo data

USAGE
  ./reset_demo.sh [options]

OPTIONS
  --days N         Depth of history to generate, in days. Default 730
                   (2 years). Together with num_plants this is the main control
                   over data volume and build time; everything else is small.

                   Scaling is linear in days x turbines. The script reads the
                   service's own memory and CPU before doing anything and prints
                   a volume projection, a build-time estimate and, only if the
                   combination is too large for THAT service, a warning.

                   Build throughput, measured on timescaledb-ha:pg17 in
                   cgroup-limited containers (16-turbine fleet, 90/360/730 days),
                   counting rows across both hypertables:

                     resources          total rows/s   730d default fleet
                     0.5 CPU /  2 GiB        21,400              ~5m 20s
                     1   CPU /  4 GiB        40,300              ~2m 50s
                     2   CPU /  8 GiB        54,600              ~2m 10s
                     4   CPU / 16 GiB        57,700              ~1m 40s

                   Note the flattening: 0.5->1 CPU nearly doubles throughput,
                   1->2 adds 35%, 2->4 adds only 6%. The backfill is a single
                   INSERT..SELECT in one backend, and sampled container CPU during
                   a build sits at a median 100% of a 200% ceiling — so beyond
                   about 2 CPU a core is simply idle. Buy CPU for memory headroom,
                   not for speed.
                   See the note on windowed refresh in 08_continuous_aggregates.sql.

                   Sets workshop_config.backfill_days, so it persists: later
                   runs without --days reuse it. Two years is the default
                   because it shows each region's seasonal cycle twice.
  --plants N       Number of wind plants, 1..36. Default 6 — one per region.
                   Plants are handed out round-robin across the six regions, so
                   6 gives one each, 12 gives two each, and so on. The site
                   catalogue holds 36 real sites (6 per region), which is the cap.
  --turbines-per-plant N
                   Turbines in each plant's grid, 1..100. Default 8.

                   These two multiply into total turbines, and total turbines
                   multiplies with --days into the row count. All three set
                   workshop_config keys and persist, so a later run without them
                   reuses whatever you last chose.

                   The script computes the resulting volume up front and warns
                   before it does anything if the combination is too large for the
                   service it is pointed at. The ceiling scales with the detected
                   memory, anchored on ~4M rows/hypertable per 8 GiB: ~3.4M is
                   comfortable on 8 GiB and ~6.8M is not, so 2 GiB tolerates about
                   1M and 16 GiB about 8M. Verified at the small end — 1.12M rows
                   on 0.5 CPU / 2 GiB completed with no OOM kill.
  --jobs N         Run the backfill as N concurrent workers over chunk-aligned
                   windows, 1..8. Defaults to one per detected CPU, capped at 4.

                   It works, but only because the chunks are pre-created first.
                   Creating a chunk takes ShareUpdateExclusiveLock on the parent
                   hypertable; PostgreSQL holds locks until commit and SUE
                   self-conflicts, so workers that create their own chunks hold the
                   parent for their whole transaction and serialise. Measured on 20
                   turbines x 730 days (1.4M rows/hypertable), 4 CPU:

                     workers create their own chunks   34.3s -> 31.2s   1.09x
                     chunks pre-created                34.3s ->  9.3s   3.67x

                   Without pre-creation: 3 of 4 backends on `Lock / relation`, CPU at
                   100% of a 400% ceiling. With it: all 4 RUNNING, zero waits, CPU at
                   384%. Whole-build wall time at the 730-day default: 40s serial,
                   28s at 2 jobs, 24s at 4 — lower than 3.67x because the aggregate
                   fill and later steps are still serial.

                   Capped at 4 because a single INSERT..SELECT cannot use parallel
                   query at all (PostgreSQL disables it for any data-modifying
                   statement), so throughput comes from connections, and WAL is the
                   next shared ceiling. --jobs 1 forces the serial path.

                   And it falls to 1 on small services ON PURPOSE. Because the work
                   is CPU-bound in one backend, extra connections need spare CORES to
                   pay for themselves, and below 2 CPU they cost time. Measured, same
                   563,588 rows per hypertable, whole build:

                     0.5 CPU   50s serial   68s at 2 jobs   +36%
                     1   CPU   21s serial   24s at 2 jobs   +14%
                                            30s at 4 jobs   +43%
                     4   CPU   20s serial   15s at 2 jobs   -25%
                                            13s at 4 jobs   -35%

                   So a sequential backfill on a fresh 0.5- or 1-CPU service is the
                   fastest setting available, not a missing optimisation. The lever
                   there is a core, not concurrency.
  --tiering        Apply the object-storage tiering policies in step 14.
                   OFF by default, and deliberately so: tiering ships data to an
                   object store, which is billable, and while removing a policy
                   is easy, chunks already uploaded come back only one at a time
                   via untier_chunk(). At the 730-day default this makes ~548
                   days of raw telemetry eligible immediately.

                   Requires tiered storage enabled for the service (Console >
                   Explorer > Data tiering). Without it, step 14 reports what it
                   would do and skips — it is not a workshop prerequisite.

                   Also sets timescaledb.enable_tiered_reads ON at the DATABASE
                   level, without which tiered data silently disappears from
                   every query and dashboard.
  --hard           Also drop workshop_config (so tunables return to their
                   defaults). This workshop creates no roles, so none are dropped.
                   Without this, config values you changed are PRESERVED.
  --keep-tables    Skip the explicit DROP phase and just re-run the SQL. Each
                   part's 02_schema.sql drops its own objects anyway, so this is
                   usually equivalent and slightly faster.
  --no-geojson     Skip regenerating grafana-geojson/wind-regions.geojson.
                   Regenerate it whenever the fleet shape changes, or the map
                   overlay will show the old footprints.
  --yes, -y        Do not prompt for confirmation.
  --help, -h       Show this.

ENVIRONMENT
  Read from ./.env next to this script. Either set the PG* variables:
      PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PGSSLMODE
  or provide a single connection string:
      TIMESCALE_SERVICE_URL=postgres://user:pw@host:port/db?sslmode=require

NOTES
  This never runs DROP SCHEMA public CASCADE. That would destroy TimescaleDB
  itself, which installs its objects into the public schema.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --days)        HISTORY_DAYS="${2:-}"; shift 2 ;;
    --days=*)      HISTORY_DAYS="${1#*=}"; shift ;;
    --plants)      PLANTS="${2:-}"; shift 2 ;;
    --plants=*)    PLANTS="${1#*=}"; shift ;;
    --turbines-per-plant)   TURBINES_PER_PLANT="${2:-}"; shift 2 ;;
    --turbines-per-plant=*) TURBINES_PER_PLANT="${1#*=}"; shift ;;
    --jobs)                 JOBS="${2:-}"; shift 2 ;;
    --jobs=*)               JOBS="${1#*=}"; shift ;;
    --tiering)     TIERING="yes"; shift ;;
    --hard)        HARD="yes"; shift ;;
    --keep-tables) KEEP_TABLES="yes"; shift ;;
    --no-geojson)  SKIP_GEOJSON="yes"; shift ;;
    -y|--yes)      ASSUME_YES="yes"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "Unknown option: $1  (try --help)" ;;
  esac
done


if [ -n "$HISTORY_DAYS" ]; then
  case "$HISTORY_DAYS" in
    ''|*[!0-9]*) die "--days must be a whole number of days (got '$HISTORY_DAYS')" ;;
  esac
  [ "$HISTORY_DAYS" -ge 1 ] || die "--days must be at least 1"
  # Retention is 3 years; generating more history than retention keeps means the
  # retention job silently deletes the excess.
  if [ "$HISTORY_DAYS" -gt 1095 ]; then
    die "--days $HISTORY_DAYS exceeds the 3-year retention policy in
sql/09_compression_retention.sql, so the oldest data would be
dropped as soon as the retention job ran. Raise the policy first, then retry."
  fi
fi

if [ -n "$PLANTS" ]; then
  case "$PLANTS" in ''|*[!0-9]*) die "--plants must be a whole number (got '$PLANTS')" ;; esac
  { [ "$PLANTS" -ge 1 ] && [ "$PLANTS" -le 36 ]; } || die \
"--plants must be between 1 and 36. The site catalogue in
sql/04_seed_turbines.sql holds 36 real development sites, six per
region, and a plant is named for the site it occupies."
fi

if [ -n "$JOBS" ]; then
  case "$JOBS" in
    ''|*[!0-9]*) die "--jobs must be a whole number (got '$JOBS')" ;;
  esac
  { [ "$JOBS" -ge 1 ] && [ "$JOBS" -le 8 ]; } || die "--jobs must be between 1 and 8."
fi
if [ -n "$TURBINES_PER_PLANT" ]; then
  case "$TURBINES_PER_PLANT" in
    ''|*[!0-9]*) die "--turbines-per-plant must be a whole number (got '$TURBINES_PER_PLANT')" ;;
  esac
  { [ "$TURBINES_PER_PLANT" -ge 1 ] && [ "$TURBINES_PER_PLANT" -le 100 ]; } || die \
"--turbines-per-plant must be between 1 and 100."
fi

# --------------------------------------------------------------------------
# Load .env and work out how to connect
# --------------------------------------------------------------------------
command -v psql >/dev/null 2>&1 || die "psql not found on PATH.
Install it: https://www.tigerdata.com/blog/how-to-install-psql-on-mac-ubuntu-debian-windows"

[ -f "$ENV_FILE" ] || die "No .env found at $ENV_FILE
Copy the template and fill in your Tiger Cloud connection details:
  cp '$REPO_ROOT/.env.example' '$REPO_ROOT/.env'"

# `set -a` exports everything the file defines, which is what psql reads.
# Note this is a shell source, so .env must contain plain KEY=value lines.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

CONNINFO=""
if [ -n "${PGHOST:-}" ] && [ -n "${PGDATABASE:-}" ]; then
  : # psql picks the PG* variables up from the environment
elif [ -n "${TIMESCALE_SERVICE_URL:-}" ]; then
  CONNINFO="$TIMESCALE_SERVICE_URL"
else
  die "Neither PGHOST/PGDATABASE nor TIMESCALE_SERVICE_URL is set in $ENV_FILE"
fi

# Single place that knows how to invoke psql, so the conninfo branch is handled once.
psql_run() {
  if [ -n "$CONNINFO" ]; then psql "$CONNINFO" "$@"; else psql "$@"; fi
}
psql_q()  { psql_run -X -q -v ON_ERROR_STOP=1 "$@"; }

# Verification runs AFTER step 13 hands the columnstore policies back to the
# scheduler, so those background jobs are actively working through a backlog of
# chunks while these queries read the same relations. That deadlocks — and it
# lands on statements as innocent as `SELECT COUNT(*) FROM wind_measurements`:
#
#   ERROR:  deadlock detected
#   DETAIL: Process 399 waits for AccessShareLock on relation 196373;
#           blocked by process 362.
#
# A deadlock is transient by definition: one side is chosen as victim and the
# other completes. Retrying is the correct response, not a workaround. Three
# attempts with a short pause; anything still failing after that is a real error.
psql_retry() {
  attempt=1
  while :; do
    if out=$(psql_run -X -v ON_ERROR_STOP=1 "$@" 2>&1); then
      printf '%s\n' "$out"; return 0
    fi
    # Retry the two transient catalog/lock races that a concurrent background job
    # can produce. `cache lookup failed for relation <oid>` is the same shape of
    # problem as a deadlock: a columnstore policy converting a chunk while this
    # statement reads or drops the same relation. Seen twice while developing,
    # both times on a database that had also been manipulated out of band, and not
    # reproducible across five clean back-to-back rebuilds at 90 and 730 days — so
    # this is defensive rather than a known defect.
    if [ "$attempt" -ge 3 ] || ! printf '%s' "$out" | grep -qiE 'deadlock detected|cache lookup failed'; then
      printf '%s\n' "$out" >&2; return 1
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
}
psql_val() {
  attempt=1
  while :; do
    if out=$(psql_run -X -tA -v ON_ERROR_STOP=1 -c "$1" 2>&1); then
      printf '%s' "$out"; return 0
    fi
    # Same two transient races as psql_retry above.
    if [ "$attempt" -ge 3 ] || ! printf '%s' "$out" | grep -qiE 'deadlock detected|cache lookup failed'; then
      printf '%s' "$out" >&2; return 1
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
}

# --------------------------------------------------------------------------
# Show the target and confirm. Destroying the wrong database is easy.
# --------------------------------------------------------------------------
head1 "Target"
if [ -n "$CONNINFO" ]; then
  # Redact the password out of the URL before printing it.
  say "  connection : $(printf '%s' "$CONNINFO" | sed -E 's#(//[^:]+:)[^@]+@#\1****@#')"
else
  say "  host       : ${PGHOST}:${PGPORT:-5432}"
  say "  database   : ${PGDATABASE}"
  say "  user       : ${PGUSER:-$(id -un)}"
  say "  sslmode    : ${PGSSLMODE:-<default>}"
fi

SERVER_ID="$(psql_val "SELECT current_database() || ' on ' || COALESCE(inet_server_addr()::text, 'local')" 2>/dev/null)" \
  || die "Could not connect. Check the values in $ENV_FILE.
For a Tiger Cloud service PGSSLMODE must be 'require'."
ok "  connected  : $SERVER_ID"


# Project the volume from the values that will actually be in effect: the
# flags where given, otherwise whatever is already in workshop_config, otherwise
# the built-in defaults (workshop_config may not exist yet on a fresh database).
cfg_or() {  # cfg_or <key> <fallback>
  v="$(psql_val "SELECT value FROM workshop_config WHERE key='$1'" 2>/dev/null || true)"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}
EFF_DAYS="${HISTORY_DAYS:-$(cfg_or backfill_days 730)}"
EFF_PLANTS="${PLANTS:-$(cfg_or num_plants 6)}"
EFF_TPP="${TURBINES_PER_PLANT:-$(cfg_or turbines_per_plant 8)}"
EFF_STEP="$(cfg_or wind_step_minutes 15)"

EFF_TURBINES=$(( EFF_PLANTS * EFF_TPP ))
EFF_ROWS=$(( EFF_TURBINES * (EFF_DAYS * 1440 / EFF_STEP + 1) ))

say "  fleet      : ${EFF_PLANTS} plant(s) x ${EFF_TPP} turbines = ${EFF_TURBINES} turbines"
say "  history    : ${EFF_DAYS} days at ${EFF_STEP}-minute resolution"
printf '  volume     : ~%s rows in EACH of two hypertables\n' \
  "$(printf '%d' "$EFF_ROWS" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta')"

# ------------------------------------------------------------------------
# Size the warning to THIS service, not to a fixed guess.
#
# Tiger Cloud sets shared_buffers to 25% of RAM and effective_cache_size to
# 75%, so their sum is the machine's memory. Compute is provisioned at a
# constant 4 GiB per CPU across every plan (0.5/2, 1/4, 2/8, 4/16, 8/32 ...),
# which is what lets CPU be inferred from memory. max_parallel_workers is a
# useful cross-check on a real service — it matches the CPU count there — but
# NOT when self-hosting, where it stays at PostgreSQL's default of 8
# regardless of cores, so it is only ever used to lower the estimate.
RAM_MB="$(psql_val "SELECT ROUND((pg_size_bytes(current_setting('shared_buffers'))
                                + pg_size_bytes(current_setting('effective_cache_size')))
                               / 1048576.0)" 2>/dev/null || echo 0)"
[ -z "$RAM_MB" ] && RAM_MB=0
MPW="$(psql_val "SELECT current_setting('max_parallel_workers')" 2>/dev/null || echo 0)"

if [ "$RAM_MB" -gt 0 ]; then
  # CPU in tenths, so half-CPU plans survive integer arithmetic.
  CPU_TENTHS=$(( RAM_MB * 10 / 4096 ))
  [ "$CPU_TENTHS" -lt 5 ] && CPU_TENTHS=5
  if [ "${MPW:-0}" -gt 0 ] && [ "$MPW" -lt 8 ] && [ $(( MPW * 10 )) -lt "$CPU_TENTHS" ]; then
    CPU_TENTHS=$(( MPW * 10 ))          # a real service reporting fewer cores
  fi
  # Round rather than truncate: 7932 MB is an 8 GiB service, not a 7 GiB one.
  RAM_GIB=$(( (RAM_MB + 512) / 1024 ))
  say "  service    : ~${RAM_GIB} GiB RAM, ~$(( CPU_TENTHS / 10 )).$(( CPU_TENTHS % 10 )) CPU (inferred from shared_buffers + effective_cache_size)"

  # Marginal build rate for BOTH hypertables together, since the run generates
  # the same row count into each. All but the last line MEASURED on
  # timescaledb-ha:pg17 in cgroup-limited containers, 16-turbine fleet over
  # 90/360/730 days:
  #     0.5 CPU /  2 GiB  ~21,400 total rows/s   fixed overhead ~3 s
  #     1   CPU /  4 GiB  ~40,300 total rows/s
  #     2   CPU /  8 GiB  ~54,600 total rows/s   fixed overhead ~1 s
  #     4   CPU / 16 GiB  ~57,700 total rows/s
  #
  # Note the shape: 0.5 -> 1 CPU nearly doubles throughput, 1 -> 2 adds 35%,
  # and 2 -> 4 adds only 6%. The curve is flat past about 2 CPU because the
  # backfill is a single INSERT..SELECT in ONE backend — sampled container CPU
  # during a build sits at a median of 100% of a 200% ceiling, so a second core
  # is already idle. Buying CPU beyond 2 does almost nothing for build time;
  # it buys MEMORY headroom, which is what the row ceiling below is about.
  case "$CPU_TENTHS" in
    5)             RATE=21400 ;;
    6|7|8|9|10)    RATE=40300 ;;
    1[1-9]|20)     RATE=54600 ;;
    2[1-9]|3[0-9]) RATE=57700 ;;
    *)             RATE=60000 ;;   # extrapolated flat; not measured above 4 CPU
  esac
  # Parallel workers, defaulting to one per whole detected CPU (capped at 4).
  #
  # This pays off ONLY because parallel_backfill() pre-creates the chunks first.
  # Measured on 20 turbines x 730 days (1.4M rows/hypertable), 4 CPU:
  #
  #   workers create their own chunks   34.3s serial -> 31.2s at 4 jobs  1.09x
  #   chunks pre-created                34.3s serial ->  9.3s at 4 jobs  3.67x
  #
  # Creating a chunk takes ShareUpdateExclusiveLock on the parent, PostgreSQL holds
  # locks until commit, and SUE self-conflicts — so a worker holds it for its whole
  # transaction and the others queue. Sampled without pre-creation: 3 of 4 backends
  # on `Lock / relation`, every ungranted lock `ShareUpdateExclusiveLock on
  # power_generation`, CPU pinned at 100% of a 400% ceiling. With pre-creation: all
  # 4 RUNNING, zero waits, CPU 384% of 400%.
  #
  # NOT a read-side problem: the generator reads turbines/plants/regions/
  # turbine_neighbors/turbine_faults on every row, all AccessShareLock, all four
  # workers holding all five at once and all granted.
  #
  # Capped at 4: a single INSERT..SELECT cannot use parallel query at all, since
  # PostgreSQL disables it for any data-modifying statement, so throughput has to
  # come from connections — and WAL is the next shared ceiling.
  if [ -n "$JOBS" ]; then
    EFF_JOBS="$JOBS"
  else
    EFF_JOBS=$(( CPU_TENTHS / 10 ))
    [ "$EFF_JOBS" -lt 1 ] && EFF_JOBS=1
    [ "$EFF_JOBS" -gt 4 ] && EFF_JOBS=4
  fi


  # Both hypertables are generated, so the row count in flight is 2 x EFF_ROWS.
  EST_SECS=$(( (EFF_ROWS * 2) / RATE + 5 ))
  # Measured speed-up from the pre-created-chunk fan-out. Sub-linear because WAL
  # and the buffer pool are still one shared resource.
  case "$EFF_JOBS" in
    1) : ;;
    2) EST_SECS=$(( EST_SECS * 100 / 190 )) ;;
    3) EST_SECS=$(( EST_SECS * 100 / 280 )) ;;
    *) EST_SECS=$(( EST_SECS * 100 / 360 )) ;;
  esac
  if [ "$EFF_JOBS" -gt 1 ]; then
    say "  backfill   : ${EFF_JOBS} parallel workers over chunk-aligned windows"
    say "               (chunks pre-created first — that is what lets them run concurrently)"
  elif [ -n "$JOBS" ]; then
    say "  backfill   : serial (--jobs 1)"
  else
    # Say WHY, because "serial" on its own reads like a missing feature. It is not:
    # the backfill is CPU-bound in one backend, so extra connections need extra CORES
    # to run on. Measured, same 563,588 rows per hypertable, whole build:
    #   0.5 CPU   50s serial   68s at 2 jobs   (+36%)
    #   1   CPU   21s serial   24s at 2 jobs   (+14%)   30s at 4 jobs  (+43%)
    #   4   CPU   20s serial   15s at 2 jobs   (-25%)   13s at 4 jobs  (-35%)
    # Below 2 CPU concurrency is a straight loss, so one worker is the right answer.
    say "  backfill   : serial — only ~$(( CPU_TENTHS / 10 )).$(( CPU_TENTHS % 10 )) CPU detected"
    say "               (extra workers measured SLOWER below 2 CPU; --jobs N overrides)"
  fi
  if [ "$EST_SECS" -lt 60 ]; then
    say "  build est. : ~${EST_SECS}s"
  else
    say "  build est. : ~$(( EST_SECS / 60 ))m $(( EST_SECS % 60 ))s (rough; measured locally, a cloud vCPU may be slower)"
  fi

  # The initial continuous-aggregate fill is the memory-hungry part, and past a
  # certain size it is OOM-killed — which restarts the instance, not just this
  # script. Anchor: ~3.4M rows/hypertable completes on 8 GiB and ~6.8M does not,
  # so warn from half the observed ceiling and scale it with RAM. Confirmed at
  # the small end: 1.12M rows on 0.5 CPU / 2 GiB completed with no OOM kill.
  SAFE_ROWS=$(( 4000000 * RAM_MB / 8192 ))
  commas() { printf '%d' "$1" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'; }
  if [ "$EFF_ROWS" -gt "$SAFE_ROWS" ]; then
    # Snap the recommendation to a real plan size rather than inventing one:
    # Tiger Cloud sells 2/4/8/16/32 GiB at 0.5/1/2/4/8 CPU.
    NEED_GIB=$(( EFF_ROWS * 8 / 4000000 + 1 ))
    for p in 2 4 8 16 32; do PLAN_GIB=$p; [ "$p" -ge "$NEED_GIB" ] && break; done
    PLAN_CPU_TENTHS=$(( PLAN_GIB * 10 / 4 ))
    warn "  WARNING    : ~$(commas "$EFF_ROWS") rows/hypertable is above the ~$(commas "$SAFE_ROWS") that"
    warn "               ${RAM_GIB} GiB is sized for. The first continuous-aggregate fill can"
    warn "               be OOM-killed past that, which restarts the database — it does"
    warn "               not just fail this script."
    warn "               Either lower --days / --plants / --turbines-per-plant, or"
    warn "               resize to ${PLAN_GIB} GiB / $(( PLAN_CPU_TENTHS / 10 )).$(( PLAN_CPU_TENTHS % 10 )) CPU. Resize for the MEMORY, not the"
    warn "               speed: build time is flat past ~2 CPU, so that would still"
    warn "               take roughly $(( ((EFF_ROWS * 2) / 54600 + 5) / 60 ))m against the ~$(( EST_SECS / 60 ))m estimated here."
  else
    ok   "  headroom   : fits — ${RAM_GIB} GiB is sized for ~$(commas "$SAFE_ROWS") rows/hypertable"
  fi
else
  # Could not read the settings — fall back to the fixed 8 GiB assumption.
  if [ "$EFF_ROWS" -gt 4000000 ]; then
    warn "  WARNING    : that is a large initial load, and the service's size could"
    warn "               not be read. Above roughly 4,000,000 rows per hypertable the"
    warn "               continuous-aggregate fill has been OOM-killed on 8 GiB."
  fi
fi
say "  tiering    : $([ "$TIERING" = yes ] \
      && echo 'ON — step 14 will tier data to object storage (billable)' \
      || echo 'off (pass --tiering to enable)')"
say "  drop phase : $([ "$KEEP_TABLES" = yes ] && echo 'skipped (--keep-tables)' || echo 'yes')"
say "  hard reset : $HARD$([ "$HARD" = yes ] && echo '  (workshop_config + roles will be dropped)' || echo '')"

if [ "$ASSUME_YES" != "yes" ]; then
  printf '\n%sThis DESTROYS the workshop tables listed above and rebuilds them. Continue? [y/N] %s' \
    "$C_YELLOW" "$C_RESET"
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) say "Aborted."; exit 0 ;; esac
fi

START_TS=$(date +%s)

# --------------------------------------------------------------------------
# Drop phase
# --------------------------------------------------------------------------
# Explicit table lists, never DROP SCHEMA. CASCADE carries the continuous
# aggregates and views away with their parent tables.
#
# Listed roughly child-first for readability; CASCADE makes the order irrelevant.
P1_TABLES="power_generation, wind_measurements, turbine_faults, turbine_neighbors, turbines, plants, regions"

if [ "$KEEP_TABLES" != "yes" ]; then
  head1 "Dropping workshop objects"
  # psql_retry, not psql_q: this is the statement most exposed to a background
  # columnstore job working through a backlog left by the previous run.
  psql_retry -c "DROP TABLE IF EXISTS $P1_TABLES CASCADE;" >/dev/null
  ok "  Wind Energy tables dropped (aggregates and views followed via CASCADE)"

  if [ "$HARD" = "yes" ]; then
    # workshop_config and the cfg*() helpers are SHARED with the Fleet Tracking
    # workshop: both create the table with IF NOT EXISTS and seed only their own
    # keys, which is what lets either run first against the same database.
    # So a hard reset here must remove only THIS workshop's keys — matched on the
    # 'Wind Energy: ' description prefix that 01_extensions.sql writes, so a key added
    # later is classified without anyone maintaining a list — and drop the
    # table only once nothing is left in it. Dropping it outright would strip the
    # other workshop's tunables and silently reset them to defaults on its next
    # run — and CASCADE would take the cfg*() functions it depends on with it.
    psql_q -c "DELETE FROM workshop_config WHERE description LIKE 'Wind Energy: %';" 2>/dev/null || true
    LEFT="$(psql_val "SELECT COUNT(*) FROM workshop_config" 2>/dev/null || echo 0)"
    if [ "${LEFT:-0}" = "0" ]; then
      psql_q -c "DROP TABLE IF EXISTS workshop_config CASCADE;" 2>/dev/null || true
      ok "  workshop_config dropped — it held only this workshop's keys"
    else
      ok "  this workshop's workshop_config keys removed ($LEFT key(s) left for the other workshop)"
    fi
    # NOTE: this workshop creates no roles, so --hard drops none. The split from
    # the combined PostGIS workshop left a block here that dropped driver_app and
    # fleet_analyst — roles belonging to the Fleet Tracking workshop. On a shared
    # service that made this workshop's --hard silently destroy another's tenancy
    # setup, which is exactly what the workshop_config prefix matching above exists
    # to prevent. A workshop must only ever tear down objects it created.
  fi
fi

# --------------------------------------------------------------------------
# Rebuild phase
# --------------------------------------------------------------------------
# Run every .sql in a part, in filename order, from `start_prefix` onward.
# Passing an empty prefix runs all of them.
run_part_from() {
  part_dir="$1"; part_label="$2"; start_prefix="$3"
  [ -d "$part_dir/sql" ] || die "Missing directory: $part_dir/sql"
  started="no"
  [ -z "$start_prefix" ] && started="yes"
  for f in "$part_dir"/sql/*.sql; do
    base="$(basename "$f")"
    if [ "$started" = "no" ]; then
      case "$base" in "$start_prefix"*) started="yes" ;; *) continue ;; esac
    fi
    case "$base" in 07_backfill_historical.sql) parallel_backfill ;; esac
    printf '  %-44s' "$base"
    if out=$(psql_q -f "$f" 2>&1); then
      ok "ok"
    else
      printf '%sFAILED%s\n' "$C_RED" "$C_RESET"
      printf '%s\n' "$out" | grep -iE 'ERROR|DETAIL|HINT' | head -8 | sed 's/^/      /'
      die "Stopped at $base. Nothing after it has run."
    fi
  done
}

# --------------------------------------------------------------------------
# Parallel backfill. ORCHESTRATION ONLY: every timestamp comes from
# backfill_wind_plan() in the database, which aligns the windows to the real
# chunk interval so no two workers ever write the same chunk. This script never
# computes a boundary, and deleting it would not change a single generated value
# — backfill_wind() alone produces byte-identical history, just serially.
#
# Worth knowing why this exists: the backfill is one INSERT..SELECT in a single
# backend, so it saturates about one core. Sampled container CPU during a serial
# build sits at a median 100% of a 200% ceiling on a 2-CPU service, and going
# from 2 to 4 CPU speeds a serial build by only 6%. The idle core is the whole
# point of running the windows concurrently.
# --------------------------------------------------------------------------
parallel_backfill() {
  [ "${EFF_JOBS:-1}" -le 1 ] && return 0

  # PRE-CREATE THE CHUNKS FIRST. This is the whole reason the fan-out pays off:
  # creating a chunk takes ShareUpdateExclusiveLock on the parent hypertable, held
  # until commit, and SUE self-conflicts — so workers creating their own chunks
  # serialise almost completely (1.09x). One cheap serial pass here and they never
  # take that lock at all (3.67x on 4 CPU).
  printf '  %-44s' "pre-create chunks"
  if psql_q -c "SELECT precreate_wind_chunks(NULL);" >/dev/null 2>&1; then
    ok "ok"
  else
    printf '%sFAILED%s\n' "$C_RED" "$C_RESET"
    die "Could not pre-create chunks. Re-run with --jobs 1 for the serial path."
  fi

  plan="$(psql_val "SELECT string_agg(worker || '|' || win_from || '|' || win_to, E'\n' ORDER BY worker)
                      FROM backfill_wind_plan(NULL, ${EFF_JOBS})")" || return 1
  [ -z "$plan" ] && return 1

  n="$(printf '%s\n' "$plan" | grep -c '|')"
  printf '  %-44s' "backfill x ${n} (parallel)"

  tmpd="$(mktemp -d)"
  pids=""
  while IFS='|' read -r w wfrom wto; do
    [ -z "$w" ] && continue
    ( psql_q -c "SELECT backfill_wind_window('$wfrom'::timestamptz, '$wto'::timestamptz);" \
        >"$tmpd/w$w.log" 2>&1; echo $? >"$tmpd/w$w.rc" ) &
    pids="$pids $!"
  done <<PLANEOF
$plan
PLANEOF

  for p in $pids; do wait "$p" 2>/dev/null || true; done

  bad=0
  for rc in "$tmpd"/*.rc; do
    [ -f "$rc" ] || continue
    [ "$(cat "$rc")" = "0" ] || bad=1
  done
  if [ "$bad" -ne 0 ]; then
    printf '%sFAILED%s\n' "$C_RED" "$C_RESET"
    for l in "$tmpd"/*.log; do
      grep -iE 'ERROR|DETAIL|HINT' "$l" 2>/dev/null | head -4 | sed 's/^/      /'
    done
    rm -rf "$tmpd"
    die "Parallel backfill failed. Re-run with --jobs 1 for the serial path."
  fi
  ok "ok"
  # Step 07 still runs next: its generation call finds every batch already
  # present and skips it, so it contributes only its verification queries.
  rm -rf "$tmpd"
}


run_part() {
  part_dir="$1"; part_label="$2"
  head1 "$part_label"
  [ -d "$part_dir/sql" ] || die "Missing directory: $part_dir/sql"
  for f in "$part_dir"/sql/*.sql; do
    case "$(basename "$f")" in 07_backfill_historical.sql) parallel_backfill ;; esac
    printf '  %-44s' "$(basename "$f")"
    if out=$(psql_q -f "$f" 2>&1); then
      ok "ok"
    else
      printf '%sFAILED%s\n' "$C_RED" "$C_RESET"
      printf '%s\n' "$out" | grep -iE 'ERROR|DETAIL|HINT' | head -8 | sed 's/^/      /'
      die "Stopped at $(basename "$f"). Nothing after it has run."
    fi
  done
}

# The tuning flags have to land AFTER 01_extensions.sql creates workshop_config
# and BEFORE 04_seed_turbines.sql / 07_backfill_historical.sql read it. So run
# 01 on its own, apply the overrides, then let the rest of the part follow.
if [ -n "$HISTORY_DAYS" ] || [ -n "$PLANTS" ] || [ -n "$TURBINES_PER_PLANT" ] \
   || [ "$TIERING" = "yes" ]; then
  head1 "Wind Energy"
  printf '  %-44s' "01_extensions.sql"
  if psql_q -f "$SCRIPT_DIR/sql/01_extensions.sql" >/dev/null 2>&1; then
    ok "ok"
  else
    die "01_extensions.sql failed; run it by hand to see why."
  fi
  set_cfg() {  # set_cfg <key> <value>
    psql_q -c "UPDATE workshop_config SET value = '$2' WHERE key = '$1';"
    ok "  $1 set to $2"
  }
  [ -n "$HISTORY_DAYS" ]       && set_cfg backfill_days      "$HISTORY_DAYS"
  [ -n "$PLANTS" ]             && set_cfg num_plants         "$PLANTS"
  [ -n "$TURBINES_PER_PLANT" ] && set_cfg turbines_per_plant "$TURBINES_PER_PLANT"
  [ "$TIERING" = "yes" ]       && set_cfg enable_tiering     "true"
  run_part_from "$SCRIPT_DIR" "Wind Energy" "02_"
else
  run_part "$SCRIPT_DIR" "Wind Energy"
fi


# --------------------------------------------------------------------------
# Regenerate the region footprints used by the Grafana map overlay
# --------------------------------------------------------------------------
GEOJSON="$SCRIPT_DIR/grafana-geojson/wind-regions.geojson"
head1 "Region footprints for the map"
# Derived from the CONVEX HULL of each region's turbines, buffered 60 km — so it
# tracks the fleet. Change num_plants and this file must be regenerated or the
# overlay keeps showing the old territory.
if mkdir -p "$(dirname "$GEOJSON")" && psql_run -X -tA -v ON_ERROR_STOP=1 \
     -c "SELECT jsonb_pretty(jsonb_build_object(
           'type','FeatureCollection',
           'features', jsonb_agg(jsonb_build_object(
             'type','Feature',
             'properties', jsonb_build_object(
               'region_name', f.region_name, 'country', f.country,
               'prevailing_wind_deg', f.prevailing_wind_deg,
               'is_offshore', f.is_offshore, 'plants', f.plants,
               'turbines', f.turbines, 'nameplate_mw', f.nameplate_mw),
             'geometry', ST_AsGeoJSON(ST_Simplify(f.footprint::geometry, 0.02))::jsonb)
             ORDER BY f.region_name)))
         FROM (
           SELECT r.region_name, r.country, r.prevailing_wind_deg, r.is_offshore,
                  COUNT(DISTINCT p.plant_id) AS plants,
                  COUNT(t.turbine_id)        AS turbines,
                  ROUND((SUM(p.rated_capacity_kw)/1000.0)::numeric,1) AS nameplate_mw,
                  ST_Buffer(ST_ConvexHull(ST_Collect(t.location::geometry))::geography, 60000)
                    AS footprint
             FROM regions r
             JOIN plants   p ON p.region_name = r.region_name
             JOIN turbines t ON t.plant_id    = p.plant_id
            GROUP BY r.region_name, r.country, r.prevailing_wind_deg, r.is_offshore) f;" \
     > "$GEOJSON".tmp 2>/dev/null && [ -s "$GEOJSON".tmp ]; then
  mv "$GEOJSON".tmp "$GEOJSON"
  ok "  wrote $(basename "$GEOJSON") ($(wc -c < "$GEOJSON" | tr -d ' ') bytes)"
  say "  ${C_DIM}Grafana picks it up on its own; no restart needed.${C_RESET}"
else
  rm -f "$GEOJSON".tmp
  warn "  could not regenerate footprints — the map will show the previous ones"
fi

# --------------------------------------------------------------------------
# Verify
# --------------------------------------------------------------------------
head1 "Verification"

# Counted for this workshop only.
# UNION ALL also does not guarantee output order once the planner parallelises
# the branches, so number the rows and sort explicitly.
psql_retry <<'SQL'
\pset footer off
WITH counts(n, object, rows, expected) AS (
          SELECT 1, 'regions',           COUNT(*)::text, '6'                  FROM regions
UNION ALL SELECT 2, 'plants',            COUNT(*)::text,
     'num_plants (' || cfg_int('num_plants') || ')'                            FROM plants
UNION ALL SELECT 3, 'turbines',          COUNT(*)::text,
     (cfg_int('num_plants') * cfg_int('turbines_per_plant')) || ' + 4 (step 12)' FROM turbines
UNION ALL SELECT 4, 'turbine_faults',    COUNT(*)::text, '~18'                FROM turbine_faults
UNION ALL SELECT 5, 'turbine_neighbors', COUNT(*)::text, 'varies with layout'  FROM turbine_neighbors
-- Derived from workshop_config, not hardcoded, because --days changes it:
-- turbines x (1 + days x 1440 / step_minutes). Approximate because step 12's
-- four extra turbines are backfilled over a shorter window than the rest.
UNION ALL SELECT 6, 'wind_measurements', COUNT(*)::text,
     '~' || to_char((SELECT COUNT(*) FROM turbines)
                    * (1 + (cfg_int('backfill_days')::BIGINT * 1440)
                           / GREATEST(1, cfg_int('wind_step_minutes'))),
                    'FM999,999,999')                                         FROM wind_measurements
UNION ALL SELECT 7, 'power_generation',  COUNT(*)::text,
     '~' || to_char((SELECT COUNT(*) FROM turbines)
                    * (1 + (cfg_int('backfill_days')::BIGINT * 1440)
                           / GREATEST(1, cfg_int('wind_step_minutes'))),
                    'FM999,999,999')                                         FROM power_generation
)
SELECT object, rows, expected FROM counts ORDER BY n;
SQL


# Structural assertions — these are the ones that actually matter.
BAD=0

UNPOLICIED=$(psql_val "SELECT COUNT(*) FROM timescaledb_information.continuous_aggregates ca
  WHERE NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs j
    WHERE j.proc_name='policy_refresh_continuous_aggregate'
      AND j.hypertable_schema=ca.view_schema AND j.hypertable_name=ca.view_name);")
if [ "$UNPOLICIED" = "0" ]; then ok "  every continuous aggregate has a refresh policy"
else warn "  $UNPOLICIED aggregate(s) have NO refresh policy"; BAD=1; fi

ORPHANS=$(psql_val "SELECT COUNT(*) FROM power_generation p
  WHERE NOT EXISTS (SELECT 1 FROM turbines t WHERE t.turbine_id = p.turbine_id);")
if [ "$ORPHANS" = "0" ]; then ok "  no telemetry for unknown turbines"
else warn "  $ORPHANS orphaned telemetry rows"; BAD=1; fi

# The hourly aggregate must account for EVERY raw row. This catches the failure that
# nothing else here would: a refresh whose upper bound lands inside an open bucket
# materialises that whole bucket and pushes the watermark past the wall clock, so rows
# written into the bucket afterwards are neither materialised nor picked up by real-time
# aggregation. It showed up as exactly one missing row per turbine added in step 12.
UNCOUNTED=$(psql_val "SELECT (SELECT COALESCE(SUM(readings),0) FROM cagg_turbine_power_hourly)
                           - (SELECT COUNT(*) FROM power_generation);")
if [ "$UNCOUNTED" = "0" ]; then ok "  hourly aggregate accounts for every raw telemetry row"
else warn "  hourly aggregate is off by $UNCOUNTED rows against power_generation"; BAD=1; fi

# One row out means one plant disagrees, so count lines rather than read a value.
MISMATCH=$(psql_val "SELECT p.plant_id FROM plants p
  LEFT JOIN turbines t ON t.plant_id = p.plant_id
  GROUP BY p.plant_id, p.turbine_count
  HAVING COUNT(t.turbine_id) <> p.turbine_count;" | grep -c . || true)
if [ "$MISMATCH" = "0" ]; then ok "  every plant has exactly the turbines it declares"
else warn "  $MISMATCH plant(s) disagree with their turbine_count"; BAD=1; fi

# The turbine dashboard's tier selection carries its union inline, so it depends
# on no view or function of ours — only on these three sources existing.
SOURCES=$(psql_val "SELECT COUNT(*) FROM (
    SELECT 1 FROM timescaledb_information.continuous_aggregates
     WHERE view_name IN ('cagg_turbine_power_hourly','cagg_turbine_power_daily')
    UNION ALL
    SELECT 1 FROM pg_class WHERE relname='power_generation') x;")
if [ "$SOURCES" = "3" ]; then ok "  all three turbine-history tiers exist (raw, hourly, daily)"
else warn "  expected 3 turbine-history sources, found $SOURCES"; BAD=1; fi

# Raw has to be finer-grained than the hourly cagg or the tier selection is
# pointless. This catches wind_step_minutes drifting to 60 or above.
STEP=$(psql_val "SELECT COALESCE(EXTRACT(EPOCH FROM MODE() WITHIN GROUP (ORDER BY gap))/60, 0)::int
  FROM (SELECT time - LAG(time) OVER (ORDER BY time) AS gap
          FROM power_generation
         WHERE turbine_id = (SELECT turbine_id FROM turbines ORDER BY name LIMIT 1)) s
 WHERE gap IS NOT NULL;")
if [ -n "$STEP" ] && [ "$STEP" -gt 0 ] && [ "$STEP" -lt 60 ]; then
  ok "  raw telemetry is ${STEP}-minute, finer than the hourly aggregate"
else
  warn "  raw telemetry step is ${STEP} min — at 60+ the raw tier adds no detail over the hourly cagg"
  BAD=1
fi


ELAPSED=$(( $(date +%s) - START_TS ))
if [ "$BAD" = "0" ]; then
  head1 "Done in ${ELAPSED}s"
  say "Reload the Grafana dashboards to see the rebuilt data:"
  GF="http://localhost:${GRAFANA_PORT:-3000}"
  say "  ${C_DIM}${GF}/d/wind-global       start here — drills global > region > plant > turbine${C_RESET}"
  say "  ${C_DIM}${GF}/d/wind-turbine      turbine detail; zoom it to watch the source tier change${C_RESET}"
else
  head1 "Finished in ${ELAPSED}s with warnings — see above"
  exit 1
fi
