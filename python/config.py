"""Database connection settings, read from the .env file in the project root."""

import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy import create_engine
from sqlalchemy.engine import URL

PROJECT_ROOT = Path(__file__).resolve().parent.parent
WORKBOOK = PROJECT_ROOT / "data" / "Wattlebrook_Synthetic_Data.xlsx"
SQL_DIR = PROJECT_ROOT / "sql"
REPORT_DIR = PROJECT_ROOT / "reports" / "output"

load_dotenv(PROJECT_ROOT / ".env")


def _require(name):
    value = os.getenv(name)
    if not value:
        sys.exit(f"Missing {name}. Copy .env.example to .env and fill it in.")
    return value


def get_db_engine():
    url = URL.create(
        "postgresql+psycopg",
        username=_require("POSTGRES_USER"),
        password=_require("POSTGRES_PASSWORD"),
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=int(os.getenv("POSTGRES_PORT", "5432")),
        database=_require("POSTGRES_DB"),
    )
    return create_engine(url)


def run_sql(conn, sql):
    """Run SQL text exactly as written (no bind-parameter parsing), on an open SQLAlchemy connection."""
    conn.connection.driver_connection.execute(sql)
