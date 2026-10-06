from pathlib import Path
from sqlalchemy import text
from config import get_db_engine
from load_source_data import load_excel_to_postgres

PROJECT_ROOT = Path(__file__).resolve().parent.parent

def run_sql_file(filename, engine):
    filepath = PROJECT_ROOT / 'sql' / filename
    print(f"Executing {filepath}...")
    with open(filepath, 'r', encoding='utf-8') as f:
        sql_content = f.read()
    
    with engine.begin() as conn:
        conn.execute(text(sql_content))

def execute_pipeline():
    engine = get_db_engine()
    
    # Step 1: Initialize SQL DDL & Procedures
    sql_files = [
        '01_init_schemas.sql',
        '02_bronze_ingestion.sql',
        '03_silver_vault_and_identity.sql',
        '04_test_masked_engine.sql',
        '05_active_metadata_catalog.sql',
        '06_retention_purge_engine.sql',
        '07_gold_star_schema.sql'
    ]
    for sql_file in sql_files:
        run_sql_file(sql_file, engine)

    # Source schemas are created by the first SQL script; populate them before ingestion.
    load_excel_to_postgres(PROJECT_ROOT / 'data' / 'USYD_Synthetic_Shadow_Data.xlsx', engine=engine)

    # Step 2: Execute Ingestion and Layer Transforms
    with engine.begin() as conn:
        print("Executing Bronze Ingestion...")
        conn.execute(text("CALL bronze.load_source('src_hrms.employee', 'bronze.hrms_employee_raw', 'HRMS');"))
        conn.execute(text("CALL bronze.load_source('src_sis.student', 'bronze.sis_student_raw', 'SIS');"))
        conn.execute(text("CALL bronze.load_source('src_crm.constituent', 'bronze.crm_constituent_raw', 'CRM');"))

        print("Executing Silver Identity Resolution...")
        conn.execute(text("CALL silver.resolve_identities();"))

        print("Provisioning Masked Data Layer...")
        conn.execute(text("CALL test_masked.provision_masked_data();"))

        print("Executing Retention Engine (Live Purge)...")
        conn.execute(text("CALL audit.run_retention(false);"))

        print("Building Gold Star Schema...")
        conn.execute(text("CALL gold.build_star_schema();"))

    print("Pipeline Execution Completed Successfully.")

if __name__ == "__main__":
    execute_pipeline()