# Wattlebrook University Governed Data Platform

[![Watch the Group 2 Wattlebrooke university shadow data demo](https://img.youtube.com/vi/_rLFbb1bO5Y/0.jpg)](https://www.youtube.com/watch?v=_rLFbb1bO5Y)

A small PostgreSQL prototype that fixes the four problems from Assignment 1:

| Problem | What the prototype does | Where |
|---|---|---|
| Data was copied by hand | An automatic pipeline: source systems → bronze → silver (Data Vault) → gold (star schema). Every step is logged. | `04_bronze.sql`, `05_silver_vault.sql`, `10_gold.sql` |
| Test copies held real personal data | Masked copies of all three systems for developers | `09_masking.sql` |
| Nobody knew where copies went | A catalogue of every table, lineage for every data movement, and a scan that finds unregistered tables | `03_audit.sql`, `07_catalogue_scan.sql` |
| Nothing was ever deleted | Every record has a use-by date; expired personal data is anonymised and expired copies are deleted | `08_retention.sql` |
| One person, three unlinked records | Identity matching links the HRMS, SIS and CRM records of the same person | `06_identity.sql` |

All data is synthetic. Nobody in it is a real person.

## How to run

You need Python 3.11+ and Docker Desktop.

```bash
cp .env.example .env              # Windows: Copy-Item .env.example .env
python -m venv .venv
.venv/bin/pip install -r requirements.txt          # Windows: .venv\Scripts\pip ...
docker compose up -d --wait

.venv/bin/python python/run_pipeline.py --reset    # Windows: .venv\Scripts\python ...
```

`--reset` deletes everything and starts from the state the 2026 audit found. Without it, the pipeline runs again on top of the existing data, which is safe to repeat.

Open psql and look at the results:

```bash
docker exec -it wbu_postgres_db psql -U wbu_admin -d wattlebrook_db
```

```sql
SELECT * FROM reports.checks;   -- end-to-end test, every row should be PASS
```

`sql/demo_queries.sql` has the queries for the presentation, including how to show a failed step.

## Project layout

```
data/Wattlebrook_Synthetic_Data.xlsx   the synthetic data
python/load_source_data.py             copies the Excel sheets into the source tables
python/run_pipeline.py                 runs the SQL files, then each step in order
sql/01 ... 11                          the platform, one file per part (run in order)
sql/demo_queries.sql                   queries for the demo
```

## Pipeline steps

| Step | What happens |
|---|---|
| load_shadow_copies | First run only. 27,500 old test copies go into `dev_sandbox.shadow_extracts`, not registered anywhere. |
| load_sources | The HRMS, SIS and CRM sheets are copied into `src_hrms`, `src_sis` and `src_crm`. |
| bronze_* | Each source table is copied into bronze with the run ID and load time. Row counts must match. |
| silver_vault | Names, emails and phone numbers are cleaned and loaded into hubs and satellites. A new satellite row is only added when the data changed. |
| identity_matching | Records are grouped into people (rules below). |
| catalogue_scan | Personal-data columns are listed, and any unregistered table is added as `FOUND_BY_SCAN`. |
| retention | Expired personal data is anonymised and expired copies are deleted (policies below). |
| masked_test_data | Masked copies of the three systems are rebuilt. |
| gold | The star schema is rebuilt. |

Each step runs in its own transaction. If a step fails, its changes are rolled back, but the failure stays in `audit.pipeline_run`.

### Identity matching rules

| Rule | Match | Confidence |
|---|---|---|
| R1 | same email | HIGH |
| R2 | same surname, date of birth and phone | HIGH |
| R3 | same first name, surname and date of birth, in different systems | MEDIUM |

If A matches B and B matches C, all three are the same person.

### Retention policies

| Policy | Applies to | Use-by date | Action |
|---|---|---|---|
| RP-01 | students who completed or withdrew | last activity + 7 years | anonymise |
| RP-02 | former staff | end of employment + 7 years | anonymise |
| RP-03 | CRM contacts who are not donors | last contact + 7 years | anonymise |
| RP-04 | shadow copies | the copy's approved expiry date | delete |

Anonymising keeps the record, for example a student's program and results, but removes the name, date of birth, email, phone, address, visa status, tax file number and bank details. The remaining shadow copies are still inside their approved date, so the table is locked (quarantined) instead of dropped.

## Reports

All reports are SQL views in the `reports` schema.

| View | Shows |
|---|---|
| `reports.checks` | end-to-end test (10 checks) |
| `reports.pipeline_runs` | every step of the last run |
| `reports.failed_steps` | every failed step |
| `reports.retention_results` | what retention removed, before and after |
| `reports.retention_overdue` | personal data past its use-by date (empty after a run) |
| `reports.catalogue` | every table, owner, personal-data columns and where its data came from |
| `reports.identity_overlap` | people found in 1, 2 or 3 systems |
| `reports.identity_accuracy` | matching precision and recall against the answer key |
| `reports.masking_check` | real personal data found in the masked tables (all 0) |

## Results from a clean run (13 Oct 2026)

- **Retention:** 6,755 students, 560 former staff and 1,651 CRM contacts anonymised. 25,343 of 27,500 shadow copies deleted; the 2,157 left are quarantined.
- **Identity:** 27,500 records grouped into 20,399 people (the real number is 20,200). Precision 99.81%, recall 97.03%. The mistakes come from different people who share a name and date of birth, which is why R3 is only MEDIUM confidence.
- **Masking:** 18,534 masked rows, no real personal data found.
- **Checks:** 10 of 10 pass.

Retention uses today's date, so later runs can give slightly different numbers.

## Limitations

- The data fabric and test-data tools recommended in Assignment 1 are imitated with Postgres schemas and procedures.
- Retention covers the platform and the shadow copies, not the source systems themselves.
- The scan finds personal data by column name only.
- The masking key is stored in the same database. In a real system it would be kept in a secrets manager.
