"""Wattlebrook governance dashboard.

Reads the reports.r01 ... r10 views from Postgres and charts each one.
Run:  streamlit run python/dashboard.py
"""
import os

import pandas as pd
import sqlalchemy as sa
import streamlit as st

st.set_page_config(page_title="Wattlebrook Governance Dashboard", layout="wide")

# Read-only role that can only read the reports schema:
#   CREATE ROLE dashboard_ro LOGIN PASSWORD 'change-me';
#   GRANT USAGE ON SCHEMA reports TO dashboard_ro;
#   GRANT SELECT ON ALL TABLES IN SCHEMA reports TO dashboard_ro;
# Re-run both GRANTs after each pipeline run: the reports schema is rebuilt each time.
DB_URL = os.getenv(
    "DASHBOARD_DB_URL",
    "postgresql+psycopg://dashboard_ro:change-me@localhost:5432/wattlebrook_db",
)


@st.cache_resource
def get_engine():
    return sa.create_engine(DB_URL)


@st.cache_data(ttl=60)
def list_reports():
    q = sa.text(
        """
        SELECT table_name
        FROM information_schema.views
        WHERE table_schema = 'reports' AND table_name ~ '^r[0-9]+'
        ORDER BY table_name
        """
    )
    with get_engine().connect() as conn:
        return [r[0] for r in conn.execute(q)]


@st.cache_data(ttl=60)
def load_report(view_name: str) -> pd.DataFrame:
    # view_name comes from information_schema, quoted as an identifier
    safe = view_name.replace('"', '""')
    with get_engine().connect() as conn:
        return pd.read_sql(sa.text(f'SELECT * FROM reports."{safe}"'), conn)


def pretty(view_name: str) -> str:
    code, _, rest = view_name.partition("_")
    return f"{code.upper()}  {rest.replace('_', ' ').title()}"


def draw(df: pd.DataFrame):
    """Bar chart: first text column on the x axis, numeric columns as bars."""
    if df.empty:
        st.info("No rows.")
        return
    numeric = df.select_dtypes("number").columns.tolist()
    text = [c for c in df.columns if c not in numeric]

    # PASS/FAIL style checks (e.g. the masking leak check)
    status_cols = [
        c for c in text
        if df[c].astype(str).str.upper().isin(["PASS", "FAIL"]).all()
    ]
    if status_cols:
        col = status_cols[0]
        fails = (df[col].astype(str).str.upper() == "FAIL").sum()
        st.metric("Checks failing", int(fails), delta=None)
        st.dataframe(
            df.style.map(
                lambda v: "color: #c0392b; font-weight: 600"
                if str(v).upper() == "FAIL" else "color: #1e8449",
                subset=[col],
            ),
            width="stretch",
        )
        return

    x_candidates = [c for c in text if c not in status_cols]
    if x_candidates and numeric:
        x = x_candidates[0]
        st.bar_chart(df, x=x, y=numeric, stack=False)
    elif numeric and len(df) == 1:
        cols = st.columns(len(numeric))
        for c, name in zip(cols, numeric):
            c.metric(name.replace("_", " "), f"{df[name].iloc[0]:,}")
    with st.expander("Data"):
        st.dataframe(df, width="stretch")


# ---- Page ----
st.title("Wattlebrook University: Shadow Data Governance")
st.caption("Built from the report views. No names, emails, phones or birth dates are shown.")

try:
    reports = list_reports()
except Exception as e:
    st.error(f"Can't connect to the database: {e}")
    st.stop()

if not reports:
    st.warning("No reports.r* views found. Run python/run_pipeline.py first.")
    st.stop()

with st.sidebar:
    st.header("Reports")
    chosen = st.multiselect("Show", reports, default=reports, format_func=pretty)
    if st.button("Reload data"):
        st.cache_data.clear()
        st.rerun()

# R8 recomputes pseudonyms with the secret masking key, so the read-only
# dashboard role cannot (and should not) run it.
NEEDS_MASKING_KEY = {"r08_masking_leak_check"}

for view in chosen:
    st.subheader(pretty(view))
    if view in NEEDS_MASKING_KEY:
        st.info("This check needs the masking key, which the dashboard role cannot read. "
                "Run it as the admin user (sql/demo_walkthrough.sql step 7c) or with validate_pipeline.py.")
        st.divider()
        continue
    try:
        draw(load_report(view))
    except Exception as e:
        st.error(f"{view}: {e}")
    st.divider()
