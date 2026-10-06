import pandas as pd
from sqlalchemy import text
from config import get_db_engine

def validate_results():
    engine = get_db_engine()
    
    print("\n================ PIPELINE VALIDATION RESULTS ================")
    
    with engine.connect() as conn:
        # 1. Verify Pipeline Run Log
        df_runs = pd.read_sql("SELECT run_id, source_name, rows_read, rows_loaded, run_status FROM audit.pipeline_run;", conn)
        print("\n--- 1. Ingestion Pipeline Audit ---")
        print(df_runs.to_string(index=False))

        # 2. Verify Identity Resolution
        df_identity = pd.read_sql("SELECT system_count, count(*) as person_count FROM gold.dim_person GROUP BY system_count ORDER BY system_count;", conn)
        print("\n--- 2. Resolved Identity Footprint ---")
        print(df_identity.to_string(index=False))

        # 3. Masking Leak Verification Check
        leak_query = """
        SELECT 'Matching Real Emails' AS check_type, count(*) AS leak_count 
        FROM test_masked.student m JOIN bronze.sis_student_raw r ON m.email = r.email
        UNION ALL
        SELECT 'Matching Name + DOB', count(*) 
        FROM test_masked.student m JOIN bronze.sis_student_raw r 
        ON m.first_name = r.first_name AND m.last_name = r.last_name AND m.date_of_birth = r.date_of_birth::DATE;
        """
        df_leak = pd.read_sql(leak_query, conn)
        print("\n--- 3. Masking Leak Check (Target: 0) ---")
        print(df_leak.to_string(index=False))

if __name__ == "__main__":
    validate_results()