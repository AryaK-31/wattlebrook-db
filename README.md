# Wattlebrook University Governed Data Platform

A PostgreSQL and Python demonstration of a governed university data platform. It loads the bundled synthetic workbook into source schemas, ingests into bronze, resolves identities, provisions a masked test dataset, runs retention handling, and builds a gold identity dimension.

## Tech Stack
- **Database**: PostgreSQL 16
- **Containerization**: Docker / Docker Compose
- **Pipeline Driver**: Python 3.11+ (Pandas, SQLAlchemy, psycopg 3)
- **Architecture**: Medallion Architecture (Bronze, Silver Data Vault 2.0, Gold Star Schema, `test_masked`, `audit`)

## Run on Windows

Prerequisites: Python 3.11 or newer and Docker Desktop with Compose enabled.

1. Create the local environment file and Python virtual environment:

	```powershell
	Copy-Item .env.example .env
	python -m venv .venv
	.\.venv\Scripts\python.exe -m pip install -r requirements.txt
	```

2. Start PostgreSQL and wait for it to become healthy:

	```powershell
	docker compose up -d --wait
	```

3. Run the end-to-end pipeline and validation:

	```powershell
	.\.venv\Scripts\python.exe python\run_pipeline.py
	.\.venv\Scripts\python.exe python\validate_pipeline.py
	```

The pipeline initializes schemas and procedures, loads the workbook in `data/`, then processes all layers. It can be rerun; source tables are reloaded and bronze tables are replaced on each run. Use `docker compose down` to stop the local database.