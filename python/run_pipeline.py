"""Run the Wattlebrook governed data pipeline end to end.

    python python/run_pipeline.py            # normal run (can be repeated)
    python python/run_pipeline.py --reset    # drop everything first: clean demo from scratch
    python python/run_pipeline.py --as-of 2026-10-12   # retention "today" (default: today)

Transactions: every step runs in its own transaction. The step's RUNNING row
and its final SUCCESS/FAILED status are written in separate transactions, so
when a step fails, its work is rolled back but the FAILED row and the error
message stay in audit.pipeline_run.
"""

import argparse
import sys
import uuid
from datetime import date

from sqlalchemy import text

from config import SQL_DIR, get_db_engine, run_sql
from load_source_data import seed_shadow_copies, seed_sources, shadow_already_seeded

PROJECT_SCHEMAS = ["reports", "gold", "test_masked", "silver", "bronze", "dev_sandbox",
                   "src_hrms", "src_sis", "src_crm", "qa", "audit"]

DEPLOY_FILES = [  # DDL and procedures; safe to run repeatedly
    "01_init_schemas.sql", "02_audit_framework.sql", "03_bronze_ingestion.sql", "04_silver_vault.sql",
    "05_identity_resolution.sql", "06_test_masked.sql", "07_catalogue_discovery.sql", "08_retention.sql",
    "09_gold_star_schema.sql", "11_indexes.sql",
]
REPORTS_FILE = "10_reports.sql"   # depends on tables rebuilt by the pipeline, so it runs last


class StepFailed(RuntimeError):
    pass


class Pipeline:
    def __init__(self, engine):
        self.engine = engine
        self.batch_id = str(uuid.uuid4())

    def step(self, name, source, target, work):
        """Run work(conn, run_id) as one atomic, logged step."""
        with self.engine.begin() as conn:
            run_id = conn.execute(text("SELECT audit.start_step(:b, :s, :src, :t)"),
                                  {"b": self.batch_id, "s": name, "src": source, "t": target}).scalar()
        print(f"[{run_id:>4}] {name} ...", flush=True)
        try:
            with self.engine.begin() as conn:
                work(conn, run_id)
        except Exception as exc:  # the step's own changes are rolled back at this point
            message = str(getattr(exc, "orig", exc)).strip()
            with self.engine.begin() as conn:
                conn.execute(text("CALL audit.fail_step(:r, :m)"), {"r": run_id, "m": message[:2000]})
            print(f"[{run_id:>4}] {name} FAILED: {message.splitlines()[0]}", file=sys.stderr)
            raise StepFailed(f"{name}: {message}") from exc
        with self.engine.begin() as conn:
            conn.execute(text("CALL audit.finish_step(:r)"), {"r": run_id})
        return run_id


def call(sql_template):
    """A step body that runs one CALL with the step's run_id."""
    return lambda conn, run_id: run_sql(conn, sql_template.format(run_id=run_id))


def deploy(engine, reset=False):
    with engine.begin() as conn:
        if reset:
            print("Dropping all project schemas (--reset)")
            run_sql(conn, "".join(f"DROP SCHEMA IF EXISTS {s} CASCADE;" for s in PROJECT_SCHEMAS))
        for name in DEPLOY_FILES:
            run_sql(conn, (SQL_DIR / name).read_text(encoding="utf-8"))
    print(f"Deployed {len(DEPLOY_FILES)} SQL scripts")


def execute_pipeline(reset=False, as_of=None):
    as_of = as_of or date.today().isoformat()
    engine = get_db_engine()
    deploy(engine, reset)
    p = Pipeline(engine)
    print(f"Batch {p.batch_id}, retention as of {as_of}")

    # 1. Source systems (simulated) and the one-off shadow-copy baseline
    p.step("seed_sources", "workbook", "src_hrms, src_sis, src_crm, qa", seed_sources)
    with engine.connect() as conn:
        seeded = shadow_already_seeded(conn)
    if not seeded:
        p.step("seed_shadow_copies", "workbook#Shadow_Extracts", "dev_sandbox.*", seed_shadow_copies)

    # 2. Bronze: append-only raw landing
    for src, tbl, label in [("src_hrms.employee", "hrms_employee_raw", "HRMS"),
                            ("src_sis.student", "sis_student_raw", "SIS"),
                            ("src_crm.constituent", "crm_constituent_raw", "ADV_CRM")]:
        p.step(f"bronze_{label.lower()}", src, f"bronze.{tbl}",
               call(f"CALL bronze.load_source({{run_id}}, '{src}', 'bronze', '{tbl}', '{label}')"))

    # 3. Silver: Data Vault and identity resolution
    p.step("silver_vault_load", "bronze.*_raw", "silver hubs + satellites", call("CALL silver.load_vault({run_id})"))
    p.step("identity_resolution", "silver satellites", "silver.hub_person + link_person_identity",
           call("CALL silver.resolve_identities({run_id})"))

    # 4. Catalogue, retention review, purge
    p.step("discovery_scan_before", "all schemas", "audit.dataset + pii_column",
           call("CALL audit.scan_for_pii({run_id}, 'BEFORE_RETENTION')"))
    p.step("retention_review", "audit.retention_policy", "audit.retention_due_record",
           call(f"CALL audit.run_retention({{run_id}}, TRUE, DATE '{as_of}')"))
    p.step("retention_purge", "audit.retention_due_record", "silver, bronze, dev_sandbox",
           call(f"CALL audit.run_retention({{run_id}}, FALSE, DATE '{as_of}')"))

    # 5. Masked test data, final scan, gold, reports
    p.step("masked_provisioning", "silver current views", "test_masked.*",
           call("CALL test_masked.provision_masked_data({run_id})"))
    p.step("discovery_scan_after", "all schemas", "audit.dataset + pii_column",
           call("CALL audit.scan_for_pii({run_id}, 'AFTER_RETENTION')"))
    p.step("gold_build", "silver + audit", "gold.*", call("CALL gold.build_star_schema({run_id})"))
    p.step("reports_views", REPORTS_FILE, "reports.*",
           lambda conn, run_id: run_sql(conn, (SQL_DIR / REPORTS_FILE).read_text(encoding="utf-8")))

    print("Pipeline completed successfully. Next: python python/validate_pipeline.py")
    return p.batch_id


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reset", action="store_true", help="drop all project schemas and start clean")
    ap.add_argument("--as-of", help="retention reference date, YYYY-MM-DD (default: today)")
    args = ap.parse_args()
    if args.as_of:
        date.fromisoformat(args.as_of)  # validate
    try:
        execute_pipeline(reset=args.reset, as_of=args.as_of)
    except StepFailed as exc:
        sys.exit(f"Pipeline stopped: {exc}\nThe failure is recorded in audit.pipeline_run.")


if __name__ == "__main__":
    main()
