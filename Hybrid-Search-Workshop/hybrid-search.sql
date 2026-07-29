-- ============================================================================
-- # Hybrid Search Workshop — BM25 Keyword + pgvector Semantic + RRF Fusion
-- ============================================================================
-- Keyword search (BM25) is precise on exact terms but blind to meaning:
-- a search for "animals chewing wires" never matches a report that says
-- "damaged wiring caused by rodents". Vector search is the opposite — it finds
-- meaning but can under-rank an exact keyword hit. Hybrid search runs both and
-- fuses the rankings, so you get precision AND recall.
--
-- This workshop searches ~685 EV charging-station maintenance reports three ways:
--   1. BM25 keyword search        (pg_textsearch)
--   2. Vector semantic search     (pgvector HNSW)
--   3. Hybrid search              (Reciprocal Rank Fusion of the two)
--
-- Embeddings are produced by a small LOCAL model (fastembed, 384-dim) via the
-- companion script hybrid_search.py — no API key, no per-call cost. The vectors
-- live in pgvector; the fusion happens in plain SQL.
-- ============================================================================
-- ## Prerequisites
-- ============================================================================
-- 1. A Tiger Cloud service (extensions used: vector, pg_textsearch).
-- 2. Python 3.9+ and the repo-root .env with TIMESCALE_SERVICE_URL set.
-- 3. Install deps:  pip install -r requirements.txt
-- ============================================================================

-- ============================================================================
-- ## Extensions
-- ============================================================================
-- vector        : embedding storage, distance operators (<=>), and the HNSW ANN index
-- pg_textsearch : BM25 full-text ranking (bm25 index access method, <@> operator)
CREATE EXTENSION IF NOT EXISTS vector CASCADE;
CREATE EXTENSION IF NOT EXISTS pg_textsearch CASCADE;


DROP TABLE IF EXISTS maintenance_reports CASCADE;
-- ============================================================================
-- ## Schema
-- ============================================================================
-- One row per maintenance visit. `description` is the searchable text;
-- `embedding` holds its 384-dim vector (populated by build-embeddings).
CREATE TABLE IF NOT EXISTS maintenance_reports (
    id            INTEGER PRIMARY KEY,
    station_code  TEXT,
    date          DATE,
    description   TEXT,
    status        TEXT,
    embedding     vector(384)
);

-- ============================================================================
-- ## Load data and build the indexes
-- ============================================================================
-- The companion script loads the CSV and (because embeddings need a model)
-- generates the vectors locally, then builds both indexes:
--
--   python hybrid_search.py load-data          -- COPY the 685 reports + BM25 index
--   python hybrid_search.py build-embeddings    -- embed descriptions + HNSW index
--
-- The indexes it creates (shown here for reference):
--
--   -- BM25 keyword index over the report text:
--   CREATE INDEX mr_bm25_idx ON maintenance_reports
--       USING bm25(description) WITH (text_config='english');
--
--   -- HNSW approximate-NN index over the embeddings (cosine distance):
--   CREATE INDEX mr_vec_idx ON maintenance_reports
--       USING hnsw (embedding vector_cosine_ops);

-- Confirm the corpus is ready (expected: 685 reports, 685 embedded):
SELECT count(*) AS reports, count(embedding) AS embedded FROM maintenance_reports;

-- ============================================================================
-- ## 1. BM25 keyword search
-- ============================================================================
-- pg_textsearch scores a document against a query with the <@> operator.
-- Scores are NEGATIVE — the more negative, the better the match — and the bm25
-- index accelerates ORDER BY ... LIMIT. Non-matching rows score 0, so we keep
-- only real matches with "< 0". No embedding needed: this is pure lexical search.
--
-- Query "animals chewing wires". Expected: strong lexical hits (raccoon/mice/rat
-- reports containing "animal", "chewing", "wiring") — but note it ranks a report
-- about a raccoon-damaged *camera* highly on the word overlap, and it cannot find
-- reports that describe the same thing in other words (e.g. "damaged wiring
-- caused by rodents", which contains none of the query terms).
SELECT id,
       ROUND((description <@> to_bm25query('animals chewing wires', 'mr_bm25_idx'))::numeric, 3) AS bm25_score,
       left(description, 80) AS description
FROM maintenance_reports
WHERE description <@> to_bm25query('animals chewing wires', 'mr_bm25_idx') < 0
ORDER BY description <@> to_bm25query('animals chewing wires', 'mr_bm25_idx')
LIMIT 5;

-- ============================================================================
-- ## 2. Vector semantic search
-- ============================================================================
-- Vector search ranks by meaning using cosine distance (<=>, smaller = closer).
-- To search arbitrary text you embed the query first — use the script:
--
--   python hybrid_search.py search "animals chewing wires" --mode vector
--
-- Expected: it surfaces "Repaired damaged wiring caused by rodents" as the top
-- hit even though that text shares NO words with the query — the semantic win
-- that BM25 cannot achieve.
--
-- You can also run semantic "more like this" entirely in SQL by using an existing
-- report's stored embedding as the query vector (no model call). Find the reports
-- most similar in meaning to report 530 ("Repaired damaged wiring caused by rodents"):
SELECT id,
       ROUND((embedding <=> (SELECT embedding FROM maintenance_reports WHERE id = 530))::numeric, 4) AS cos_dist,
       left(description, 80) AS description
FROM maintenance_reports
WHERE id <> 530
ORDER BY embedding <=> (SELECT embedding FROM maintenance_reports WHERE id = 530)
LIMIT 5;

-- ============================================================================
-- ## 3. Hybrid search (Reciprocal Rank Fusion)
-- ============================================================================
-- RRF fuses two ranked lists without needing to normalise their different score
-- scales. Each document scores SUM over lists of 1 / (k + rank_in_list), with a
-- constant k (60 is the common default). A document ranked highly by either
-- method scores well; a document ranked highly by BOTH wins.
--
-- For arbitrary query text, the script embeds the query and runs exactly this
-- fusion:
--
--   python hybrid_search.py search "animals chewing wires" --mode hybrid
--
-- Expected: the semantic-only top hit ("...wiring caused by rodents", vec_rank 1,
-- kw_rank 4) is promoted to #1, reports both methods agree on rise, and the
-- keyword-only false-ish positive (the raccoon *camera* report) drops out of the
-- top results.
--
-- The same fusion, runnable purely in SQL as "hybrid more like this" — using
-- report 530's own text for the BM25 side and its embedding for the vector side:
WITH seed AS (
    SELECT description, embedding FROM maintenance_reports WHERE id = 530
),
kw AS (   -- BM25 keyword ranking
    SELECT id, row_number() OVER (
        ORDER BY description <@> to_bm25query((SELECT description FROM seed), 'mr_bm25_idx')) AS rank
    FROM maintenance_reports
    WHERE id <> 530
      AND description <@> to_bm25query((SELECT description FROM seed), 'mr_bm25_idx') < 0
    ORDER BY description <@> to_bm25query((SELECT description FROM seed), 'mr_bm25_idx')
    LIMIT 50
),
vec AS (  -- vector semantic ranking
    SELECT id, row_number() OVER (
        ORDER BY embedding <=> (SELECT embedding FROM seed)) AS rank
    FROM maintenance_reports
    WHERE id <> 530
    ORDER BY embedding <=> (SELECT embedding FROM seed)
    LIMIT 50
)
SELECT r.id,
       ROUND((COALESCE(1.0/(60 + kw.rank), 0) + COALESCE(1.0/(60 + vec.rank), 0))::numeric, 5) AS rrf_score,
       kw.rank  AS kw_rank,
       vec.rank AS vec_rank,
       left(r.description, 70) AS description
FROM maintenance_reports r
LEFT JOIN kw  ON kw.id  = r.id
LEFT JOIN vec ON vec.id = r.id
WHERE kw.id IS NOT NULL OR vec.id IS NOT NULL
ORDER BY rrf_score DESC
LIMIT 10;

-- ============================================================================
-- ## Why hybrid
-- ============================================================================
-- - BM25 alone: great when the user's words appear verbatim; misses paraphrases
--   and can be fooled by incidental term overlap (e.g. "break" vs "break-in").
-- - Vector alone: captures meaning and synonyms; can under-rank an exact,
--   obviously-relevant keyword hit.
-- - Hybrid (RRF): keeps BM25's precision on exact terms and vector's recall on
--   meaning, and rewards documents both methods agree on — the most robust
--   default for real search over messy operational text.
