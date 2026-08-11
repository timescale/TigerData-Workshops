# this workshop — How the Data Is Generated

Companion to [README.md](README.md), which covers the database and query design. This file covers
where the rows come from.

Everything here runs inside PostgreSQL. There is no Python, no external ingest process and no
scheduler — the whole data path is SQL functions you can read, call by hand, and re-run. That is
deliberate: a workshop where data appears from somewhere off-screen is much harder to reason about
when a number looks wrong.

## The Shape of the Fleet

Two values in `workshop_config` control everything:

```sql
UPDATE workshop_config SET value = '24' WHERE key = 'num_plants';
UPDATE workshop_config SET value = '16' WHERE key = 'turbines_per_plant';
-- then re-run steps 02 through 08
```

Plants are dealt **round-robin across the six regions**, so `num_plants = 6` puts one plant in each
region rather than six in Texas. The site catalogue holds 36 entries, which is the ceiling.

| `num_plants` | `turbines_per_plant` | Turbines | Wake pairs | Fleet wake loss |
| --- | --- | --- | --- | --- |
| 6 | 4 | 24 | 72 | 5.3% |
| **12** | **8** | **96** | **456** | **6.6%** |
| 18 | 16 | 288 | 1,800 | 8.6% |
| 36 | 9 | 324 | 1,656 | 7.5% |

Larger arrays lose more to their own wakes, because more turbines have more neighbours upwind. That
is the real physical relationship rather than something tuned — and it is why a developer cannot
simply keep adding machines to a site.

Layout knobs, in rotor diameters:

```sql
UPDATE workshop_config SET value = '7'  WHERE key = 'spacing_crosswind_rotors';
UPDATE workshop_config SET value = '12' WHERE key = 'spacing_downwind_rotors';
```

Widen them and wake losses fall while the site footprint grows. That is the actual trade a wind
developer makes.

## Generation Cost Scales Linearly

At both seed and generation time, in total turbine count. Measured with `num_plants = 6`:

| `turbines_per_plant` | Turbines | Wake pairs | Pairs/turbine | Seed | Backfill |
| --- | --- | --- | --- | --- | --- |
| 32 | 192 | 1,380 | 7.19 | 75 ms | 26.9 µs/row |
| 64 | 384 | 3,096 | 8.06 | 96 ms | 26.3 µs/row |
| 128 | 768 | 6,624 | 8.63 | 148 ms | 27.0 µs/row |
| 256 | 1,536 | 13,848 | 9.02 | 262 ms | 26.9 µs/row |
| 512 | 3,072 | 28,548 | 9.29 | 451 ms | — |

Each doubling of turbines costs under 2× the time and cost per row is flat. Wake physics is what
makes that possible: the 12-rotor-diameter cutoff bounds the neighbourhood at about nine turbines
however large the plant grows, so work per turbine is constant.

Two implementation choices were required to actually get linear behaviour, both documented in
`sql/04_seed_turbines.sql`:

- **The neighbour search uses `ST_DWithin` inside a `LATERAL`**, so the GiST index prunes. Filtering
  on `ST_Distance` in a `WHERE` clause cannot use an index, so the planner materialises all n²
  same-plant pairs — 59,400 examined to keep 5,016 at 100 turbines per plant, with the waste ratio
  growing as the plant grows.
- **Verification queries reuse `turbine_neighbors`** instead of recomputing pairwise distances. A
  `MIN(ST_Distance(...))` nearest-neighbour check is itself O(n²) and had become the most expensive
  statement in the file.

## Step 1 — Regions

Six real physiographic and maritime regions, each a genuine wind-development heartland, each with a
polygon boundary and its true prevailing wind direction:

| Region | Country | Prevailing wind | |
| --- | --- | --- | --- |
| Southern Great Plains | United States | 190° | southerly — the Great Plains low-level jet |
| North Sea | UK / Denmark | 245° | offshore |
| North German Plain | Germany | 250° | mid-latitude westerlies |
| Iberian Meseta | Spain | 290° | |
| Deccan Plateau | India | 225° | southwest monsoon |
| Inner Mongolian Plateau | China | 305° | |

The Southern Great Plains figure is worth noting: it is **southerly, not westerly**, because the
low-level jet pulls Gulf air northward. That is why the Texas–Oklahoma wind corridor runs the way it
does, and it matters here because prevailing wind sets the orientation of every turbine grid in the
region.

Boundaries are `ST_MakeEnvelope` boxes — production systems would use administrative or
grid-operator geometry, but envelopes stay readable while still exercising a real point-in-polygon
join. They are deliberately non-overlapping so every site resolves to exactly one region.

Step 04 also exports them to `grafana-geojson/wind-regions.geojson` for the map overlay,
because Grafana's geomap reads GeoJSON only from a static file.

## Step 2 — Site Catalogue

Thirty-six real places with real coordinates, six per region, each an actual wind-development area:

- **Southern Great Plains** — Sweetwater, Snyder, Amarillo, Woodward, Dodge City, Great Bend
- **North Sea** — Dogger Bank, Hornsea, Firth of Forth, Horns Rev, East Anglia, Humber Gateway
- **North German Plain** — Husum, Bremerhaven, Magdeburg, Neubrandenburg, Paderborn, Leipzig
- **Iberian Meseta** — Zaragoza, Albacete, Burgos, A Coruña, Tarifa, Soria
- **Deccan Plateau** — Kanyakumari, Tirunelveli, Palladam, Chitradurga, Satara, Sangli
- **Inner Mongolian Plateau** — Ulanqab, Zhangbei, Jiuquan, Bayannur, Xilinhot, Chifeng

A verification query asserts every site falls inside its declared region, which catches a
transposed coordinate immediately rather than three files later.

## Step 3 — Plants

Plant names follow a business asset-code convention, `<Site>_RRSS`, where RR is the region number and
SS the sequence within it: `Sweetwater_0106` is the sixth plant in region 1. Operators really do name
assets this way, and it means a plant name sorts usefully and carries its region.

Turbine model is chosen by region so the fleet is plausible — big direct-drive machines offshore,
Enercon and Nordex on the North German Plain, Goldwind in Inner Mongolia, Suzlon on the Deccan:

| Region | Model | Rotor | Rated |
| --- | --- | --- | --- |
| North Sea | SG 167-8.0 DD | 167 m | 8,000 kW |
| North German Plain | Enercon E-138 EP3 | 138 m | 3,500 kW |
| Southern Great Plains | Vestas V150-4.2 | 150 m | 4,200 kW |
| Iberian Meseta | Nordex N149-4.5 | 149 m | 4,500 kW |
| Deccan Plateau | Suzlon S144-3.0 | 144 m | 3,000 kW |
| Inner Mongolian Plateau | Goldwind GW140-3.4 | 140 m | 3,400 kW |

The specification lives on `plants`, not on individual turbines: a wind farm is procured as one
order, so every machine on site is the same model. Storing it per turbine would be eight identical
copies waiting to drift apart.

## Step 4 — The Geodesic Turbine Grid

```
cols  = ceil(sqrt(n));  col = i % cols;  row = i / cols
dx    = (col - (cols-1)/2) * crosswind_spacing        -- 5 rotor diameters
dy    = ((rows-1)/2 - row) * downwind_spacing         -- 8 rotor diameters, row 0 upwind
dx   += (row odd ? 0.5 : 0) * crosswind_spacing       -- STAGGER: checkerboard the rows
rotate (dx, dy) by the plant's grid bearing
location = ST_Project(centre, hypot(dx, dy), atan2(dx, dy))
```

Three details that were each a bug before they were a feature. All three now have verification
queries at the end of `sql/04_seed_turbines.sql`, and the queries matter — two of these produce a
layout that looks entirely plausible while being wrong.

**Use `ST_Project`, not degree arithmetic.** Dividing metres by 111,320 is right for latitude and
wrong for longitude by 1/cos(latitude) — 1.7× at Dogger Bank's 54.75°N. Measured nearest-neighbour
spacing now matches intent to the metre at every latitude from 8°N to 56°N.

**A compass bearing is `(sin θ, cos θ)`, not `(cos θ, sin θ)`.** That is the transpose of the
mathematical convention, so the textbook rotation matrix rotates by −θ and mirrors the grid. Spacing
checks still pass perfectly; only an orientation check catches it. The verification asserts the
downwind neighbour's bearing equals `grid_bearing_deg` — error must be ~0.

**Row 0 must be the upwind row.** `grid_bearing_deg` is the direction wind comes *from*, so +dy
points upwind and the sign has to be flipped. Get it wrong and every front-row-versus-back-row query
is inverted while looking sensible.

`LPAD` also deserves a mention: it **truncates** rather than declining to pad, so
`LPAD('100', 2, '0')` returns `'10'`. Turbine 100 was named `T10`, collided with turbine 10, and
`ON CONFLICT DO NOTHING` discarded it silently — a request for 150 turbines produced 99. Names now
pad to the width of the count, and step 04 asserts that every plant has exactly the turbines it asked
for.

## Step 5 — The Wake Model

The reason plants exist as a concept rather than just a label. A turbine extracts energy from the
air, so it leaves a slower wake; anything standing in that wake produces less.

The work is split by what changes and what does not:

| | Where | When |
| --- | --- | --- |
| Pairwise geometry — distance, bearing, deficit, wake half-angle | `turbine_neighbors` | once, at seed |
| "Is the wind coming from that neighbour right now?" | `apply_wake()` | per reading |

The Jensen (Park) model, standard since 1983:

```
deficit = (1 - sqrt(1 - Ct)) / (1 + 2k·x/D)      squared
Ct ≈ 0.8  →  numerator 0.5528
k  = 0.05 onshore, 0.04 offshore
```

`k` is lower offshore because smooth water generates less turbulence, so wakes recover more slowly —
which is exactly why offshore arrays are spaced further apart. At 5D a turbine loses ~25% of its wind
speed, at 8D ~17%, at 12D ~10%. Because power goes as **v³**, a 17% velocity deficit is roughly a
**43% power loss** while that machine is shaded. Multiple wakes combine by root-sum-square, not
addition.

Sweep the wind through 360° for one turbine and you get a directional loss rose, one dip per upwind
neighbour:

```
 wind_from | wake_factor | power_loss_pct | profile
        90 |       1.000 |            0.0 |
       100 |       0.754 |           57.1 | #################################################
       110 |       1.000 |            0.0 |
       190 |       0.829 |           42.9 | ##################################
```

The deepest dips are the **tight 5D crosswind pairs**, which is precisely why you aim the wide 8D
spacing along the prevailing wind. Measured across the fleet:

| Grid position | Wake loss | Capacity factor |
| --- | --- | --- |
| upwind edge (row 0) | 3.4% | 33.4% |
| interior | 9.0% | 31.4% |
| downwind edge | 8.1% | 31.5% |

Wake loss is stored as `power_generation.wake_loss_pct`, and it is computed from the two *power*
values rather than from the velocity deficit — because clipping at rated capacity changes the answer.
A turbine already pitch-limited at rated power loses **nothing** to a modest wake.

`apply_wake()` is declared `STABLE`, not `IMMUTABLE`, because it reads `turbine_neighbors`. That is
the honest declaration, and it is why the wake step sits outside the immutable wind model.

## Step 6 — The Wind Model

Every wind reading comes from `wind_at()`, which is a **pure function of (turbine, timestamp)**. That
single property does a surprising amount of work:

- **Backfill and live generation are the same code path.** The only difference between "30 days of
  history" and "the last 15 minutes" is the window passed to `generate_series`. No second
  implementation to keep in sync, and no discontinuity where history meets live data.
- **History is reproducible.** Drop the tables, re-run the backfill, get identical readings.
- **It is `IMMUTABLE`**, so PostgreSQL will inline it and let aggregates depend on it.

Randomness is added by the *caller*, never inside the function — a function calling `random()` cannot
honestly be `IMMUTABLE`, and marking it so anyway is a lie PostgreSQL punishes with cached plans that
reuse one "random" value for every row.

Six superimposed effects:

1. **Latitude base** — the mid-latitude westerly belt, a Gaussian peaking at 52°, which is why the
   North Sea and North German Plain are covered in turbines.
2. **Seasonal cycle** — northern winter storms peak in January; the southern hemisphere is six
   months out of phase.
3. **Diurnal cycle** — daytime convective mixing drags faster air to hub height, peaking
   mid-afternoon in *local solar time* derived from longitude, so the wave sweeps around the globe
   rather than every turbine peaking at once.
4. **Synoptic weather** — passing depressions on ~4-day and ~1.7-day periods. The dominant source of
   variance.
5. **Monsoon** — tropics only, because the westerly belt cannot explain why southern India is full of
   turbines. Tamil Nadu's Muppandal cluster sits at the Palghat Gap, which funnels the southwest
   monsoon from June to September. Without this term the Indian fleet reads as nearly dead in exactly
   the months it should be at full output.
6. **Storms** — a 23-day oscillator raised to the 16th power: near zero almost always, spiking hard
   for a few hours. Without it no reading ever reaches cut-out speed and the most interesting part of
   the power curve never appears in the data.

Plus an offshore roughness bonus, the single biggest reason offshore capacity factors beat onshore.

### The subtlest line in the model

The synoptic phase comes from **location, not turbine identity**. The obvious implementation hashes
the turbine id for a per-turbine phase offset — and that is wrong in a way that is easy to miss:
turbine ids are random UUIDs, so hashing them gives two turbines 200 m apart completely unrelated
weather. The data looks fine in a single-turbine chart and falls apart the moment you compare
neighbours.

It showed up as a flat 4.6 m/s difference between turbines at *every* separation. With a spatial
phase — one cycle per 55° of longitude and 140° of latitude, roughly the scale of a real synoptic
system — the relationship appears:

| Separation | Avg wind difference |
| --- | --- |
| under 25 km (same plant) | 0.98 m/s |
| 25–100 km | 0.97 m/s |
| 100–500 km | 1.82 m/s |
| 500–1000 km | 3.42 m/s |
| 1000–2000 km | 4.69 m/s |

Longitude dominating also gives the model a west-to-east travelling wave, which is the direction
mid-latitude systems actually move.

### Where the model stops being honest

The spatial phase is a **sinusoid**, so beyond about 2000 km pairs wrap back into phase and appear
correlated again — the difference peaks near 2000 km at ~4.7 m/s and falls to ~1.5 m/s for antipodal
pairs, which is physically meaningless. Below 2000 km it behaves like weather; above that it is an
artifact, and `sql/11_geospatial_queries.sql` says so and scopes its query accordingly.

A production system would not model this at all — it would ingest ERA5 reanalysis or a numerical
weather prediction feed, where the correlation structure comes from actual physics. The workshop
README explains how to swap in live Open-Meteo data on a self-hosted setup with `pgsql-http`
available (Tiger Cloud offers neither `http` nor `pg_net`, so SQL there cannot make an outbound
request).

## Step 5b — Turbine Faults

Real turbines degrade, and the machine keeps reporting happily the whole time — it just makes less
power than the wind it is standing in should produce. `turbine_faults` is the **answer key** for that,
and `turbine_health(turbine_id, at_time)` applies it during generation.

Roughly one turbine in nine carries a fault, which is about right for a real fleet at any moment.
Assignment is deterministic (hashed from the turbine name) so the same machines are faulted on every
rebuild and the dashboards are reproducible.

| `fault_type` | Severity | Shape | Notes |
| --- | --- | --- | --- |
| `blade_soiling` | 4–5.5% | gradual (30–45 d) | dust and insects on the leading edge |
| `blade_erosion` | 6–7.5% | gradual (90–120 d) | leading-edge wear |
| `pitch_misalignment` | 8.5% | step | blade angle out by ~1.5° |
| `yaw_misalignment` | 6.5% | step | nacelle off-wind |
| `gearbox_degradation` | 11.5% | gradual (70 d) | rising drivetrain losses |
| `generator_derate` | 9.5% | step | thermal derate |
| `grid_curtailment` | 30% | step | **not a fault** — operator instruction |

Three deliberate details:

- **`ramp_days` distinguishes the two shapes.** A step fault is on in one reading and a threshold
  alarm catches it. A gradual one creeps in over weeks and no single reading looks wrong — the
  effective severity is `severity × min(1, days_since_start / ramp_days)`.
- **`detected_at` lags `started_at`**, and some rows have it NULL — still undiagnosed. That gap is
  what monitoring exists to close. One seeded fault is only ten days into a ninety-day ramp, costing
  under 1% today, and is invisible to any threshold.
- **`grid_curtailment` is included precisely because it is not a fault.** It looks identical in the
  data; separating it needs context the telemetry does not carry.

Concurrent faults are **summed and capped** rather than multiplied. Multiplying is arguably more
physical, but summing is what wind-industry loss accounting does and it keeps the arithmetic legible
when reconciling a dashboard number.

`turbine_health()` is `STABLE`, not `IMMUTABLE`, because it reads a table — which is why both the wake
and fault steps sit outside the immutable wind model.

## Step 7 — The Power Curve

Power is never reported. It is derived:

```
P = 0.5 × ρ × A × Cp × v³      clipped at rated capacity
                                zero below cut-in, zero at/above cut-out
```

with ρ = 1.225 kg/m³, A the swept area, and Cp a constant 0.40. The `v³` term is the whole economics
of wind: double the wind speed for **eight times** the power, which is why siting matters so much.

Three regimes, and the third surprises people: above `cut_out_ms` output drops to **zero**, because
the turbine shuts down to protect itself. On the stormiest day of the year a region's output can
collapse within minutes as machines hit cut-out one after another.

Simplifying assumption worth stating: real Cp varies with tip-speed ratio and blade pitch, peaking
around 0.45–0.50. The Betz limit — the theoretical maximum for any open rotor — is 16/27 ≈ 0.593. A
constant 0.40 keeps the function readable and lands rated power at a realistic wind speed, while
slightly overstating output at the low end.

## Growing the Dataset

`sql/10_advance_simulation.sql` is the file you re-run. `advance_wind()` resumes from `MAX(time)` in
`wind_measurements` and generates steps of `wind_step_minutes` (15 by default) up to now — the same
step and the same config key `backfill_wind()` uses, so the raw history has one uniform resolution
rather than changing pace where the backfill ends and the live simulation begins.

**Idempotency comes from deriving the window from existing data, not from `ON CONFLICT`.** Run it
twice back to back and the second call reports "already current" and inserts nothing — the window it
would generate cannot overlap what is already there, so there is no duplicate to guard against. That
choice is deliberate: a unique index on a hypertable must include the partitioning column, and
upserts against columnstore chunks add complexity for no benefit.

The `source` column (`'backfill'` vs `'model_live'`) is why it is worth distinguishing the two paths
even though they run identical model code — you can always tell which rows came from the one-off
historical load and which accumulated during the workshop.

## Expected Volumes (default config)

Two columns, because step 12's ACID demo permanently adds four turbines to
`Amarillo_0601`. Run steps 01–11 and you get the left column; a full this workshop run ends
at the right.

| Object | After 01–11 | After step 12 |
| --- | --- | --- |
| `regions` | 6 | 6 |
| `plants` | 12 (425.6 MW nameplate) | 12 (442.4 MW) |
| `turbines` | 96 | 100 |
| `turbine_neighbors` | 456 | 500 |
| `turbine_faults` | 18 (16 active) | 18 |
| `wind_measurements` / `power_generation` | ~6,727,776 each | ~6,730,948 each |

### The four settings that drive all of it

Every number above is a product of four `workshop_config` values. They are in that
table rather than `.env` because **SQL cannot read environment variables** — there is
no external process here to pass them in.

| Setting | Default | `reset_demo.sh` flag |
| --- | --- | --- |
| `backfill_days` | **730** (2 years) | `--days N` |
| `num_plants` | **12** (two per region) | `--plants N` |
| `turbines_per_plant` | **8** | `--turbines-per-plant N` |
| `wind_step_minutes` | **15** | — |

```
rows per hypertable = num_plants x turbines_per_plant
                      x backfill_days x 1440 / wind_step_minutes
                    = 12 x 8 x 730 x 96
                    = 6,727,776          (and there are two of them)
```

Measured end to end, both parts, on an 8 GB machine:

| Fleet | History | Rows per hypertable | Total DB | Whole run |
| --- | --- | --- | --- | --- |
| 96 turbines (default) | 730 d | 6,730,948 | 886 MB | 199 s |
| 48 turbines | 365 d | 1,684,948 | 506 MB | 49 s |
| 72 turbines | 90 d | 625,180 | 299 MB | 18 s |
| 1 turbine | 30 d | 5,767 | 93 MB | 3 s |

**Why the telemetry is ~6.7 M rows and not ~70,000.** Both the backfill and the live
simulation step at `wind_step_minutes`: 96 samples a day, 2,881 per turbine per 30
days, 70,081 over two years. Earlier versions backfilled hourly and only stepped at
15 minutes going forward, which left the raw table at roughly the same resolution as
`cagg_turbine_power_hourly` — and made the raw tier of the turbine dashboard
pointless, since zooming in revealed nothing the aggregate did not already have. Both
paths now read the same key.

Set `wind_step_minutes` to 60 and the volume drops fourfold, at the cost of that
tier. `reset_demo.sh` checks for exactly this and warns if the raw step reaches 60
minutes.

**The binding constraint is the aggregate fill, not the backfill.** At this volume
the initial `refresh_continuous_aggregate` pass used to be OOM-killed partway
through — signal 9, taking the whole instance into recovery. Step 08 now fills in
monthly windows *and* reconnects between aggregates, which releases the memory that
was accumulating across calls in a single session. Read the note there before
raising `num_plants` much beyond the default.

Fleet capacity factor lands around **37%** with **6.2%** average wake loss and a fleet performance
ratio near **99%** — all three realistic. Offshore North Sea plants reach ~51%, the Southern Great
Plains ~33% over a full two years. Individual faulted turbines drop to 77–85% performance ratio while
their capacity factor can look perfectly normal, which is the whole reason both are stored.

## Scheduling It for Real

The workshop has you run the advance script by hand, which keeps pacing in your control and means
nothing happens off-screen. In production you would schedule it with `add_job()` — available on every
Tiger Cloud service with no preload and no support ticket:

```sql
CREATE PROCEDURE job_advance_wind(job_id INT, config JSONB) LANGUAGE plpgsql AS $$
BEGIN
  PERFORM advance_wind();
END $$;

SELECT add_job('job_advance_wind', '15 minutes');
```

`pg_cron` also exists on Tiger Cloud but is gated behind a support request, which is why it is not a
workshop prerequisite.
