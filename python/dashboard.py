"""Streamlit dashboard for the Wattlebrook governed data platform.

Read-only: it only runs SELECTs against the reports.* views (plus the silver link
for the person lookup). Run the pipeline first, then:

    pip install streamlit
    streamlit run python/dashboard.py

Connection settings come from .env (same as the pipeline scripts).
"""
import os
from pathlib import Path

import pandas as pd
import psycopg
import altair as alt
import streamlit as st
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

st.set_page_config(page_title="Wattlebrook data platform", layout="wide")


@st.cache_resource
def connect():
    conn = psycopg.connect(
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=os.getenv("POSTGRES_PORT", "5432"),
        dbname=os.getenv("POSTGRES_DB", "wattlebrook_db"),
        user=os.getenv("POSTGRES_USER", "wbu_admin"),
        password=os.getenv("POSTGRES_PASSWORD", ""),
        autocommit=True,
    )
    conn.read_only = True  # the dashboard can never change data
    return conn


@st.cache_data(ttl=60)
def query(sql, params=None):
    with connect().cursor() as cur:
        cur.execute(sql, params)
        cols = [d.name for d in cur.description]
        return pd.DataFrame(cur.fetchall(), columns=cols)


def show(df, **kw):
    st.dataframe(df, hide_index=True, width="stretch", **kw)


STATUS_COLOUR = {"SUCCESS": "#1a7f37", "FAILED": "#cf222e"}


def flow_dot(runs):
    """Graphviz source: one box per pipeline step, coloured by status."""
    lines = ["digraph G { rankdir=LR; bgcolor=transparent; node [shape=box, style=\"rounded,filled\", "
             "fontname=Helvetica, fontcolor=white, fontsize=11, margin=\"0.12,0.06\"]; edge [color=\"#8a94a0\"];"]
    for r in runs.itertuples():
        rows = r.rows_loaded
        sub = f"\\n{int(rows):,} rows" if pd.notna(rows) else ""
        colour = STATUS_COLOUR.get(r.status, "#8a94a0")
        lines.append(f'n{r.run_id} [label="{r.step_name}{sub}\\n{r.seconds}s", fillcolor="{colour}"];')
    ids = list(runs["run_id"])
    for a, b in zip(ids, ids[1:]):
        lines.append(f"n{a} -> n{b};")
    return "\n".join(lines) + "}"


def person_dot(links):
    """Graphviz source: a person node with its source records hanging off it."""
    pid = links.iloc[0].person_id
    colours = {"HIGH": "#1a7f37", "MEDIUM": "#bf8700", "SINGLE": "#8a94a0"}
    out = ["digraph G { rankdir=LR; bgcolor=transparent; node [fontname=Helvetica, fontsize=11]; edge [fontname=Helvetica, fontsize=10];",
           f'p [label="{pid}\\n(hub_person)", shape=ellipse, style=filled, fillcolor="#6639ba", fontcolor=white];']
    for i, r in enumerate(links.itertuples()):
        out.append(f'r{i} [label="{r.source_record_id}\\n{r.system_name}", shape=box, style="rounded,filled", '
                   f'fillcolor="#0969da", fontcolor=white];')
        out.append(f'r{i} -> p [label="{r.match_rule}\\n{r.confidence}", color="{colours.get(r.confidence, "#8a94a0")}", '
                   f'fontcolor="{colours.get(r.confidence, "#8a94a0")}"];')
    return "\n".join(out) + "}"


try:
    connect()
except Exception as e:  # noqa: BLE001
    st.error(f"Cannot connect to the database: {e}")
    st.info("Start it with `docker compose up -d`, run the pipeline, then reload.")
    st.stop()

# The reports views are created by sql/11_reports.sql when the pipeline runs.
# If they are missing, the database was built from older code or never loaded.
with connect().cursor() as _cur:
    _cur.execute("SELECT to_regclass('reports.checks') IS NOT NULL")
    _ready = _cur.fetchone()[0]
if not _ready:
    st.error("The database has no reports views yet (reports.checks is missing).")
    st.markdown(
        "Your database was built from older code or the pipeline has not run. "
        "From the repo root, with Docker running:\n\n"
        "```\ngit pull\ndocker compose down -v\ndocker compose up -d\n"
        "python python/run_pipeline.py\n```\n"
        "Then reload this page. `down -v` wipes the old database so the new schema is created."
    )
    st.stop()

st.title("Wattlebrook University governed data platform")
st.caption("Synthetic data. Every number below is read live from the reports.* views.")

tab_over, tab_health, tab_run, tab_cat, tab_id, tab_ret, tab_mask, tab_lookup = st.tabs(
    ["Overview", "Health checks", "Pipeline run", "Catalogue", "Identity", "Retention", "Masking", "Person lookup"]
)

# -------------------------------------------------------------------- overview
with tab_over:
    runs_o = query("SELECT * FROM reports.pipeline_runs")
    checks_o = query("SELECT * FROM reports.checks")
    ok = int((checks_o["result"] == "PASS").sum())
    c1, c2, c3 = st.columns(3)
    c1.metric("Checks passing", f"{ok} / {len(checks_o)}")
    c2.metric("Pipeline steps", len(runs_o))
    c3.metric("Run time (s)", f"{float(runs_o['seconds'].astype(float).sum()):.1f}")

    st.subheader("1. The pipeline, step by step")
    half = (len(runs_o) + 1) // 2
    st.graphviz_chart(flow_dot(runs_o.iloc[:half]), width="stretch")
    st.graphviz_chart(flow_dot(runs_o.iloc[half:]), width="stretch")

    st.subheader("2. From source rows to people")
    funnel = query("""
        SELECT '1 Source rows' AS stage, (SELECT count(*) FROM src_hrms.employee) + (SELECT count(*) FROM src_sis.student)
               + (SELECT count(*) FROM src_crm.constituent) AS n
        UNION ALL SELECT '2 Bronze rows', (SELECT count(*) FROM bronze.hrms_employee) + (SELECT count(*) FROM bronze.sis_student)
               + (SELECT count(*) FROM bronze.crm_constituent)
        UNION ALL SELECT '3 Silver hub rows', (SELECT count(*) FROM silver.hub_employee) + (SELECT count(*) FROM silver.hub_student)
               + (SELECT count(*) FROM silver.hub_constituent)
        UNION ALL SELECT '4 Linked records', (SELECT count(*) FROM silver.link_person)
        UNION ALL SELECT '5 People (hub_person)', (SELECT count(*) FROM silver.hub_person)
        UNION ALL SELECT '6 Gold dim_person', (SELECT count(*) FROM gold.dim_person)""")
    funnel["n"] = funnel["n"].astype(int)
    chart = (alt.Chart(funnel).mark_bar().encode(
        y=alt.Y("stage:N", sort=None, title=None, axis=alt.Axis(labelLimit=240)),
        x=alt.X("n:Q", title="rows"),
        tooltip=["stage", alt.Tooltip("n:Q", format=",")])
        + alt.Chart(funnel).mark_text(align="left", dx=4).encode(
            y=alt.Y("stage:N", sort=None), x="n:Q", text=alt.Text("n:Q", format=",")))
    st.altair_chart(chart, width="stretch")
    st.caption("Source, bronze, hub and link rows are the same 27,500 records. Identity matching is the step "
               "that collapses them into fewer people.")

    st.subheader("3. Health checks")
    cols = st.columns(5)
    for i, r in enumerate(checks_o.itertuples()):
        good = r.result == "PASS"
        with cols[i % 5]:
            st.markdown(
                f"<div style='border:1px solid {'#1a7f37' if good else '#cf222e'};border-left:6px solid "
                f"{'#1a7f37' if good else '#cf222e'};border-radius:6px;padding:8px 10px;margin-bottom:10px;"
                f"min-height:84px'><b style='color:{'#1a7f37' if good else '#cf222e'}'>{r.result}</b><br>"
                f"<span style='font-size:0.85rem'>{r.check_name}</span><br>"
                f"<span style='font-size:0.75rem;opacity:0.7'>{r.detail or ''}</span></div>",
                unsafe_allow_html=True)

# ---------------------------------------------------------------- health checks
with tab_health:
    checks = query("SELECT * FROM reports.checks")
    passed = int((checks["result"] == "PASS").sum())
    c1, c2 = st.columns(2)
    c1.metric("Checks passing", f"{passed} / {len(checks)}")
    c2.metric("Failing", len(checks) - passed)

    def colour(v):
        return {"PASS": "color: #1a7f37; font-weight: 600", "FAIL": "color: #cf222e; font-weight: 600"}.get(v, "")

    st.dataframe(checks.style.map(colour, subset=["result"]), hide_index=True, width="stretch")
    if (checks["result"] == "FAIL").any():
        st.warning(
            "A FAIL is real, not a bug in the dashboard. For example the retention check fails if records "
            "passed their use-by date since the last pipeline run. Re-run `python python/run_pipeline.py`."
        )

# ------------------------------------------------------------------ pipeline run
with tab_run:
    runs = query("SELECT * FROM reports.pipeline_runs")
    st.subheader("Steps of the most recent run")
    show(runs)
    if not runs.empty:
        st.bar_chart(runs.set_index("step_name")["seconds"].astype(float), y_label="seconds")
    st.subheader("Failed steps (all time)")
    failed = query("SELECT * FROM reports.failed_steps")
    if failed.empty:
        st.success("No failed steps logged.")
    else:
        show(failed)

# ------------------------------------------------------------------- catalogue
with tab_cat:
    cat = query("SELECT * FROM reports.catalogue")
    c1, c2, c3 = st.columns(3)
    c1.metric("Datasets", len(cat))
    c2.metric("With personal data", int((cat["pii_columns"] > 0).sum()))
    c3.metric("Without lineage", int((cat["comes_from"].str.startswith("unknown")).sum()))
    layers = ["All"] + sorted(cat["layer"].unique())
    pick = st.selectbox("Layer", layers)
    show(cat if pick == "All" else cat[cat["layer"] == pick])

# -------------------------------------------------------------------- identity
with tab_id:
    acc = query("SELECT * FROM reports.identity_accuracy").iloc[0]
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Real people (answer key)", f"{int(acc.real_people):,}")
    c2.metric("People found", f"{int(acc.people_found):,}")
    c3.metric("Precision", f"{acc.precision_pct}%")
    c4.metric("Recall", f"{acc.recall_pct}%")
    st.caption(
        f"{int(acc.correct_links):,} correct links, {int(acc.wrong_links):,} wrong links, "
        f"{int(acc.missed_links):,} missed links."
    )
    left, right = st.columns(2)
    with left:
        st.subheader("Which systems each person is in")
        overlap = query("SELECT * FROM reports.identity_overlap")
        st.bar_chart(overlap.set_index("systems")["people"])
        show(overlap)
    with right:
        st.subheader("How each source record was matched")
        rules = query(
            "SELECT match_rule, confidence, count(*) AS link_rows FROM silver.link_person "
            "GROUP BY 1, 2 ORDER BY 3 DESC"
        )
        show(rules)
        st.caption("R1 same email, R2 same surname + date of birth + phone, R3 same name + date of birth.")

# ------------------------------------------------------------------- retention
with tab_ret:
    st.subheader("What retention did on its last run")
    show(query("SELECT * FROM reports.retention_results"))
    st.subheader("Personal data past its use-by date right now")
    overdue = query(
        "SELECT policy_id, count(*) AS records, min(retention_expiry_date) AS oldest "
        "FROM reports.retention_overdue GROUP BY 1 ORDER BY 1"
    )
    if overdue.empty:
        st.success("Nothing overdue.")
    else:
        st.warning("These records expired since the last run. The next pipeline run will clear them.")
        show(overdue)

# --------------------------------------------------------------------- masking
with tab_mask:
    st.caption("Counts of real personal data found in the masked test tables. Every count should be 0.")
    mask = query("SELECT * FROM reports.masking_check")
    show(mask)
    if int(mask["found"].sum()) == 0:
        st.success("No real personal data in the masked test tables.")
    else:
        st.error("Real personal data leaked into the test tables.")

# --------------------------------------------------------------- person lookup
with tab_lookup:
    st.caption("Type any source ID (for example STU0000001, EMP000001 or CRM0000001) to see the person it belongs to.")
    sid = st.text_input("Source record ID", value="STU0000001").strip().upper()
    if sid:
        links = query(
            "SELECT l.person_id, l.system_name, l.source_record_id, l.match_rule, l.confidence "
            "FROM silver.link_person l "
            "WHERE l.person_id IN (SELECT person_id FROM silver.link_person WHERE source_record_id = %s) "
            "ORDER BY l.system_name",
            (sid,),
        )
        if links.empty:
            st.info("No record with that ID.")
        else:
            st.write(f"Person **{links.iloc[0].person_id}** is made of {len(links)} source record(s):")
            st.graphviz_chart(person_dot(links), width="content")
            show(links)