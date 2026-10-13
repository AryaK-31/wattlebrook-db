"""Run the Wattlebrook pipeline from start to finish.

    python python/run_pipeline.py            run the pipeline
    python python/run_pipeline.py --reset    delete everything first and start again

Each step runs in its own transaction. If a step fails, its changes are rolled
back, but the FAILED row stays in audit.pipeline_run because it is written in a
separate transaction.
"""

import os
import sys
import uuid
from pathlib import Path

import psycopg
from dotenv import load_dotenv

from load_source_data import load_shadow_copies, load_sources

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

DB = dict(
    host=os.getenv("POSTGRES_HOST", "localhost"),
    port=os.getenv("POSTGRES_PORT", "5432"),
    dbname=os.getenv("POSTGRES_DB"),
    user=os.getenv("POSTGRES_USER"),
    password=os.getenv("POSTGRES_PASSWORD"),
)

SCHEMAS = ["reports", "gold", "test_masked", "silver", "bronze", "dev_sandbox",
           "src_hrms", "src_sis", "src_crm", "qa", "audit"]

# (step name, SQL to run). %s is replaced with the step's run_id.
STEPS = [
    ("load_sources",       load_sources),
    ("bronze_hrms",        "CALL bronze.load_source(%s, 'src_hrms.employee', 'hrms_employee', 'HRMS')"),
    ("bronze_sis",         "CALL bronze.load_source(%s, 'src_sis.student', 'sis_student', 'SIS')"),
    ("bronze_crm",         "CALL bronze.load_source(%s, 'src_crm.constituent', 'crm_constituent', 'ADV_CRM')"),
    ("silver_vault",       "CALL silver.load_vault(%s)"),
    ("identity_matching",  "CALL silver.resolve_identities(%s)"),
    ("catalogue_scan",     "CALL audit.scan_catalogue(%s)"),
    ("retention",          "CALL audit.run_retention(%s)"),
    ("masked_test_data",   "CALL test_masked.provision(%s)"),
    ("gold",               "CALL gold.build(%s)"),
]


def run_step(batch_id, name, work):
    with psycopg.connect(**DB) as conn:
        run_id = conn.execute(
            "INSERT INTO audit.pipeline_run (batch_id, step_name, status) VALUES (%s, %s, 'RUNNING') RETURNING run_id",
            (batch_id, name),
        ).fetchone()[0]
    print(f"{name} ...")

    try:
        with psycopg.connect(**DB) as conn:  # commits if the block finishes, rolls back on an error
            if callable(work):
                work(conn, run_id)
            else:
                conn.execute(work, (run_id,))
    except psycopg.Error as error:
        message = str(error).splitlines()[0]
        with psycopg.connect(**DB) as conn:
            conn.execute(
                "UPDATE audit.pipeline_run SET status = 'FAILED', error_message = %s, finished_at = now() WHERE run_id = %s",
                (message, run_id),
            )
        sys.exit(f"{name} FAILED: {message}")

    with psycopg.connect(**DB) as conn:
        conn.execute("UPDATE audit.pipeline_run SET status = 'SUCCESS', finished_at = now() WHERE run_id = %s", (run_id,))


def main():
    if not DB["dbname"]:
        sys.exit("Copy .env.example to .env first.")

    with psycopg.connect(**DB) as conn:
        if "--reset" in sys.argv:
            print("Dropping all schemas")
            for schema in SCHEMAS:
                conn.execute(f"DROP SCHEMA IF EXISTS {schema} CASCADE")
        for sql_file in sorted((ROOT / "sql").glob("[0-9][0-9]_*.sql")):  # not demo_queries.sql
            conn.execute(sql_file.read_text(encoding="utf-8"))

    batch_id = str(uuid.uuid4())

    # The shadow copies are only loaded once: after that, retention decides what is left of them.
    with psycopg.connect(**DB) as conn:
        loaded_before = conn.execute(
            "SELECT count(*) FROM audit.pipeline_run WHERE step_name = 'load_shadow_copies' AND status = 'SUCCESS'"
        ).fetchone()[0]
    if not loaded_before:
        run_step(batch_id, "load_shadow_copies", load_shadow_copies)

    for name, work in STEPS:
        run_step(batch_id, name, work)

    print("Done. Check the result with:  SELECT * FROM reports.checks;")


if __name__ == "__main__":
    main()
