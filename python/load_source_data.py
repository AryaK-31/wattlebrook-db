"""Copy the sheets of the Excel workbook into the source tables.

The tables themselves are defined in sql/02_source_tables.sql.
"""

from pathlib import Path

import pandas as pd

WORKBOOK = Path(__file__).resolve().parent.parent / "data" / "Wattlebrook_Synthetic_Data.xlsx"

SOURCE_SHEETS = {
    "HRMS": "src_hrms.employee",
    "SIS": "src_sis.student",
    "ADV_CRM": "src_crm.constituent",
    "Identity_Answer_Key": "qa.identity_answer_key",
}


def copy_sheet(conn, sheet, table):
    """Replace the rows of a table with the rows of one sheet. Returns the number of rows."""
    df = pd.read_excel(WORKBOOK, sheet_name=sheet, dtype=str)
    df = df.astype(object).where(df.notna(), None)  # empty cells become NULL

    conn.execute(f"TRUNCATE {table}")
    columns = ", ".join(df.columns)
    with conn.cursor().copy(f"COPY {table} ({columns}) FROM STDIN") as copy:
        for row in df.itertuples(index=False):
            copy.write_row(row)
    print(f"    {table:<28} {len(df):>6} rows")
    return len(df)


def load_sources(conn, run_id):
    """Fill the three source systems and the answer key."""
    total = 0
    for sheet, table in SOURCE_SHEETS.items():
        rows = copy_sheet(conn, sheet, table)
        total += rows
        conn.execute(
            "INSERT INTO audit.lineage (run_id, source, target, operation, row_count) VALUES (%s, %s, %s, 'EXTRACT', %s)",
            (run_id, f"{WORKBOOK.name} / {sheet}", table, rows),
        )
    conn.execute("UPDATE audit.pipeline_run SET rows_loaded = %s WHERE run_id = %s", (total, run_id))


def load_shadow_copies(conn, run_id):
    """Recreate the copies found by the audit. Not registered in the catalogue, on purpose."""
    rows = copy_sheet(conn, "Shadow_Extracts", "dev_sandbox.shadow_extracts")
    conn.execute("UPDATE audit.pipeline_run SET rows_loaded = %s WHERE run_id = %s", (rows, run_id))
