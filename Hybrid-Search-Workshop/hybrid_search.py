#!/usr/bin/env python3
"""
Hybrid-search helper for the EV maintenance-report corpus.

Embeddings are produced by a small, local ONNX model (fastembed —
BAAI/bge-small-en-v1.5, 384 dims), so there is no API key and no per-call cost.
The vectors are stored in pgvector; BM25 keyword search uses pg_textsearch; and
`search --mode hybrid` fuses the two rankings with Reciprocal Rank Fusion (RRF).

Setup:
    python3 -m venv .venv && source .venv/bin/activate
    pip install -r requirements.txt
    # repo-root .env must define TIMESCALE_SERVICE_URL

Workshop flow:
    python hybrid_search.py load-data          # create table (+ BM25 index) and load the CSV
    python hybrid_search.py build-embeddings   # embed descriptions + build the vector index
    python hybrid_search.py search "rodent damage" --mode keyword
    python hybrid_search.py search "rodent damage" --mode vector
    python hybrid_search.py search "rodent damage" --mode hybrid
"""
import argparse
import os
import sys

import psycopg2
import psycopg2.extras
from dotenv import load_dotenv, find_dotenv

EMBED_MODEL = "BAAI/bge-small-en-v1.5"
EMBED_DIMENSIONS = 384
BM25_INDEX = "mr_bm25_idx"
RRF_K = 60            # Reciprocal Rank Fusion constant
CANDIDATES = 50       # per-list candidate depth before fusion
HERE = os.path.dirname(os.path.abspath(__file__))

load_dotenv(find_dotenv())
DB_URL = os.environ.get("TIMESCALE_SERVICE_URL")
if not DB_URL:
    sys.exit("TIMESCALE_SERVICE_URL is not set (check the repo-root .env).")

_model = None  # lazy so load-data works without downloading the model


def embed(text):
    """Embed one string with the local fastembed model (downloaded once, then cached)."""
    global _model
    if _model is None:
        from fastembed import TextEmbedding
        _model = TextEmbedding(EMBED_MODEL)
    return list(_model.embed([text]))[0].tolist()


def vec_literal(vec):
    return "[" + ",".join(repr(float(x)) for x in vec) + "]"


def connect():
    return psycopg2.connect(DB_URL)


# ---------------------------------------------------------------------------
def cmd_load_data(args):
    """Create the table + BM25 index and load the maintenance-report CSV."""
    csv_path = os.path.join(HERE, "ev_maintenance_reports.csv")
    with connect() as conn, conn.cursor() as cur:
        cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
        cur.execute("CREATE EXTENSION IF NOT EXISTS pg_textsearch;")
        cur.execute(f"""
            CREATE TABLE IF NOT EXISTS maintenance_reports (
                id            INTEGER PRIMARY KEY,
                station_code  TEXT,
                date          DATE,
                description   TEXT,
                status        TEXT,
                embedding     vector({EMBED_DIMENSIONS}));
        """)
        cur.execute("TRUNCATE maintenance_reports;")
        with open(csv_path) as f:
            cur.copy_expert(
                "COPY maintenance_reports (id, station_code, date, description, status) "
                "FROM STDIN WITH (FORMAT CSV, HEADER, DELIMITER ',')", f)
        # BM25 keyword index (indexes the text; no embeddings needed)
        cur.execute(f"CREATE INDEX IF NOT EXISTS {BM25_INDEX} "
                    "ON maintenance_reports USING bm25(description) WITH (text_config='english');")
        cur.execute("SELECT count(*) FROM maintenance_reports;")
        n = cur.fetchone()[0]
    print(f"Loaded {n} maintenance reports and built the BM25 index.")


def cmd_build_embeddings(args):
    """Embed every description with the local model and build the HNSW vector index."""
    with connect() as conn, conn.cursor(name="mr_cursor") as read_cur:
        read_cur.itersize = 256
        read_cur.execute("SELECT id, description FROM maintenance_reports "
                         "WHERE embedding IS NULL AND description IS NOT NULL ORDER BY id;")
        rows = read_cur.fetchall()
    if not rows:
        print("All reports already embedded.")
    else:
        from fastembed import TextEmbedding
        global _model
        _model = _model or TextEmbedding(EMBED_MODEL)
        print(f"Embedding {len(rows)} reports with {EMBED_MODEL} ...")
        ids = [r[0] for r in rows]
        vecs = list(_model.embed([r[1] for r in rows]))  # batched internally
        with connect() as conn, conn.cursor() as cur:
            psycopg2.extras.execute_values(
                cur,
                "UPDATE maintenance_reports AS m SET embedding = v.embedding "
                "FROM (VALUES %s) AS v(id, embedding) WHERE m.id = v.id",
                [(i, vec_literal(vv.tolist())) for i, vv in zip(ids, vecs)],
                template="(%s, %s::vector)")
            conn.commit()
    with connect() as conn, conn.cursor() as cur:
        cur.execute("CREATE INDEX IF NOT EXISTS mr_vec_idx "
                    "ON maintenance_reports USING hnsw (embedding vector_cosine_ops);")
        conn.commit()
        cur.execute("SELECT count(*) FROM maintenance_reports WHERE embedding IS NOT NULL;")
        n = cur.fetchone()[0]
    print(f"{n} reports embedded; HNSW vector index ready.")


def _print(rows):
    for r in rows:
        extra = "  ".join(f"{k}={v}" for k, v in r[1].items())
        print(f"[{r[0]:>6}] {extra}\n         {r[2][:110]}")


def cmd_search(args):
    q = args.query
    k = args.k
    with connect() as conn, conn.cursor() as cur:
        if args.mode == "keyword":
            cur.execute(
                f"""SELECT id, ROUND((description <@> to_bm25query(%s, '{BM25_INDEX}'))::numeric, 4) AS bm25,
                           description
                    FROM maintenance_reports
                    WHERE description <@> to_bm25query(%s, '{BM25_INDEX}') < 0   -- keep only real matches
                    ORDER BY description <@> to_bm25query(%s, '{BM25_INDEX}')
                    LIMIT %s""",
                (q, q, q, k))
            _print([(r[0], {"bm25": r[1]}, r[2]) for r in cur.fetchall()])

        elif args.mode == "vector":
            qv = vec_literal(embed(q))
            cur.execute(
                """SELECT id, ROUND((embedding <=> %s::vector)::numeric, 4) AS dist, description
                   FROM maintenance_reports
                   ORDER BY embedding <=> %s::vector
                   LIMIT %s""",
                (qv, qv, k))
            _print([(r[0], {"cos_dist": r[1]}, r[2]) for r in cur.fetchall()])

        elif args.mode == "hybrid":
            qv = vec_literal(embed(q))
            cur.execute(
                f"""
                WITH kw AS (
                    SELECT id, row_number() OVER (ORDER BY description <@> to_bm25query(%(q)s, '{BM25_INDEX}')) AS rank
                    FROM maintenance_reports
                    WHERE description <@> to_bm25query(%(q)s, '{BM25_INDEX}') < 0
                    ORDER BY description <@> to_bm25query(%(q)s, '{BM25_INDEX}')
                    LIMIT %(n)s
                ),
                vec AS (
                    SELECT id, row_number() OVER (ORDER BY embedding <=> %(qv)s::vector) AS rank
                    FROM maintenance_reports
                    ORDER BY embedding <=> %(qv)s::vector
                    LIMIT %(n)s
                )
                SELECT r.id,
                       ROUND((COALESCE(1.0/(%(rk)s + kw.rank), 0) + COALESCE(1.0/(%(rk)s + vec.rank), 0))::numeric, 5) AS rrf,
                       kw.rank AS kw_rank, vec.rank AS vec_rank, r.description
                FROM maintenance_reports r
                LEFT JOIN kw  ON kw.id  = r.id
                LEFT JOIN vec ON vec.id = r.id
                WHERE kw.id IS NOT NULL OR vec.id IS NOT NULL
                ORDER BY rrf DESC
                LIMIT %(k)s""",
                {"q": q, "qv": qv, "n": CANDIDATES, "rk": RRF_K, "k": k})
            _print([(r[0], {"rrf": r[1], "kw_rank": r[2], "vec_rank": r[3]}, r[4]) for r in cur.fetchall()])


def main():
    p = argparse.ArgumentParser(description="Hybrid search (BM25 + pgvector) over EV maintenance reports")
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("load-data").set_defaults(func=cmd_load_data)
    sub.add_parser("build-embeddings").set_defaults(func=cmd_build_embeddings)
    sp = sub.add_parser("search")
    sp.add_argument("query")
    sp.add_argument("--mode", choices=["keyword", "vector", "hybrid"], default="hybrid")
    sp.add_argument("--k", type=int, default=10)
    sp.set_defaults(func=cmd_search)
    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
