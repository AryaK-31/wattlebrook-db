import pandas as pd
from pathlib import Path
from config import get_db_engine

PROJECT_ROOT = Path(__file__).resolve().parent.parent

def load_excel_to_postgres(excel_path=None, engine=None):
    if excel_path is None:
        excel_path = PROJECT_ROOT / 'data' / 'USYD_Synthetic_Shadow_Data.xlsx'
    if engine is None:
        engine = get_db_engine()
    xls = pd.ExcelFile(excel_path)
    
    print("Loading sheets into database...")
    
    # 1. Load HRMS
    df_hrms = pd.read_excel(xls, sheet_name='HRMS')
    df_hrms.to_sql('employee', engine, schema='src_hrms', if_exists='replace', index=False)
    print(f"Loaded {len(df_hrms)} rows into src_hrms.employee")

    # 2. Load SIS
    df_sis = pd.read_excel(xls, sheet_name='SIS')
    df_sis.to_sql('student', engine, schema='src_sis', if_exists='replace', index=False)
    print(f"Loaded {len(df_sis)} rows into src_sis.student")

    # 3. Load ADV_CRM
    df_crm = pd.read_excel(xls, sheet_name='ADV_CRM')
    df_crm.to_sql('constituent', engine, schema='src_crm', if_exists='replace', index=False)
    print(f"Loaded {len(df_crm)} rows into src_crm.constituent")

    # 4. Load Shadow Extracts into Sandbox
    df_shadow = pd.read_excel(xls, sheet_name='Shadow_Extracts')
    df_shadow.to_sql('shadow_extracts_all', engine, schema='dev_sandbox', if_exists='replace', index=False)
    print(f"Loaded {len(df_shadow)} rows into dev_sandbox.shadow_extracts_all")

if __name__ == "__main__":
    load_excel_to_postgres()