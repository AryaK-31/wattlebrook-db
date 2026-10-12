"""Load the synthetic workbook into the simulated environment.

* HRMS, SIS and ADV_CRM sheets -> the three source-system schemas, with proper
  column types (dates as DATE, money as NUMERIC). The source systems are the
  "operational" side; the governed platform starts at bronze.
* Shadow_Extracts -> one table per environment in dev_sandbox. This recreates
  the uncontrolled copies found by the 2026 audit, so it is done only once
  per database: the retention engine is supposed to make them go away.
* Identity_Answer_Key and DQ_Test_Cases -> qa schema, used only by reports
  and tests to score the pipeline. They never reach the source systems.
"""

import pandas as pd
from sqlalchemy import Date, Integer, Numeric, Text, text

from config import WORKBOOK, run_sql

SOURCE_SHEETS = {
    # sheet: (schema, table, owner, {column: SQLAlchemy type})
    "HRMS": ("src_hrms", "employee", "People & Culture", {
        "date_of_birth": Date, "employment_start_date": Date, "employment_end_date": Date}),
    "SIS": ("src_sis", "student", "Student Administration", {
        "date_of_birth": Date, "last_activity_date": Date, "enrolment_year": Integer,
        "completion_year": Integer, "gpa": Numeric(4, 2), "outstanding_fees_aud": Numeric(12, 2)}),
    "ADV_CRM": ("src_crm", "constituent", "Advancement Office", {
        "date_of_birth": Date, "last_contact_date": Date, "alumni_year": Integer,
        "lifetime_donation_aud": Numeric(12, 2), "engagement_score": Integer}),
}
SHADOW_TYPES = {"extracted_date": Date, "retention_expiry_date": Date, "last_accessed_date": Date,
                "approved_retention_days": Integer, "date_of_birth": Date}


def _typed(df, types):
    """Convert workbook text into the declared types; every other column stays TEXT."""
    df = df.copy()
    for col, typ in types.items():
        if typ is Date:
            df[col] = pd.to_datetime(df[col], errors="raise").dt.date
        elif typ is Integer:
            df[col] = pd.to_numeric(df[col]).astype("Int64")
        else:
            df[col] = pd.to_numeric(df[col])
    df = df.astype(object).where(df.notna(), None)
    dtype = {c: Text() for c in df.columns}
    dtype.update({c: (t() if isinstance(t, type) else t) for c, t in types.items()})
    return df, dtype


def _write(conn, df, schema, table, dtype):
    """Replace the rows of a table, keeping the table (and any views on it) in place."""
    exists = conn.execute(text("SELECT to_regclass(:t) IS NOT NULL"), {"t": f"{schema}.{table}"}).scalar()
    if exists:
        run_sql(conn, f'TRUNCATE TABLE "{schema}"."{table}"')
    df.to_sql(table, conn, schema=schema, if_exists="append", index=False, dtype=dtype, chunksize=5000)


def _read(sheet):
    return pd.read_excel(WORKBOOK, sheet_name=sheet, dtype=str)


def seed_sources(conn, run_id):
    """Load the three source systems and the QA answer key. Returns rows loaded."""
    total = 0
    for sheet, (schema, table, owner, types) in SOURCE_SHEETS.items():
        df, dtype = _typed(_read(sheet), types)
        _write(conn, df, schema, table, dtype)
        total += len(df)
        params = {"r": run_id, "p": f"{WORKBOOK.name}#{sheet}", "c": f"{schema}.{table}", "n": len(df)}
        conn.execute(text("CALL audit.record_lineage(:r, :p, :c, 'EXTRACT', :n, FALSE)"), params)
        conn.execute(text("CALL audit.register_dataset(:d, 'source', 'operational', TRUE, FALSE, :o)"),
                     {"d": f"{schema}.{table}", "o": owner})
        print(f"  {schema}.{table:<12} {len(df):>6,} rows")

    key = _read("Identity_Answer_Key").astype(object)
    _write(conn, key.where(key.notna(), None), "qa", "identity_answer_key", {c: Text() for c in key.columns})
    dq = _read("DQ_Test_Cases")
    _write(conn, dq, "qa", "dq_test_cases", {c: Text() for c in dq.columns})
    conn.execute(text("CALL audit.set_step_rows(:r, :n, :n)"), {"r": run_id, "n": total})
    return total


def shadow_already_seeded(conn):
    return conn.execute(text(
        "SELECT EXISTS (SELECT 1 FROM audit.pipeline_run "
        "WHERE step_name = 'seed_shadow_copies' AND run_status = 'SUCCESS')")).scalar()


def seed_shadow_copies(conn, run_id):
    """Recreate the uncontrolled copies: one dev_sandbox table per environment. Not catalogued on purpose."""
    df, dtype = _typed(_read("Shadow_Extracts"), SHADOW_TYPES)
    for env, part in df.groupby("environment"):
        _write(conn, part.drop(columns=["environment"]), "dev_sandbox", env,
               {c: t for c, t in dtype.items() if c != "environment"})
        print(f"  dev_sandbox.{env:<28} {len(part):>6,} rows")
    conn.execute(text("CALL audit.set_step_rows(:r, :n, :n)"), {"r": run_id, "n": len(df)})
    return len(df)
