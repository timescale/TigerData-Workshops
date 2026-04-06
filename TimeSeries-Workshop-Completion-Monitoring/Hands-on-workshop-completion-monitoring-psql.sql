-- ============================================================================
-- # Oil & Gas Well Completion Monitoring — Hydraulic Fracturing Stage Analytics
-- ============================================================================
-- Hydraulic fracturing (completions) generates thousands of high-frequency 
-- sensor readings — treating pressure, slurry pump rate, proppant concentration, 
-- and downhole pressure — at 5-second intervals from surface treating iron and 
-- downhole gauges.
--
-- A completions engineer monitors these signals in real time against the
-- engineered pump schedule (the "design"), watching for screenouts, pressure
-- anomalies, or rate deviations that require immediate field decisions.
--
-- TigerData handles this workload natively: sub-second ingest, columnar
-- compression on historical stages, continuous aggregates for trend analysis,
-- and full SQL joins across the stage hierarchy and pump schedule design tables.
-- ============================================================================
-- ## Prerequisites
-- ============================================================================
-- 1. A TigerData Cloud service with time-series and analytics enabled
--    https://console.cloud.timescale.com/signup
--
-- 2. Connection string from the TigerData Console:
--    postgres://tsdbadmin:<password>@<host>:<port>/tsdb?sslmode=require
--
-- 3. psql CLI installed (recommended):
--    https://www.tigerdata.com/blog/how-to-install-psql-on-mac-ubuntu-debian-windows
--
-- 4. Basic SQL knowledge
-- ============================================================================
-- ## What You'll Learn
-- ============================================================================
-- - Hypertables:           time-partitioned tables optimised for high-frequency
--                          frac telemetry (5-second intervals)
-- - Columnar compression:  90%+ storage reduction on completed stage data
-- - Continuous aggregates: pre-computed 1-minute rollups for stage trend analysis
-- - Tiered storage:        hot/warm/cold tiers for multi-well, multi-job history
-- - Data retention:        automated lifecycle policies for raw frac telemetry
-- - Design vs Actual:      JOIN pump schedule design tables to live telemetry
-- ============================================================================


-- ============================================================================
-- ## Setup: Drop Existing Objects
-- ============================================================================
-- (highlight and run this block to reset the workshop environment)

DROP TABLE IF EXISTS frac_telemetry    CASCADE;
DROP TABLE IF EXISTS pump_schedule     CASCADE;
DROP TABLE IF EXISTS frac_stages       CASCADE;
DROP TABLE IF EXISTS completion_jobs   CASCADE;


-- ============================================================================
-- ## Create Reference Tables
-- ============================================================================

-- Completion job metadata: one row per frac job (one job covers all stages on a well).
-- This is the relational layer — static information captured before pumping begins.
CREATE TABLE completion_jobs (
  id                       SERIAL        PRIMARY KEY,
  job_identifier           VARCHAR(20)   NOT NULL,    -- anonymised job code (e.g. 'BK-2025-001')
  pad_identifier           VARCHAR(20)   NOT NULL,    -- pad/location code
  formation                VARCHAR(50)   NOT NULL,    -- target zone (e.g. 'Bakken', 'Wolfcamp A')
  basin                    VARCHAR(50)   NOT NULL,    -- producing basin
  operator                 VARCHAR(100)  NOT NULL,
  service_company          VARCHAR(100),              -- frac service company
  wireline_company         VARCHAR(100),              -- wireline/perforating company
  latitude                 DOUBLE PRECISION,
  longitude                DOUBLE PRECISION,
  total_stages             INTEGER       NOT NULL,    -- planned stage count
  job_start_date           DATE          NOT NULL,
  max_working_pressure_psi INTEGER       NOT NULL     -- surface treating pressure limit
);

-- Per-stage metadata: one row per frac stage.
-- Captures the engineered design and post-job actuals for each pumped interval.
CREATE TABLE frac_stages (
  id                         SERIAL         PRIMARY KEY,
  job_id                     INTEGER        NOT NULL REFERENCES completion_jobs (id),
  stage_number               INTEGER        NOT NULL,
  stage_start_time           TIMESTAMPTZ,
  stage_end_time             TIMESTAMPTZ,
  -- Perforation and plug geometry
  perf_top_ft                INTEGER,                 -- top perforation depth, measured depth ft
  perf_bottom_ft             INTEGER,                 -- bottom perforation depth, measured depth ft
  plug_depth_ft              INTEGER,                 -- frac plug set depth, measured depth ft
  -- Design volumes
  design_fluid_bbl           DOUBLE PRECISION,        -- engineered fluid volume
  design_proppant_lbs        DOUBLE PRECISION,        -- engineered proppant mass
  -- Actuals (populated at stage end)
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

-- Pump schedule (design table): the engineered sub-stage sequence for each stage.
-- Completions engineers execute against this schedule in real time.
-- Comparing actual telemetry to this design is the core operational query.
CREATE TABLE pump_schedule (
  id                         SERIAL         PRIMARY KEY,
  stage_id                   INTEGER        NOT NULL REFERENCES frac_stages (id),
  substage_number            INTEGER        NOT NULL,
  fluid_type                 VARCHAR(50),             -- e.g. 'Slickwater', 'Linear Gel'
  proppant_type              VARCHAR(50),             -- e.g. '100 Mesh', '40/70 Mesh', 'None'
  design_volume_bbl          DOUBLE PRECISION,
  design_rate_bpm            DOUBLE PRECISION,        -- target pump rate, bbl/min
  design_proppant_lbs        DOUBLE PRECISION,
  design_concentration_ppg   DOUBLE PRECISION,        -- proppant concentration target, lb/gal
  max_pressure_psi           INTEGER                  -- sub-stage pressure limit
);


-- ============================================================================
-- ## Create the Frac Telemetry Hypertable
-- ============================================================================
-- Stores real-time pump data at 5-second intervals during active pumping.
--
-- Key TigerData settings:
--   tsdb.partition_column = 'time'
--       Weekly chunks let TigerData skip entire stages outside a time filter
--       without reading a single row — critical when querying one job across
--       dozens of stages spanning multiple months.
--
--   tsdb.enable_columnstore = true
--       Columnar format groups all treating_pressure values together,
--       all slurry_rate values together, etc. Aggregation queries (AVG, MAX)
--       touch only the columns they need — far less I/O than row storage.
--
--   tsdb.segmentby = 'stage_id'
--       Each compressed segment holds all readings for one stage.
--       Per-stage queries — the dominant access pattern — require no scan
--       of other stages. Mirrors how completions engineers think: by stage.
--
--   tsdb.orderby = 'time DESC'
--       Within each segment, readings sorted newest-first — matches the
--       real-time dashboard pattern of always fetching the most recent data.
--
--   tsdb.sparse_index = 'minmax(treating_pressure_psi), minmax(slurry_rate_bpm)'
--       Lightweight metadata per segment. WHERE treating_pressure_psi > 9000
--       skips any segment whose max < 9000 — fast screenout detection across
--       thousands of stages without decompressing any data.

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
  tsdb.segmentby          = 'stage_id',
  tsdb.orderby            = 'time DESC',
  tsdb.sparse_index       = 'minmax(treating_pressure_psi), minmax(slurry_rate_bpm)'
);


-- ============================================================================
-- ## Create Indexes
-- ============================================================================
-- TigerData automatically indexes the partition column (time).
-- Add a composite index for efficient per-stage time-range queries —
-- the dominant pattern for stage replay and anomaly investigation.

CREATE INDEX ON frac_telemetry (stage_id, time DESC);


-- ============================================================================
-- ## Populate Completion Jobs
-- ============================================================================
-- Five multi-stage frac jobs across three major U.S. unconventional basins.

INSERT INTO completion_jobs (
  job_identifier, pad_identifier, formation, basin,
  operator, service_company, wireline_company,
  latitude, longitude,
  total_stages, job_start_date, max_working_pressure_psi
) VALUES
-- Williston Basin / Bakken — very deep horizontal wells (~25,000 ft MD)
('BK-2025-001', 'PAD-ALPHA',  'Bakken Middle Member', 'Williston Basin',
 'Northern Plains Energy', 'Apex Pressure Pumping', 'Meridian Wireline',
  47.92, -103.40, 25, '2025-01-15', 9000),
('BK-2025-002', 'PAD-DELTA',  'Three Forks',          'Williston Basin',
 'Northern Plains Energy', 'Apex Pressure Pumping', 'Meridian Wireline',
  48.08, -103.55, 22, '2025-04-01', 8500),

-- Permian Basin — deep stacked laterals, higher treating pressures
('PB-2025-001', 'PAD-BRAVO',  'Wolfcamp A',            'Permian Basin',
 'Permian Basin Resources', 'Summit Frac Services', 'Crestline Wireline',
  31.85, -102.15, 30, '2025-02-20', 9500),
('PB-2025-002', 'PAD-ECHO',   'Spraberry Trend',       'Permian Basin',
 'Permian Basin Resources', 'Summit Frac Services', 'Crestline Wireline',
  32.05, -101.85, 28, '2025-04-28', 9000),

-- Eagle Ford — shallower, lower treating pressures, thinner fluid
('EF-2025-001', 'PAD-CHARLIE','Upper Eagle Ford',       'Eagle Ford',
 'South Texas Petroleum', 'Horizon Pressure Services', 'Gulf Wireline',
  28.42, -99.75,  20, '2025-03-10', 8000);

-- Verify:
SELECT id, job_identifier, pad_identifier, formation, basin, total_stages,
       job_start_date, max_working_pressure_psi
FROM completion_jobs
ORDER BY job_start_date;


-- ============================================================================
-- ## Populate Frac Stages
-- ============================================================================
-- Generates all stages for all jobs. Stages walk from toe to heel
-- (highest measured depth first), with 3-hour inter-stage intervals
-- (2 hours pumping + 1 hour wireline / pressure-test operations).

INSERT INTO frac_stages (                                                                                                            
    job_id, stage_number,                                                                                                            
    stage_start_time, stage_end_time,                                                                                                  
    perf_top_ft, perf_bottom_ft, plug_depth_ft,
    design_fluid_bbl, design_proppant_lbs,                                                                                             
    actual_fluid_bbl, actual_proppant_lbs,                                                                                             
    fluid_efficiency_pct, proppant_efficiency_pct,                                                                                     
    pump_time_minutes,                                                                                                                 
    avg_treating_pressure_psi, max_treating_pressure_psi,                                                                            
    stage_result                                                                                                                       
  )                                                                                                                                  
  SELECT                                                                                                                               
    cj.id                                                                      AS job_id,                                            
    s.n                                                                        AS stage_number,
                                                                                                                                       
    -- Anchor to NOW(): walk backward so the last stage of each job ends at NOW() - 1 minute.
    -- last stage start = NOW() - 121 min  →  last reading ≈ NOW() - 121 min + 120 min = NOW() - 1 min                                 
    -- earlier stages walk back by 3-hour inter-stage intervals from there.                                                            
    NOW() - INTERVAL '121 minutes' - ((cj.total_stages - s.n) * INTERVAL '3 hours') AS stage_start_time,                               
    NOW() - INTERVAL '121 minutes' - ((cj.total_stages - s.n) * INTERVAL '3 hours')                                                    
      + INTERVAL '2 hours'                                                            AS stage_end_time,                               
                                                                                                                                     
    -- Perf depths: walk from toe toward heel, 200 ft cluster spacing                                                                  
    CASE cj.basin                                                                                                                    
      WHEN 'Williston Basin' THEN 25500 - (s.n - 1) * 200                                                                              
      WHEN 'Permian Basin'   THEN 14500 - (s.n - 1) * 200                                                                              
      ELSE                        16000 - (s.n - 1) * 200                                                                              
    END                                                                        AS perf_top_ft,                                         
                                                                                                                                       
    CASE cj.basin                                                                                                                      
      WHEN 'Williston Basin' THEN 25500 - (s.n - 1) * 200 + 185                                                                        
      WHEN 'Permian Basin'   THEN 14500 - (s.n - 1) * 200 + 185                                                                        
      ELSE                        16000 - (s.n - 1) * 200 + 185
    END                                                                        AS perf_bottom_ft,                                      
                                                                                                                                     
    CASE cj.basin                                                                                                                      
      WHEN 'Williston Basin' THEN 25500 - (s.n - 1) * 200 + 200                                                                      
      WHEN 'Permian Basin'   THEN 14500 - (s.n - 1) * 200 + 200                                                                        
      ELSE                        16000 - (s.n - 1) * 200 + 200
    END                                                                        AS plug_depth_ft,                                       
                                                                                                                                     
    -- Design fluid: 380-550 bbl per stage                                                                                             
    ROUND((420 + (cj.id * 17 + s.n * 7) % 130)::NUMERIC, 0)                 AS design_fluid_bbl,                                     
                                                                                                                                       
    -- Design proppant: 180,000-300,000 lbs per stage                                                                                  
    ROUND((200000 + (cj.id * 13 + s.n * 11) % 100000)::NUMERIC, 0)          AS design_proppant_lbs,                                    
                                                                                                                                       
    -- Actuals (95–110% of design)                                                                                                     
    ROUND(((420 + (cj.id * 17 + s.n * 7) % 130) * (1.0 + ((s.n * 3 + cj.id) % 15 - 5) / 100.0))::NUMERIC, 0)                           
                                                                               AS actual_fluid_bbl,                                    
    ROUND(((200000 + (cj.id * 13 + s.n * 11) % 100000) * (1.0 + ((s.n * 2 + cj.id) % 12 - 4) / 100.0))::NUMERIC, 0)                    
                                                                               AS actual_proppant_lbs,                                 
                                                                                                                                       
    -- Efficiency percentages                                                                                                          
    ROUND((96.0 + (s.n * 3 + cj.id) % 14)::NUMERIC, 1)                      AS fluid_efficiency_pct,                                   
    ROUND((93.0 + (s.n * 2 + cj.id) % 12)::NUMERIC, 1)                      AS proppant_efficiency_pct,                                
                                                                                                                                       
    -- Pump time: 110–130 minutes                                                                                                      
    110 + (s.n * 3 + cj.id * 7) % 20                                         AS pump_time_minutes,                                     
                                                                                                                                       
    -- Average and max treating pressure (basin-calibrated)                                                                          
    CASE cj.basin                                                                                                                      
      WHEN 'Williston Basin' THEN 7800 + (cj.id * 200 + s.n * 50) % 600                                                              
      WHEN 'Permian Basin'   THEN 7200 + (cj.id * 150 + s.n * 40) % 600                                                                
      ELSE                        6400 + (cj.id * 100 + s.n * 30) % 500                                                                
    END                                                                        AS avg_treating_pressure_psi,                           
                                                                                                                                       
    CASE cj.basin                                                                                                                    
      WHEN 'Williston Basin' THEN 8400 + (cj.id * 180 + s.n * 60) % 500                                                                
      WHEN 'Permian Basin'   THEN 7800 + (cj.id * 150 + s.n * 50) % 500                                                                
      ELSE                        7000 + (cj.id * 120 + s.n * 40) % 400                                                                
    END                                                                        AS max_treating_pressure_psi,                           
                                                                                                                                       
    -- Stage result: occasional screenout (~1 in 15 stages)                                                                            
    CASE WHEN (s.n * cj.id) % 15 = 0 THEN 'Screenout' ELSE 'Completed' END  AS stage_result                                            
                                                                                                                                       
  FROM completion_jobs cj,                                                                                                           
       generate_series(1, cj.total_stages) AS s(n); 

-- Verify stage count and depth ranges:
SELECT
  cj.job_identifier,
  cj.basin,
  COUNT(fs.id)                       AS stages_loaded,
  MIN(fs.perf_top_ft)                AS shallowest_perf_ft,
  MAX(fs.perf_bottom_ft)             AS deepest_perf_ft,
  ROUND(AVG(fs.design_proppant_lbs)::NUMERIC, 0) AS avg_design_proppant_lbs
FROM frac_stages fs
JOIN completion_jobs cj ON fs.job_id = cj.id
GROUP BY cj.id, cj.job_identifier, cj.basin
ORDER BY cj.job_start_date;


-- ============================================================================
-- ## Populate Pump Schedule (Design Table)
-- ============================================================================
-- Each stage follows a standard 7-substage pump schedule:
--   1. Pad       — slickwater, no proppant (open fracture, establish geometry)
--   2–6.         — stepwise proppant ramp (0.25 → 0.5 → 1.0 → 1.5 → 2.0 ppg)
--   7. Flush     — clean slickwater to displace proppant into fracture
--
-- In the field this table is loaded pre-job and the crew pumps to schedule.
-- Comparing live telemetry to this table is the core operational query.

INSERT INTO pump_schedule (
  stage_id, substage_number, fluid_type, proppant_type,
  design_volume_bbl, design_rate_bpm,
  design_proppant_lbs, design_concentration_ppg, max_pressure_psi
)
SELECT
  fs.id                                                  AS stage_id,
  sub.substage_number,
  sub.fluid_type,
  sub.proppant_type,
  -- Volume allocation per sub-stage (fraction of total design fluid)
  ROUND((fs.design_fluid_bbl * sub.volume_fraction)::NUMERIC, 0) AS design_volume_bbl,
  -- Target rate by basin (Bakken runs higher rates)
  CASE cj.basin
    WHEN 'Williston Basin' THEN 80.0
    WHEN 'Permian Basin'   THEN 70.0
    ELSE                        60.0
  END                                                    AS design_rate_bpm,
  -- Proppant mass per sub-stage
  ROUND((fs.design_proppant_lbs * sub.proppant_fraction)::NUMERIC, 0) AS design_proppant_lbs,
  sub.design_concentration_ppg,
  cj.max_working_pressure_psi                            AS max_pressure_psi

FROM frac_stages fs
JOIN completion_jobs cj ON fs.job_id = cj.id
CROSS JOIN (
  VALUES
    (1, 'Slickwater', 'None',       0.25, 0.00,  0.000),  -- pad
    (2, 'Slickwater', '100 Mesh',   0.10, 0.25,  0.080),  -- 0.25 ppg
    (3, 'Slickwater', '100 Mesh',   0.12, 0.50,  0.130),  -- 0.50 ppg
    (4, 'Slickwater', '40/70 Mesh', 0.15, 1.00,  0.220),  -- 1.0 ppg
    (5, 'Slickwater', '40/70 Mesh', 0.15, 1.50,  0.280),  -- 1.5 ppg
    (6, 'Slickwater', '30/50 Mesh', 0.13, 2.00,  0.270),  -- 2.0 ppg
    (7, 'Slickwater', 'None',       0.10, 0.00,  0.000)   -- flush
) AS sub (substage_number, fluid_type, proppant_type,
          volume_fraction, design_concentration_ppg, proppant_fraction);

-- Verify:
SELECT COUNT(*) AS schedule_rows FROM pump_schedule;
SELECT COUNT(DISTINCT stage_id) AS stages_with_schedule FROM pump_schedule;


-- ============================================================================
-- ## Generate Frac Telemetry (5-Second Intervals)
-- ============================================================================
-- Simulates real-time pump data for all stages across all jobs.
--
-- CONFIGURABLE — the data volume is driven by stage count and pump_time_minutes:
-- ---------------------------------------------------------------
-- Default configuration (all 5 jobs loaded above):
--   125 stages × avg 120 min × 12 readings/min (5-sec) ≈ 180,000 rows
--
--   Volume reference:
--     1 stage  × 120 min × 12 readings/min =   1,440 rows
--     25 stages × 120 min × 12 readings/min =  36,000 rows (1 Bakken job)
--     125 stages × 120 min × 12 readings/min = 180,000 rows (all 5 jobs)
-- ---------------------------------------------------------------
--
-- Each stage simulates the characteristic frac curve shape:
--   - Slurry rate ramps up over the first 10 minutes
--   - Treating pressure rises with rate then holds steady
--   - Proppant concentration steps up through the pump schedule
--   - Everything ramps down during the final flush

  INSERT INTO frac_telemetry (
    time, stage_id,
    treating_pressure_psi,
    slurry_rate_bpm,
    proppant_concentration_ppg,
    bottomhole_pressure_psi,
    hydrostatic_pressure_psi,
    slurry_density_ppg
  )
  SELECT
    fs.stage_start_time + (g.n * INTERVAL '5 seconds')    AS time,
    fs.id                                                  AS stage_id,
    GREATEST(500,
      CASE cj.basin
        WHEN 'Williston Basin' THEN 7600 + (fs.id % 5) * 120
        WHEN 'Permian Basin'   THEN 7000 + (fs.id % 5) * 100
        ELSE                        6200 + (fs.id % 5) * 80
      END
      + 400 * LEAST(1.0, g.n / 120.0)
               * GREATEST(0.0, LEAST(1.0, (fs.pump_time_minutes * 12 - g.n) / 120.0))
      + 200 * CASE
          WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.25 THEN 0.0
          WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.40 THEN 0.2
          WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.55 THEN 0.4
          WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.65 THEN 0.6
          WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.75 THEN 0.8
          WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.88 THEN 1.0
          ELSE 0.0
        END
      + (random() * 300 - 150)
    )                                                      AS treating_pressure_psi,
    GREATEST(0.0,
      CASE cj.basin
        WHEN 'Williston Basin' THEN 78.0 + (fs.id % 4) * 2.0
        WHEN 'Permian Basin'   THEN 68.0 + (fs.id % 4) * 2.0
        ELSE                        57.0 + (fs.id % 4) * 1.5
      END
      * LEAST(1.0, g.n / 120.0)
      * GREATEST(0.0, LEAST(1.0, (fs.pump_time_minutes * 12 - g.n) / 120.0))
      + (random() * 1.5 - 0.75)
    )                                                      AS slurry_rate_bpm,
    CASE
      WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.25 THEN 0.00 + random() * 0.02
      WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.40 THEN 0.25 + random() * 0.04
      WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.55 THEN 0.50 + random() * 0.04
      WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.65 THEN 1.00 + random() * 0.06
      WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.75 THEN 1.50 + random() * 0.08
      WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.88 THEN 2.00 + random() * 0.10
      ELSE                                                      0.00 + random() * 0.02
    END                                                    AS proppant_concentration_ppg,
    GREATEST(0,
      CASE cj.basin
        WHEN 'Williston Basin' THEN 10200 + (fs.id % 5) * 150
        WHEN 'Permian Basin'   THEN  9000 + (fs.id % 5) * 100
        ELSE                         8300 + (fs.id % 5) * 80
      END
      + (random() * 400 - 200)
    )                                                      AS bottomhole_pressure_psi,
    CASE cj.basin
      WHEN 'Williston Basin' THEN 9600 + random() * 60
      WHEN 'Permian Basin'   THEN 8400 + random() * 50
      ELSE                        7700 + random() * 40
    END                                                    AS hydrostatic_pressure_psi,
    8.33
    + CASE
        WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.25 THEN 0.00
        WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.40 THEN 0.18
        WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.55 THEN 0.35
        WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.65 THEN 0.68
        WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.75 THEN 1.00
        WHEN g.n::FLOAT / (fs.pump_time_minutes * 12) < 0.88 THEN 1.32
        ELSE                                                      0.00
      END
    + random() * 0.08                                      AS slurry_density_ppg
  FROM frac_stages fs
  JOIN completion_jobs cj ON fs.job_id = cj.id
  CROSS JOIN generate_series(0, (fs.pump_time_minutes::INTEGER * 12 - 1)) AS g(n);
-- 12 readings/min = 60 sec/min ÷ 5 sec/reading


-- ============================================================================
-- ## Examine Hypertable Partitions
-- ============================================================================
-- TigerData partitions the frac_telemetry table into weekly chunks.
-- Since frac jobs span days to weeks, each job's stages land in
-- 1–4 chunks. During stage-replay queries, chunks outside the time
-- filter are skipped without scanning a single row.

SELECT
  chunk_name,
  range_start,
  range_end,
  is_compressed
FROM timescaledb_information.chunks
WHERE hypertable_name = 'frac_telemetry'
ORDER BY range_start DESC;


-- ============================================================================
-- ## Verify the Dataset
-- ============================================================================
SELECT COUNT(*) AS total_telemetry_rows FROM frac_telemetry;
SELECT * FROM frac_telemetry ORDER BY time DESC LIMIT 10;

-- Rows by job:
SELECT
  cj.job_identifier,
  cj.basin,
  COUNT(ft.time)                          AS telemetry_rows,
  COUNT(DISTINCT ft.stage_id)             AS stages,
  ROUND(AVG(ft.treating_pressure_psi)::NUMERIC, 0) AS avg_treating_pressure_psi,
  ROUND(AVG(ft.slurry_rate_bpm)::NUMERIC, 1)        AS avg_slurry_rate_bpm
FROM frac_telemetry ft
JOIN frac_stages fs   ON ft.stage_id = fs.id
JOIN completion_jobs cj ON fs.job_id  = cj.id
GROUP BY cj.id, cj.job_identifier, cj.basin
ORDER BY cj.job_start_date;


-- ============================================================================
-- ## Sample Queries
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Query 1: Real-Time Stage Status Across All Active Jobs
-- ----------------------------------------------------------------------------
-- Snapshot of the last 5 minutes across all stages currently being pumped.
-- A completions engineer uses this to monitor treating pressure against
-- the max working pressure limit and confirm the rate is on target.
-- Flag any stage within 500 psi of the surface pressure limit.
-- ----------------------------------------------------------------------------
SELECT
  cj.job_identifier,
  cj.basin,
  fs.stage_number,
  fs.stage_result,
  cj.max_working_pressure_psi                                             AS mwp_psi,
  ROUND(AVG(ft.treating_pressure_psi)::NUMERIC, 0)                       AS avg_tp_psi,
  ROUND(MAX(ft.treating_pressure_psi)::NUMERIC, 0)                       AS max_tp_psi,
  ROUND(AVG(ft.slurry_rate_bpm)::NUMERIC, 1)                             AS avg_rate_bpm,
  ROUND(AVG(ft.proppant_concentration_ppg)::NUMERIC, 2)                  AS avg_conc_ppg,
  CASE
    WHEN MAX(ft.treating_pressure_psi) >= cj.max_working_pressure_psi
      THEN 'EXCEEDS MWP — SHUT DOWN'
    WHEN MAX(ft.treating_pressure_psi) >= cj.max_working_pressure_psi - 500
      THEN 'APPROACHING MWP — MONITOR'
    ELSE 'Normal'
  END                                                                     AS pressure_alert
FROM frac_telemetry ft
JOIN frac_stages fs     ON ft.stage_id  = fs.id
JOIN completion_jobs cj ON fs.job_id    = cj.id
WHERE ft.time >= NOW() - INTERVAL '5 minutes'
GROUP BY cj.id, cj.job_identifier, cj.basin, fs.stage_number, fs.stage_result,
         cj.max_working_pressure_psi
ORDER BY cj.job_start_date, fs.stage_number;


-- ----------------------------------------------------------------------------
-- Query 2: Stage Replay — 1-Minute Trend for a Specific Stage
-- ----------------------------------------------------------------------------
-- Collapses 5-second readings into 1-minute buckets for a single stage.
-- Used to review treating pressure, rate, and proppant ramp after the stage
-- completes — or to replay an incident (screenout, rate deviation).
--
-- Equivalent to the "Daily Production Trend" in production monitoring,
-- but at 1-minute granularity over a 2-hour stage window.
-- Change stage_id to review any stage in the dataset.
-- ----------------------------------------------------------------------------
SELECT
  time_bucket('1 minute', ft.time)                    AS minute,
  ROUND(AVG(ft.treating_pressure_psi)::NUMERIC, 0)   AS avg_tp_psi,
  ROUND(MAX(ft.treating_pressure_psi)::NUMERIC, 0)   AS max_tp_psi,
  ROUND(AVG(ft.slurry_rate_bpm)::NUMERIC, 1)         AS avg_rate_bpm,
  ROUND(AVG(ft.proppant_concentration_ppg)::NUMERIC, 2) AS avg_conc_ppg,
  ROUND(AVG(ft.bottomhole_pressure_psi)::NUMERIC, 0) AS avg_bhp_psi,
  ROUND(AVG(ft.hydrostatic_pressure_psi)::NUMERIC, 0) AS avg_hydrostatic_psi,
  -- Pressure drawdown above hydrostatic (net fracture extension pressure)
  ROUND((AVG(ft.bottomhole_pressure_psi) - AVG(ft.hydrostatic_pressure_psi))::NUMERIC, 0)
                                                       AS net_pressure_psi
FROM frac_telemetry ft
WHERE ft.stage_id = 1            -- change to any stage_id of interest
GROUP BY minute
ORDER BY minute;

-- Remember the time it took to run the stage replay query (Query 2) above.
-- After enabling compression and creating the continuous aggregate,
-- run the same query on the c-agg and compare the execution time.


-- ----------------------------------------------------------------------------
-- Query 3: Design vs Actual — Stage Execution Adherence
-- ----------------------------------------------------------------------------
-- Compares the engineered pump schedule (pump_schedule) to the recorded
-- stage actuals (frac_stages). This is the post-job summary a completions
-- engineer uses to assess execution quality and update completion models.
--
-- Fluid and proppant efficiency < 95% often indicates near-wellbore complexity
-- or a premature screenout. Efficiency > 110% may indicate screen/gauge issues.
-- ----------------------------------------------------------------------------
SELECT
  cj.job_identifier,
  cj.basin,
  fs.stage_number,
  fs.perf_top_ft,
  fs.perf_bottom_ft,
  fs.design_fluid_bbl,
  fs.actual_fluid_bbl,
  ROUND(fs.fluid_efficiency_pct::NUMERIC, 1)          AS fluid_pct,
  ROUND(fs.design_proppant_lbs::NUMERIC, 0)           AS design_proppant_lbs,
  ROUND(fs.actual_proppant_lbs::NUMERIC, 0)           AS actual_proppant_lbs,
  ROUND(fs.proppant_efficiency_pct::NUMERIC, 1)       AS proppant_pct,
  fs.pump_time_minutes,
  fs.avg_treating_pressure_psi,
  fs.max_treating_pressure_psi,
  fs.stage_result,
  CASE
    WHEN fs.stage_result = 'Screenout'            THEN 'SCREENOUT — REVIEW'
    WHEN fs.fluid_efficiency_pct < 95             THEN 'UNDER-DISPLACED — INVESTIGATE'
    WHEN fs.proppant_efficiency_pct < 90          THEN 'PROPPANT SHORTFALL'
    WHEN fs.max_treating_pressure_psi
         >= cj.max_working_pressure_psi - 200     THEN 'HIGH PRESSURE EVENT'
    ELSE 'On Design'
  END                                                  AS execution_flag
FROM frac_stages fs
JOIN completion_jobs cj ON fs.job_id = cj.id
ORDER BY cj.job_start_date, fs.stage_number;


-- ----------------------------------------------------------------------------
-- Query 4: Pump Schedule Adherence — Sub-Stage Breakdown
-- ----------------------------------------------------------------------------
-- Joins the pump_schedule design table to recorded telemetry to show
-- how well the crew executed each sub-stage of the pump schedule.
-- Aggregates telemetry over the approximate time window each sub-stage
-- would have been pumped and compares to the engineered target.
-- Useful for evaluating whether the proppant ramp followed design.
-- ----------------------------------------------------------------------------
SELECT
  cj.job_identifier,
  fs.stage_number,
  ps.substage_number,
  ps.fluid_type,
  ps.proppant_type,
  ps.design_concentration_ppg,
  ps.design_volume_bbl,
  ps.design_rate_bpm,
  -- Approximate actual values from telemetry during the sub-stage window
  ROUND(AVG(ft.proppant_concentration_ppg)::NUMERIC, 2)    AS actual_conc_ppg,
  ROUND(AVG(ft.slurry_rate_bpm)::NUMERIC, 1)               AS actual_rate_bpm,
  ROUND(AVG(ft.treating_pressure_psi)::NUMERIC, 0)         AS actual_tp_psi,
  ps.max_pressure_psi                                       AS mwp_psi
FROM pump_schedule ps
JOIN frac_stages fs     ON ps.stage_id  = fs.id
JOIN completion_jobs cj ON fs.job_id    = cj.id
-- Approximate sub-stage time window based on sub-stage number (7 sub-stages, 2-hour stage)
JOIN frac_telemetry ft  ON ft.stage_id  = fs.id
  AND ft.time BETWEEN
    fs.stage_start_time + ((ps.substage_number - 1)::FLOAT / 7 * fs.pump_time_minutes * INTERVAL '1 minute')
    AND
    fs.stage_start_time + (ps.substage_number::FLOAT / 7 * fs.pump_time_minutes * INTERVAL '1 minute')
WHERE fs.id = 1                     -- change to any stage_id of interest
GROUP BY cj.job_identifier, fs.stage_number, ps.substage_number,
         ps.fluid_type, ps.proppant_type,
         ps.design_concentration_ppg, ps.design_volume_bbl,
         ps.design_rate_bpm, ps.max_pressure_psi
ORDER BY ps.substage_number;


-- ============================================================================
-- ## Enable Columnarstore (Compression)
-- ============================================================================
-- After a stage completes it becomes historical data — still queried for
-- post-job analysis and completion optimisation, but no longer receiving
-- live updates. TigerData compresses completed stage data automatically.
--
-- Keep the most recent 12 hours uncompressed (live stage buffer);
-- compress everything older as stages complete throughout the day.

-- Columnstore is already enabled via tsdb.enable_columnstore = true at 
-- table creation — no separate policy call needed. 

CALL add_columnstore_policy('frac_telemetry', after => INTERVAL '12 hours');

-- Compress all existing chunks immediately to observe storage savings:
SELECT compress_chunk(c, true) FROM show_chunks('frac_telemetry') c;

-- SELECT decompress_chunk(c, true) FROM show_chunks('frac_telemetry') c;


-- ============================================================================
-- ## Storage Saved by Compression
-- ============================================================================
SELECT
  pg_size_pretty(before_compression_total_bytes) AS before_compression,
  pg_size_pretty(after_compression_total_bytes)  AS after_compression,
  ROUND(
    (1 - after_compression_total_bytes::NUMERIC / before_compression_total_bytes)
    * 100, 1
  ) AS compression_pct
FROM hypertable_compression_stats('frac_telemetry');

-- Sample output (5 jobs, 125 stages, 5-sec intervals):
--  before_compression | after_compression | compression_pct
-- --------------------+-------------------+-----------------
--  28 MB              | 2.8 MB            |            90.0

-- Per-chunk breakdown:
SELECT
  c.chunk_name,
  c.range_start,
  c.range_end,
  c.is_compressed,
  pg_size_pretty(s.before_compression_total_bytes) AS before,
  pg_size_pretty(s.after_compression_total_bytes)  AS after,
  ROUND(
    (s.before_compression_total_bytes::NUMERIC - s.after_compression_total_bytes::NUMERIC)
    / s.before_compression_total_bytes::NUMERIC * 100, 1
  ) AS compression_pct
FROM timescaledb_information.chunks c
JOIN chunk_compression_stats('frac_telemetry') s ON c.chunk_name = s.chunk_name
ORDER BY c.range_start DESC;


-- ============================================================================
-- ## Create a Continuous Aggregate: 1-Minute Stage Summary
-- ============================================================================
-- Continuous aggregates pre-compute 1-minute rollups from 5-second telemetry.
-- Instead of scanning 12 raw readings per minute, trend analysis and
-- post-job reporting hit one pre-aggregated row per minute — orders of
-- magnitude faster for replay queries covering full 2-hour stages.
--
-- 1-minute granularity is chosen because:
--   - A 2-hour stage contains 120 one-minute buckets — appropriate dashboard resolution
--   - Sub-stage transitions (proppant ramps) occur over 10–15 minutes — visible at 1 min
--   - Screenout events develop over 2–5 minutes — detectable at 1-min granularity
--
-- timescaledb.materialized_only = false returns real-time data for the
-- current (not-yet-aggregated) period without any manual REFRESH.

-- DROP MATERIALIZED VIEW IF EXISTS stage_minute_summary;
CREATE MATERIALIZED VIEW stage_minute_summary
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT
  time_bucket('1 minute', time)            AS minute,
  stage_id,
  AVG(treating_pressure_psi)               AS avg_tp_psi,
  MAX(treating_pressure_psi)               AS max_tp_psi,
  MIN(treating_pressure_psi)               AS min_tp_psi,
  AVG(slurry_rate_bpm)                     AS avg_rate_bpm,
  MAX(slurry_rate_bpm)                     AS max_rate_bpm,
  AVG(proppant_concentration_ppg)          AS avg_conc_ppg,
  MAX(proppant_concentration_ppg)          AS max_conc_ppg,
  AVG(bottomhole_pressure_psi)             AS avg_bhp_psi,
  AVG(hydrostatic_pressure_psi)            AS avg_hydrostatic_psi,
  AVG(slurry_density_ppg)                  AS avg_density_ppg,
  COUNT(*)                                 AS readings_count    -- expect 12 per minute
FROM frac_telemetry
GROUP BY minute, stage_id;

-- Refresh policy: keep the last 2 hours of stage data current.
-- Covers any stage currently being pumped or just completed.
SELECT add_continuous_aggregate_policy('stage_minute_summary',
  start_offset      => INTERVAL '2 hours',
  end_offset        => INTERVAL '1 minute',
  schedule_interval => INTERVAL '1 minute');


-- ============================================================================
-- ## Query the Continuous Aggregate
-- ============================================================================
-- Same result as Query 2 above, but against pre-aggregated 1-minute data.
-- Run EXPLAIN ANALYZE on both to compare execution plans and timing.

--EXPLAIN ANALYZE
SELECT
  sm.minute,
  fs.stage_number,
  cj.job_identifier,
  ROUND(sm.avg_tp_psi::NUMERIC, 0)       AS avg_tp_psi,
  ROUND(sm.max_tp_psi::NUMERIC, 0)       AS max_tp_psi,
  ROUND(sm.avg_rate_bpm::NUMERIC, 1)     AS avg_rate_bpm,
  ROUND(sm.avg_conc_ppg::NUMERIC, 2)     AS avg_conc_ppg,
  ROUND(sm.avg_bhp_psi::NUMERIC, 0)      AS avg_bhp_psi,
  ROUND((sm.avg_bhp_psi - sm.avg_hydrostatic_psi)::NUMERIC, 0) AS net_pressure_psi,
  sm.readings_count
FROM stage_minute_summary sm
JOIN frac_stages fs     ON sm.stage_id = fs.id
JOIN completion_jobs cj ON fs.job_id   = cj.id
WHERE sm.stage_id = 1           -- change to any stage_id of interest
ORDER BY sm.minute;


-- ============================================================================
-- ## Real-Time Continuous Aggregates
-- ============================================================================
-- Insert a live reading and confirm the continuous aggregate reflects it
-- immediately — no REFRESH needed, unlike standard PostgreSQL materialized views.

INSERT INTO frac_telemetry (
  time, stage_id,
  treating_pressure_psi, slurry_rate_bpm, proppant_concentration_ppg,
  bottomhole_pressure_psi, hydrostatic_pressure_psi, slurry_density_ppg
)
VALUES (NOW(), 1, 8250.0, 79.5, 1.50, 10350.0, 9620.0, 9.58);

SELECT
  minute,
  stage_id,
  ROUND(avg_tp_psi::NUMERIC, 0)   AS avg_tp_psi,
  ROUND(avg_rate_bpm::NUMERIC, 1) AS avg_rate_bpm,
  ROUND(avg_conc_ppg::NUMERIC, 2) AS avg_conc_ppg,
  readings_count
FROM stage_minute_summary
WHERE minute >= NOW() - INTERVAL '5 minutes'
ORDER BY minute DESC;

-- The new reading appears immediately in the result.
-- A standard PostgreSQL materialized view would require REFRESH MATERIALIZED VIEW first.


-- ============================================================================
-- ## Tier Data to S3 Storage
-- ============================================================================
-- Completed frac jobs are queried infrequently after post-job analysis.
-- TigerData tiered storage moves data older than 30 days to low-cost S3
-- while retaining full SQL queryability — no query rewrites required.
--
-- Enable tiered storage first in the TigerData Console:
--   Service → Explorer → Storage Configuration → Tiering Storage → Enabled

SELECT add_tiering_policy('frac_telemetry', INTERVAL '30 days');

-- Enable tiered reads for this session:
ALTER DATABASE tsdb SET timescaledb.enable_tiered_reads TO true;

-- Monitor tiering status:
SELECT * FROM timescaledb_osm.chunks_queued_for_tiering
WHERE hypertable_name = 'frac_telemetry';

SELECT * FROM timescaledb_osm.tiered_chunks
WHERE hypertable_name = 'frac_telemetry';


-- ============================================================================
-- ## Data Retention Policy
-- ============================================================================
-- Raw 5-second frac telemetry provides operational value for post-job analysis
-- and completion optimisation — typically 1–2 years. After that, the
-- stage_minute_summary continuous aggregate preserves the 1-minute trend
-- record at dramatically lower storage cost.
--
-- This policy drops raw telemetry chunks older than 2 years automatically.
-- The stage_minute_summary continuous aggregate is retained indefinitely.

SELECT add_retention_policy('frac_telemetry', INTERVAL '2 years');
