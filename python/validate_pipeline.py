"""End-to-end test of the pipeline. Run after run_pipeline.py.

Every check prints PASS or FAIL; the script exits with status 1 if any check
fails. It also demonstrates failure handling: it runs a deliberately broken
ingestion step and confirms that its work was rolled back while its FAILED
row stayed in audit.pipeline_run.
"""

import sys

from sqlalchemy import text

from config import get_db_engine
from run_pipeline import Pipeline, StepFailed, call

MIN_PRECISION, MIN_RECALL = 99.0, 95.0
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  ({detail})" if detail else ""))


def scalar(conn, sql):
    return conn.execute(text(sql)).scalar()


def main():
    engine = get_db_engine()
    with engine.connect() as c:
        print("\n1. Pipeline run log")
        failed = scalar(c, "SELECT count(*) FROM reports.r01_pipeline_runs WHERE run_status <> 'SUCCESS'")
        steps = scalar(c, "SELECT count(*) FROM reports.r01_pipeline_runs")
        check("every step of the latest batch succeeded", failed == 0, f"{steps} steps")

        print("\n2. Row counts reconcile from source to bronze to silver")
        for src, brz, hub, sysname in [("src_hrms.employee", "bronze.hrms_employee_raw", "silver.hub_employee", "HRMS"),
                                       ("src_sis.student", "bronze.sis_student_raw", "silver.hub_student", "SIS"),
                                       ("src_crm.constituent", "bronze.crm_constituent_raw", "silver.hub_constituent", "ADV_CRM")]:
            n_src = scalar(c, f"SELECT count(*) FROM {src}")
            n_brz = scalar(c, f"SELECT count(*) FROM {brz} WHERE pipeline_run_id = bronze.latest_batch('{brz}')")
            n_hub = scalar(c, f"SELECT count(*) FROM {hub}")
            n_del = scalar(c, f"SELECT count(*) FROM audit.erasure_register WHERE system_name = '{sysname}' AND action = 'DELETE'")
            check(f"{src} = {brz} + records deleted by retention = {hub}", n_src == n_brz + n_del == n_hub,
                  f"{n_src} = {n_brz} + {n_del} = {n_hub}")
        n_link = scalar(c, "SELECT count(*) FROM silver.link_person_identity")
        n_expected = scalar(c, """SELECT (SELECT count(*) FROM silver.hub_student) + (SELECT count(*) FROM silver.hub_employee)
                                       + (SELECT count(*) FROM silver.hub_constituent)
                                       - (SELECT count(*) FROM audit.erasure_register WHERE action = 'DELETE')""")
        check("every retained source record has exactly one identity link", n_link == n_expected, f"{n_link} links")
        orphans = scalar(c, """SELECT count(*) FROM silver.sat_student_pii s
                               WHERE NOT EXISTS (SELECT 1 FROM silver.hub_student h WHERE h.student_hk = s.student_hk)""")
        check("no satellite rows without a hub", orphans == 0)

        print("\n3. Identity resolution against the answer key")
        acc = c.execute(text("SELECT precision_pct, recall_pct, wrong_links, missed_links FROM reports.r07_identity_accuracy")).one()
        check(f"precision >= {MIN_PRECISION}%", acc.precision_pct >= MIN_PRECISION, f"{acc.precision_pct}%, {acc.wrong_links} wrong links")
        check(f"recall >= {MIN_RECALL}%", acc.recall_pct >= MIN_RECALL, f"{acc.recall_pct}%, {acc.missed_links} missed links")
        high_wrong = scalar(c, "SELECT records_in_wrong_merges FROM reports.r07b_identity_errors_by_confidence WHERE match_confidence = 'HIGH'")
        check("no wrong merges among HIGH-confidence links", (high_wrong or 0) == 0, f"{high_wrong or 0}")

        print("\n4. Masked test data contains no real personal data")
        for row in c.execute(text("SELECT check_name, failures FROM reports.r08_masking_leak_check WHERE target = 0")):
            check(row.check_name, row.failures == 0, f"{row.failures}")
        provisioned = scalar(c, "SELECT failures FROM reports.r08_masking_leak_check WHERE check_name LIKE '(info) masked rows%'")
        check("masked data was provisioned for all three systems",
              all(scalar(c, f"SELECT count(*) FROM test_masked.{t}") > 0 for t in ("student", "employee", "constituent")),
              f"{provisioned} rows")

        print("\n5. Retention")
        overdue = scalar(c, """SELECT (SELECT count(*) FROM silver.v_student_current
                                       WHERE retention_expiry_date < current_date AND anonymised_at IS NULL AND first_name IS NOT NULL)
                                    + (SELECT count(*) FROM silver.v_employee_current
                                       WHERE retention_expiry_date < current_date AND anonymised_at IS NULL AND first_name IS NOT NULL)
                                    + (SELECT count(*) FROM silver.v_constituent_current
                                       WHERE retention_expiry_date < current_date AND first_name IS NOT NULL)""")
        check("no silver PII past its retention date", overdue == 0, f"{overdue}")
        sandbox_overdue = 0
        for (ds,) in c.execute(text("SELECT dataset FROM audit.dataset WHERE layer = 'dev_sandbox' AND to_regclass(dataset) IS NOT NULL")):
            sandbox_overdue += scalar(c, f"SELECT count(*) FROM {ds} WHERE retention_expiry_date < current_date")
        check("no shadow copies past their approved retention", sandbox_overdue == 0, f"{sandbox_overdue}")
        still_found = scalar(c, "SELECT count(*) FROM audit.dataset WHERE layer = 'dev_sandbox' AND status = 'FOUND_BY_SCAN'")
        check("every shadow copy was purged or quarantined", still_found == 0)
        bronze_pii = scalar(c, """SELECT count(*) FROM bronze.sis_student_raw r JOIN audit.erasure_register e
                                  ON e.system_name = 'SIS' AND e.business_key = r.sis_student_id WHERE r.email IS NOT NULL""")
        check("erased records hold no PII in bronze either", bronze_pii == 0, f"{bronze_pii}")
        purged = scalar(c, "SELECT coalesce(sum(rows_affected), 0) FROM audit.purge_log")
        check("purge actions were logged", purged > 0, f"{purged} rows affected in total")

        print("\n6. Catalogue and lineage")
        unregistered = scalar(c, """SELECT count(*) FROM information_schema.tables t
                                    WHERE t.table_type = 'BASE TABLE'
                                      AND t.table_schema IN ('src_hrms','src_sis','src_crm','bronze','silver','gold','test_masked','dev_sandbox')
                                      AND NOT EXISTS (SELECT 1 FROM audit.dataset d WHERE d.dataset = t.table_schema || '.' || t.table_name)""")
        check("every table in the platform is in the catalogue", unregistered == 0, f"{unregistered} missing")
        no_lineage = scalar(c, """SELECT count(*) FROM audit.dataset d WHERE d.status = 'REGISTERED'
                                    AND d.layer IN ('source', 'bronze', 'silver', 'test_masked', 'gold')
                                    AND NOT EXISTS (SELECT 1 FROM audit.lineage l WHERE l.child = d.dataset)""")
        check("every pipeline-built dataset has lineage", no_lineage == 0, f"{no_lineage} without")
        pii_cols = scalar(c, "SELECT count(*) FROM audit.pii_column")
        check("discovery scan classified PII columns", pii_cols > 0, f"{pii_cols} columns")

        print("\n7. Data quality")
        missed = scalar(c, """SELECT count(*) FROM qa.dq_test_cases q WHERE NOT EXISTS
                              (SELECT 1 FROM audit.dq_issue i WHERE i.system_name = q.source_system AND i.record_key = q.source_record_id)""")
        seeded = scalar(c, "SELECT count(*) FROM qa.dq_test_cases")
        check("every seeded data-quality problem was detected", missed == 0, f"{seeded - missed}/{seeded}")

    print("\n8. Failure handling (deliberately broken step)")
    with engine.connect() as c:
        before = scalar(c, "SELECT count(*) FROM bronze.sis_student_raw")
    p = Pipeline(engine)
    try:
        # The source has a column that bronze does not, as if the SIS schema changed without notice.
        with engine.begin() as c:
            c.execute(text("DROP TABLE IF EXISTS qa.broken_source"))
            c.execute(text("CREATE TABLE qa.broken_source AS SELECT s.*, 'surprise' AS unexpected_column FROM src_sis.student s"))
        p.step("failure_demo", "qa.broken_source", "bronze.sis_student_raw",
               call("CALL bronze.load_source({run_id}, 'qa.broken_source', 'bronze', 'sis_student_raw', 'SIS')"))
        check("broken step raised an error", False)
    except StepFailed:
        check("broken step raised an error", True)
    with engine.begin() as c:
        c.execute(text("DROP TABLE IF EXISTS qa.broken_source"))
        row = c.execute(text("SELECT run_status, error_message FROM audit.pipeline_run "
                             "WHERE batch_id = :b AND step_name = 'failure_demo'"), {"b": p.batch_id}).one()
        after = scalar(c, "SELECT count(*) FROM bronze.sis_student_raw")
    check("FAILED row survived the rollback", row.run_status == "FAILED", row.error_message[:70])
    check("bronze table unchanged after the failed step", before == after, f"{before} rows before and after")

    passed = sum(results)
    print(f"\n{passed}/{len(results)} checks passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
