# Wattlebrook University Governed Data Platform

A PostgreSQL and Python prototype of a governed data platform for Wattlebrook University. It fixes the four gaps found in Assignment 1, each with a step you can run and a report that proves it works:

| Assignment 1 gap | Fix in this prototype | Proof |
|---|---|---|
| No governed integration: data copied by hand | Automated pipeline from the three source systems into bronze → silver (Data Vault 2.0) → gold (star schema), with every step logged | R1 pipeline audit, row-count reconciliation in the tests |
| No masking: test copies held real personal data | `test_masked` schema for all three systems, with keyed-hash pseudonyms and fake values | R8 leak check (9 checks, all 0) |
| No lineage or catalogue: nobody knew where copies went | `audit.dataset` catalogue, `audit.lineage` written by every step, and a discovery scan that finds unregistered copies | R5 catalogue and lineage |
| No retention: copies kept forever | Policy-driven retention with a dry-run review, before/after logging and an erasure register | R2 records past retention, R3 purge results, R4 before/after |
| Bonus: one person, three unlinked records | Identity resolution into a person hub, scored against an answer key | R6 overlap, R7 precision/recall |

All data is synthetic. No real person is represented.

## Run it

Prerequisites: Python 3.11+ and Docker Desktop (with Compose).

**Windows (PowerShell)**

```powershell
Copy-Item .env.example .env
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
docker compose up -d --wait

.\.venv\Scripts\python.exe python\run_pipeline.py --reset
.\.venv\Scripts\python.exe python\validate_pipeline.py
.\.venv\Scripts\python.exe python\reports.py
.\.venv\Scripts\python.exe python\performance_demo.py
```

**macOS / Linux**

```bash
cp .env.example .env
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
docker compose up -d --wait

.venv/bin/python python/run_pipeline.py --reset
.venv/bin/python python/validate_pipeline.py
.venv/bin/python python/reports.py
.venv/bin/python python/performance_demo.py
```

Change `POSTGRES_PASSWORD` in `.env` before starting the container. `docker compose down -v` removes the database completely.

- `--reset` drops every project schema first, so the run starts from the 2026 audit baseline. Use it for demos and the video.
- Without `--reset`, the pipeline runs as it would in production: it reloads the sources, keeps history, and does not recreate shadow copies that retention already removed. Running it repeatedly is safe.
- `--as-of 2026-10-12` fixes the date retention uses as "today", so results are reproducible.
- `validate_pipeline.py` runs 31 checks and exits with status 1 if any fail. Its last checks run a deliberately broken step and confirm that the step's work was rolled back while its `FAILED` row stayed in the log.
- `reports.py` prints every report and saves CSVs and charts to `reports/output/`.

## Project layout

```
data/Wattlebrook_Synthetic_Data.xlsx   synthetic workbook (regenerate with python/generate_synthetic_data.py)
sql/                                   numbered scripts, one design element each (see mapping below)
python/
  generate_synthetic_data.py           builds the workbook (seeded, reproducible)
  load_source_data.py                  workbook -> source schemas, dev_sandbox copies, qa answer key
  run_pipeline.py                      orchestrator: one logged transaction per step
  validate_pipeline.py                 end-to-end test (31 checks)
  reports.py                           prints reports, writes CSVs and charts
  performance_demo.py                  EXPLAIN ANALYZE with and without indexes
```

## Design element to script mapping

| Design element | Script | Main objects |
|---|---|---|
| Architecture (schemas per layer) | `sql/01_init_schemas.sql` | `src_hrms`, `src_sis`, `src_crm`, `dev_sandbox`, `bronze`, `silver`, `gold`, `test_masked`, `audit`, `reports`, `qa` |
| Run log, catalogue, lineage, policy register | `sql/02_audit_framework.sql` | `audit.pipeline_run`, `audit.dataset`, `audit.lineage`, `audit.pii_column`, `audit.retention_policy`, `audit.erasure_register`, `audit.purge_log`, `audit.dq_issue` |
| Governed ingestion | `sql/03_bronze_ingestion.sql` | `bronze.load_source` (append-only, row-count reconciled, lineage recorded) |
| Data Vault 2.0, cleaning, data quality | `sql/04_silver_vault.sql` | hubs, PII and non-PII satellites with `hash_diff`, `silver.v_*_current` views, DQ checks |
| Identity resolution | `sql/05_identity_resolution.sql` | `silver.hub_person`, `silver.link_person_identity` |
| Test data management | `sql/06_test_masked.sql` | `test_masked.student`, `.employee`, `.constituent` |
| Active metadata / discovery | `sql/07_catalogue_discovery.sql` | `audit.scan_for_pii` |
| Lifecycle / retention | `sql/08_retention.sql` | `audit.run_retention` (dry run and live) |
| Dimensional model | `sql/09_gold_star_schema.sql` | `dim_person`, `dim_program`, `dim_system`, `dim_date`, `fact_enrolment`, `fact_giving`, `fact_pii_holding` |
| Reports | `sql/10_reports.sql` | `reports.r01` … `reports.r10` |
| Query performance | `sql/11_indexes.sql` | email/phone and person-link indexes |
| Transactions | `python/run_pipeline.py` | per-step transaction; failure logged in a separate transaction |

## Pipeline steps

| # | Step | What happens |
|---|---|---|
| 1 | `seed_sources` | Workbook sheets load into the three source systems, typed (dates as `DATE`, money as `NUMERIC`). The answer key goes to `qa` only. |
| 2 | `seed_shadow_copies` | First run only: 27,500 copied records go into eight `dev_sandbox` tables. They are deliberately left out of the catalogue, as at the 2026 audit. |
| 3 | `bronze_*` | Each source is appended to bronze with its run ID, load time and record source. Read and loaded counts must match. |
| 4 | `silver_vault_load` | The latest bronze batch is cleaned (names, emails, phone formats), checked for data quality, and loaded into hubs and insert-only satellites. Each PII satellite row gets a retention expiry date. |
| 5 | `identity_resolution` | Rules R1–R3 group records into people (see below). |
| 6 | `discovery_scan_before` | Every table is scanned, PII columns are classified, unregistered tables are added as `FOUND_BY_SCAN`, and holdings are snapshotted. |
| 7 | `retention_review` | Dry run: every record past its retention date is written to `audit.retention_due_record`. |
| 8 | `retention_purge` | Live run: policies are applied, every action goes to `audit.purge_log`, and erased keys go to `audit.erasure_register`. |
| 9 | `masked_provisioning` | Masked copies of all three systems are built from the retained silver data. |
| 10 | `discovery_scan_after` | Second scan and snapshot, used for the before/after report. |
| 11 | `gold_build` | The star schema is rebuilt. It holds no direct personal data. |
| 12 | `reports_views` | The report views are created. |

### Identity resolution rules

| Rule | Match | Confidence |
|---|---|---|
| R1_EMAIL | same normalised email | HIGH |
| R2_SURNAME_DOB_PHONE | same surname, date of birth and mobile number | HIGH |
| R3_NAME_DOB | same first name (nicknames mapped, e.g. Alex = Alexander), surname and DOB. Accepted only if unambiguous and the two groups share no system | MEDIUM |
| R0_PRIOR_LINK | a record whose PII was erased keeps the person it was linked to | HIGH |

Matches chain (if A matches B and B matches C, they are one person). Each group keeps the `person_id` it had in the previous run, so IDs stay stable even when retention deletes a member.

### Retention policies

| Policy | Applies to | Rule | Action |
|---|---|---|---|
| RP-01 | student PII | completed or withdrawn, last activity more than 7 years ago | anonymise |
| RP-02 | former staff PII, TFN and bank details | employment ended more than 7 years ago | anonymise |
| RP-03 | CRM contacts | non-donor, last contact more than 7 years ago | delete |
| RP-04 | `dev_sandbox` copies | past the copy's approved retention date; table dropped once empty, otherwise access revoked (quarantined) | delete |
| RP-05 | bronze | keep only the latest batch; blank PII of erased records | delete / anonymise |

Erased keys are recorded in `audit.erasure_register`. Later loads consult it, so personal data that retention removed is not loaded back in from the source systems.

## Results (clean run, `--as-of 2026-10-12`)

- **Retention:** 6,755 student, 560 staff and 1,650 CRM records were past retention, plus 25,397 shadow copies. After the run, no PII past its retention date remains. One sandbox (`git_repo_hr_migration`) was dropped entirely; the other seven are quarantined, with 2,103 in-retention rows left (1,977 of them unmasked).
- **Identity:** the 25,850 records left after retention resolve to 19,646 people (true number: 19,486). Precision is 99.84% and recall 96.96%. All 11 wrong links come from the MEDIUM rule (R3) on seeded "false friends": different people who share a name and date of birth. HIGH-confidence links had no errors.
- **Masking:** 18,535 masked rows across all three systems; all 9 leak checks are 0. 3,449 masked people still join across tables through `person_ref`.
- **Data quality:** all 12 seeded impossible-date cases were detected.
- **Performance:** a subject access request by email takes about 8 ms without the email indexes and about 0.15 ms with them.

## The synthetic data

`python/generate_synthetic_data.py` (seed 2026) creates:

| Sheet | Rows | Notes |
|---|---|---|
| HRMS | 5,000 | own key `EMPnnnnnn`; TFN, bank details, employment dates |
| SIS | 15,000 | own key `STUnnnnnnn`; program, status, visa, fees, last activity |
| ADV_CRM | 7,500 | own key `CRMnnnnnnn`; alumni year, donations, last contact |
| Shadow_Extracts | 27,500 | one copied record per source record, extracted 2012–2026 into eight environments |
| Identity_Answer_Key | 27,500 | true person for every source record (QA only) |
| DQ_Test_Cases | 12 | rows made impossible on purpose |
| Data_Dictionary | 14 | column meanings |

- The source systems share **no identifier**, so the pipeline has to work out who is who.
- Overlapping people look different in each system: student, staff and personal email addresses; phone formats `0412345678`, `0412 345 678` and `+61 412 345 678`; nicknames; stray spaces and capitals; occasional surname typos; and day/month swaps in dates of birth. Some overlaps are therefore unmatchable, which is why recall is below 100%.
- Dates are life-consistent: staff are at least 21 when hired, students enrol at 17 or older, and alumni graduate after enrolling. The 12 exceptions are listed in `DQ_Test_Cases`.
- The 27,500 shadow copies are **records**, covering 20,200 distinct people.
- Fake values used by masking (names, `0491 57x xxx` phones, `@example.invalid` emails) never occur in the source data.

## Design trade-offs and limitations

- **Imitated platform:** the data fabric, lakehouse and test-data tooling recommended in Assignment 1 are imitated with Postgres schemas and procedures. Separate schemas are less realistic than separate databases.
- **Source systems keep their data:** retention acts on the governed platform and the shadow copies. Applying it inside HRMS, SIS and CRM is outside this prototype.
- **Name-based PII classification:** the discovery scan classifies columns by name. A column named something unexpected would be missed; content-based detection would be the next step.
- **Masking key:** the key lives in `audit.masking_key` in the same database. In production it would sit in a secrets manager, and `audit` would be locked down with roles.
- **Matching trade-off:** the matcher favours precision. R3 can still merge "false friends", which is why those links are only MEDIUM confidence.
- **Current-state links:** `link_person_identity` holds the current links only. The history of how matches changed is not kept.
