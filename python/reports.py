"""Print the pipeline reports and save them as CSV files and charts.

    python python/reports.py

Output goes to reports/output/: one CSV per report view, plus four charts.
"""

import matplotlib

matplotlib.use("Agg")  # no display needed
import matplotlib.pyplot as plt
import pandas as pd
from sqlalchemy import text

from config import REPORT_DIR, get_db_engine

REPORTS = [
    ("r01_pipeline_runs", "R1  Pipeline audit (latest batch)"),
    ("r01b_failed_steps", "R1b Failed steps ever recorded"),
    ("r02_retention_due_summary", "R2  Records past their retention date (latest review)"),
    ("r02c_retention_history", "R2c Retention reviews over time"),
    ("r03_purge_results", "R3  Retention actions taken"),
    ("r04_pii_holdings_before_after", "R4  Personal-data holdings before and after retention"),
    ("r05_catalogue_lineage", "R5  Catalogue and lineage"),
    ("r06_identity_overlap", "R6  People by number of systems"),
    ("r07_identity_accuracy", "R7  Identity matching accuracy vs answer key"),
    ("r07b_identity_errors_by_confidence", "R7b Wrong merges by confidence"),
    ("r08_masking_leak_check", "R8  Masking leak check (target 0)"),
    ("r09_dq_issues", "R9  Data-quality findings"),
    ("r10_enrolments_by_program", "R10 Enrolments by program (star schema)"),
]
COLORS = {"before": "#c0504d", "after": "#4f81bd", "neutral": "#4f81bd", "muted": "#9bbb59"}


def save_chart(fig, name):
    path = REPORT_DIR / f"{name}.png"
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)
    return path


def chart_retention(df):
    by_policy = df[df.policy_id != "RP-05"].groupby(["policy_id", "policy_name"], as_index=False)["records_due"].sum()
    fig, ax = plt.subplots(figsize=(8, 4))
    if by_policy.empty:
        ax.text(0.5, 0.5, "Nothing past its retention date in the latest review.\n"
                "(Run with --reset to see the 2026 audit baseline.)", ha="center", va="center", fontsize=11)
        ax.set_axis_off()
    else:
        labels = [f"{p}\n{n}" for p, n in zip(by_policy.policy_id, by_policy.policy_name.str.wrap(28))]
        bars = ax.bar(labels, by_policy.records_due, color=COLORS["before"])
        ax.bar_label(bars, fmt="{:,.0f}")
        ax.set_ylabel("Records past retention date")
        ax.tick_params(axis="x", labelsize=8)
        ax.spines[["top", "right"]].set_visible(False)
    ax.set_title("Personal data past its retention date, by policy")
    return save_chart(fig, "chart_retention_due")


def chart_holdings(df):
    df = df[df.layer.isin(["dev_sandbox", "silver", "bronze", "test_masked"])].copy()
    df = df[(df.real_pii_rows_before > 0) | (df.real_pii_rows_after > 0) | (df.layer == "test_masked")]
    df["label"] = df.dataset.str.split(".").str[1] + "  (" + df.layer + ")"
    df = df.sort_values("real_pii_rows_before")
    fig, ax = plt.subplots(figsize=(8, 5))
    y = range(len(df))
    ax.barh([i + 0.2 for i in y], df.real_pii_rows_before, height=0.4, color=COLORS["before"], label="Before retention")
    ax.barh([i - 0.2 for i in y], df.real_pii_rows_after, height=0.4, color=COLORS["after"], label="After retention")
    ax.set_yticks(list(y), df.label, fontsize=8)
    ax.set_xlabel("Rows holding real personal data")
    ax.set_title("Real personal data held, before and after the retention run")
    ax.legend(frameon=False)
    ax.spines[["top", "right"]].set_visible(False)
    return save_chart(fig, "chart_pii_before_after")


def chart_overlap(df):
    fig, ax = plt.subplots(figsize=(8, 4))
    bars = ax.bar(df.systems.str.replace(" + ", "\n+ ", regex=False), df.people,
                  color=[COLORS["muted"] if n == 1 else COLORS["neutral"] for n in df.system_count])
    ax.bar_label(bars, fmt="{:,.0f}")
    ax.set_ylabel("People")
    ax.set_title("Resolved people by the systems they appear in")
    ax.tick_params(axis="x", labelsize=8)
    ax.spines[["top", "right"]].set_visible(False)
    return save_chart(fig, "chart_identity_overlap")


def chart_leaks(df):
    df = df[df.target.notna()]
    fig, ax = plt.subplots(figsize=(8, 4))
    ax.barh(df.check_name, df.failures, color=COLORS["after"])
    for i, v in enumerate(df.failures):
        ax.text(v, i, f" {v}", va="center")
    ax.set_xlim(0, max(1, df.failures.max() * 1.2))
    ax.invert_yaxis()
    ax.tick_params(axis="y", labelsize=8)
    ax.set_xlabel("Failures (target: 0)")
    ax.set_title("Masked test data: leak checks")
    ax.spines[["top", "right"]].set_visible(False)
    return save_chart(fig, "chart_masking_leaks")


def main():
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    engine = get_db_engine()
    frames = {}
    pd.set_option("display.width", 200)
    pd.set_option("display.max_columns", 20)
    pd.set_option("display.max_colwidth", 60)
    with engine.connect() as conn:
        for view, title in REPORTS:
            df = pd.read_sql(text(f"SELECT * FROM reports.{view}"), conn)
            frames[view] = df
            df.to_csv(REPORT_DIR / f"{view}.csv", index=False)
            print(f"\n=== {title} ({len(df)} rows)")
            print(df.head(25).to_string(index=False) if len(df) else "(none)")
    charts = [chart_retention(frames["r02_retention_due_summary"]),
              chart_holdings(frames["r04_pii_holdings_before_after"]),
              chart_overlap(frames["r06_identity_overlap"]),
              chart_leaks(frames["r08_masking_leak_check"])]
    print(f"\nSaved {len(REPORTS)} CSV files and {len(charts)} charts to {REPORT_DIR}")


if __name__ == "__main__":
    main()
