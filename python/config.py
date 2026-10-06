import os
from pathlib import Path
from dotenv import load_dotenv
from sqlalchemy import create_engine
from sqlalchemy.engine import URL

PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / '.env')

DB_USER = os.getenv("POSTGRES_USER", "wbu_admin")
DB_PASS = os.getenv("POSTGRES_PASSWORD", "WattlebrookSecurePass2026!")
DB_HOST = os.getenv("POSTGRES_HOST", "localhost")
DB_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
DB_NAME = os.getenv("POSTGRES_DB", "wattlebrook_db")

DATABASE_URL = URL.create(
    "postgresql+psycopg",
    username=DB_USER,
    password=DB_PASS,
    host=DB_HOST,
    port=DB_PORT,
    database=DB_NAME,
)

def get_db_engine():
    return create_engine(DATABASE_URL)