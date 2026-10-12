"""Show the effect of the email indexes with EXPLAIN ANALYZE.

    python python/performance_demo.py

The query is a subject access request: "find every record we hold for this
email address" across the three PII satellites. It runs twice: first with the
email indexes temporarily dropped (inside a transaction that is rolled back,
so nothing changes), then with them in place. Output is also saved to
reports/output/performance_demo.txt.
"""

from sqlalchemy import text

from config import REPORT_DIR, get_db_engine

INDEXES = ["silver.ix_sat_student_pii_email", "silver.ix_sat_employee_pii_email", "silver.ix_sat_constituent_pii_email"]
QUERY = """
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT 'SIS' AS system, h.sis_student_id AS record_id, s.load_dts
  FROM silver.sat_student_pii s JOIN silver.hub_student h USING (student_hk) WHERE s.email = :email
UNION ALL
SELECT 'HRMS', h.hr_employee_id, s.load_dts
  FROM silver.sat_employee_pii s JOIN silver.hub_employee h USING (employee_hk) WHERE s.email = :email
UNION ALL
SELECT 'ADV_CRM', h.crm_contact_id, s.load_dts
  FROM silver.sat_constituent_pii s JOIN silver.hub_constituent h USING (constituent_hk) WHERE s.email = :email
"""


def explain(conn, email):
    plan = [row[0] for row in conn.execute(text(QUERY), {"email": email})]
    timing = next((line for line in plan if line.startswith("Execution Time")), "")
    return plan, timing


def main():
    engine = get_db_engine()
    out = []
    with engine.connect() as conn:
        email = conn.execute(text(
            "SELECT email FROM silver.sat_constituent_pii WHERE email IS NOT NULL ORDER BY email LIMIT 1")).scalar()
        out.append(f"Subject access request for: {email}\n")
        conn.rollback()  # end the autobegun read so the demo transaction starts cleanly

        trans = conn.begin()
        for ix in INDEXES:
            conn.execute(text(f"DROP INDEX {ix}"))
        plan, timing = explain(conn, email)
        trans.rollback()  # indexes come back untouched
        out += ["--- WITHOUT email indexes (sequential scans) ---", *plan, ""]
        slow = timing

        plan, timing = explain(conn, email)
        out += ["--- WITH email indexes ---", *plan, ""]
        out.append(f"Summary: without indexes {slow.split(':')[1].strip()}, with indexes {timing.split(':')[1].strip()}")

    report = "\n".join(out)
    print(report)
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    (REPORT_DIR / "performance_demo.txt").write_text(report + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
