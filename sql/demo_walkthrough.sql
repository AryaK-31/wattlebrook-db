-- =============================================================================
-- Wattlebrook University governed data platform: demo walkthrough
--
-- Run AFTER a clean pipeline run and the end-to-end test:
--     python python/run_pipeline.py --reset --as-of 2026-10-12
--     python python/validate_pipeline.py
--
-- Then run these queries one at a time in pgAdmin / DBeaver, or all at once:
--     docker exec -i wbu_postgres_db psql -U wbu_admin -d wattlebrook_db -e < sql/demo_walkthrough.sql
--
-- Read-only: nothing here changes data (the index demo in step 9 is rolled back).
--
-- Two people are followed through the whole platform:
--   Anh Le        - one person, three systems, three emails, three phone formats, no shared ID
--   Olivia Saito  - one person whose old student and CRM records are past retention
-- Expected results (from a clean run with --as-of 2026-10-12) are under each query.
-- =============================================================================


-- =============================================================================
-- STEP 0  Platform at a glance: every layer, from the catalogue
-- Talking point: one query tells you every dataset, which layer it is in and how
-- much real personal data it holds. Before this project nobody could answer that.
-- =============================================================================

SELECT layer, count(*) AS datasets, sum(row_count) AS total_rows, sum(real_pii_rows) AS rows_with_real_pii
  FROM audit.dataset
 GROUP BY layer
 ORDER BY CASE layer WHEN 'source' THEN 1 WHEN 'bronze' THEN 2 WHEN 'silver' THEN 3 WHEN 'test_masked' THEN 4
                     WHEN 'gold' THEN 5 ELSE 6 END;
-- Expected: source 3 datasets / 27,500 rows; test_masked 3 datasets / 0 real PII;
--           gold 7 datasets / 0 real PII; dev_sandbox 8 datasets (1 dropped, 7 quarantined)


-- =============================================================================
-- STEP 1  The problem (Assignment 1 audit)
-- =============================================================================

-- 1a. Three systems, no shared key. The same person, Anh Le, looks different in each.
SELECT 'SIS' AS system, sis_student_id AS record_id, first_name, last_name, email, phone::TEXT AS phone, date_of_birth
  FROM src_sis.student WHERE sis_student_id = 'STU0000001'
UNION ALL
SELECT 'HRMS', hr_employee_id, first_name, last_name, email, phone::TEXT, date_of_birth
  FROM src_hrms.employee WHERE hr_employee_id = 'EMP000001'
UNION ALL
SELECT 'ADV_CRM', crm_contact_id, first_name, last_name, email, phone::TEXT, date_of_birth
  FROM src_crm.constituent WHERE crm_contact_id = 'CRM0000001';
-- Expected: three different IDs, three different emails, phones written
--           0439986987 / 0439 986 987 / +61 439 986 987. Same DOB 1996-07-17.

-- 1b. The shadow copies as the audit found them (snapshot taken before retention ran).
SELECT dataset, status, row_count, real_pii_rows, masked
  FROM audit.pii_holding_snapshot
 WHERE layer = 'dev_sandbox'
   AND run_id = (SELECT max(run_id) FROM audit.pii_holding_snapshot WHERE phase = 'BEFORE_RETENTION')
 ORDER BY row_count DESC;
-- Expected: 8 tables, 27,500 rows in total, all FOUND_BY_SCAN (nobody registered them), none masked.

-- 1c. How bad the copies were: almost none masked, catalogued or traced.
SELECT sum(row_count) AS shadow_rows, sum(real_pii_rows) AS rows_with_real_pii,
       round(100.0 * sum(real_pii_rows) / sum(row_count), 1) AS pct_real_pii
  FROM audit.pii_holding_snapshot
 WHERE layer = 'dev_sandbox'
   AND run_id = (SELECT max(run_id) FROM audit.pii_holding_snapshot WHERE phase = 'BEFORE_RETENTION');


-- =============================================================================
-- STEP 2  Governed ingestion: source -> bronze  (Problem 1)
-- =============================================================================

-- 2a. Every pipeline step is logged, with rows read vs loaded and timing.
SELECT run_id, step_name, target_table, rows_read, rows_loaded, run_status, seconds
  FROM reports.r01_pipeline_runs;
-- Expected: 14 steps, all SUCCESS. bronze_* steps show rows_read = rows_loaded
--           (5,000 HRMS, 15,000 SIS, 7,500 CRM).

-- 2b. Bronze keeps the raw record as-is, stamped with the run, load time and source.
SELECT sis_student_id, first_name, email, phone, pipeline_run_id, ingested_at, record_source
  FROM bronze.sis_student_raw
 WHERE sis_student_id = 'STU0000001';

-- 2c. Lineage: every movement of data is recorded by the step that did it.
SELECT l.run_id, r.step_name, l.parent, l.child, l.operation, l.rows_moved, l.masked
  FROM audit.lineage l LEFT JOIN audit.pipeline_run r USING (run_id)
 WHERE l.operation IN ('INGEST', 'VAULT_LOAD', 'MASK', 'AGGREGATE')
 ORDER BY l.lineage_id;

-- 2d. Failures are kept even though the failed step is rolled back.
--     (validate_pipeline.py runs a deliberately broken step, so this shows one row.)
SELECT run_id, step_name, target_table, split_part(error_message, E'\n', 1) AS error, started_at
  FROM reports.r01b_failed_steps;
-- Expected: failure_demo, error 'column "unexpected_column" ... does not exist'.
--           The test also proves the bronze table was unchanged (15,000 rows before and after).


-- =============================================================================
-- STEP 3  Silver: cleaning, Data Vault 2.0, data quality
-- =============================================================================

-- 3a. Cleaning: raw source vs cleaned silver for Anh Le's three records.
SELECT 'SIS' AS system, s.phone::TEXT AS raw_phone, v.phone AS clean_phone, s.email AS raw_email, v.email AS clean_email
  FROM src_sis.student s JOIN silver.v_student_current v USING (sis_student_id)
 WHERE sis_student_id = 'STU0000001'
UNION ALL
SELECT 'HRMS', s.phone::TEXT, v.phone, s.email, v.email
  FROM src_hrms.employee s JOIN silver.v_employee_current v USING (hr_employee_id)
 WHERE hr_employee_id = 'EMP000001'
UNION ALL
SELECT 'ADV_CRM', s.phone::TEXT, v.phone, s.email, v.email
  FROM src_crm.constituent s JOIN silver.v_constituent_current v USING (crm_contact_id)
 WHERE crm_contact_id = 'CRM0000001';
-- Expected: all three phones become 0439986987, so they can now be compared.

-- 3b. Cleaning names: stray spaces and ALL CAPS fixed, mixed case (O'Brien, McKay) left alone.
SELECT s.sis_student_id, '[' || s.first_name || ']' AS raw_first, '[' || v.first_name || ']' AS clean_first,
       '[' || s.last_name || ']' AS raw_last, '[' || v.last_name || ']' AS clean_last
  FROM src_sis.student s JOIN silver.v_student_current v USING (sis_student_id)
 WHERE v.first_name IS NOT NULL AND (s.first_name <> v.first_name OR s.last_name <> v.last_name)
 LIMIT 8;

-- 3c. Data Vault: the hub holds only the business key and its hash; personal and
--     non-personal attributes live in separate satellites (so retention can blank
--     the PII satellite and keep the enrolment history).
SELECT h.sis_student_id, h.student_hk, silver.hash_key('STU0000001') = h.student_hk AS hash_matches,
       h.record_source, h.pipeline_run_id,
       (SELECT count(*) FROM silver.sat_student_pii p WHERE p.student_hk = h.student_hk) AS pii_sat_rows,
       (SELECT count(*) FROM silver.sat_student_enrolment e WHERE e.student_hk = h.student_hk) AS enrolment_sat_rows
  FROM silver.hub_student h
 WHERE h.sis_student_id = 'STU0000001';

-- 3d. Data quality: every seeded impossible record was caught.
SELECT system_name, rule_name, issues, matches_seeded_case, records
  FROM reports.r09_dq_issues;
-- Expected: 16 issues on the 12 seeded records (4 SIS records break two rules each);
--           every issue matches a seeded test case.


-- =============================================================================
-- STEP 4  Identity resolution: one person, three records  (Problem 5)
-- =============================================================================

-- 4a. Anh Le's three records are linked into one person, and the link says why.
SELECT hp.person_id, l.system_name, l.business_key, l.match_rule, l.match_confidence
  FROM silver.link_person_identity l
  JOIN silver.hub_person hp USING (person_hk)
 WHERE hp.person_hk = (SELECT person_hk FROM silver.link_person_identity
                        WHERE system_name = 'SIS' AND business_key = 'STU0000001')
 ORDER BY l.system_name;
-- Expected: one person_id, rule R2_SURNAME_DOB_PHONE (HIGH). Email could not match
--           (three different addresses), but surname + DOB + cleaned phone did.

-- 4b. How many people appear in 1, 2 or 3 systems.
SELECT * FROM reports.r06_identity_overlap;

-- 4c. Accuracy against the answer key.
SELECT * FROM reports.r07_identity_accuracy;
-- Expected: 25,850 records, 19,486 true people, 19,646 predicted;
--           precision 99.84%, recall 96.96%, 11 wrong links.

-- 4d. Where the wrong links come from: only the MEDIUM rule.
SELECT * FROM reports.r07b_identity_errors_by_confidence;

-- 4e. A "false friend": two different people wrongly merged (same name and DOB).
WITH j AS (
    SELECT hp.person_id, l.system_name, l.business_key, l.match_rule, k.true_person_id
      FROM silver.link_person_identity l
      JOIN silver.hub_person hp USING (person_hk)
      JOIN qa.identity_answer_key k ON k.source_system = l.system_name AND k.source_record_id = l.business_key
)
SELECT person_id,
       string_agg(system_name || ' ' || business_key || ' -> true ' || true_person_id || ' via ' || match_rule,
                  ' | ' ORDER BY system_name) AS records
  FROM j
 WHERE person_id IN (SELECT person_id FROM j GROUP BY person_id HAVING count(DISTINCT true_person_id) > 1)
 GROUP BY person_id
 LIMIT 3;
-- Talking point: this is why R3 is only MEDIUM confidence and goes to review.


-- =============================================================================
-- STEP 5  Catalogue, discovery scan and lineage  (Problem 3)
-- =============================================================================

-- 5a. The catalogue: every dataset, its owner, PII columns and where it came from.
SELECT dataset, layer, status, owner, contains_real_pii, masked, row_count, pii_columns, comes_from
  FROM reports.r05_catalogue_lineage;
-- Expected: governed datasets show their parent; dev_sandbox tables show
--           owner UNKNOWN and '(no lineage: origin unknown)'.

-- 5b. What the discovery scan classified as personal data.
SELECT sensitivity_level, count(*) AS columns, count(DISTINCT dataset) AS datasets,
       string_agg(DISTINCT column_name, ', ') AS column_names
  FROM audit.pii_column
 GROUP BY sensitivity_level
 ORDER BY columns DESC;

-- 5c. Full upstream lineage of the masked student table, back to the source system.
WITH RECURSIVE up AS (
    SELECT parent, child, operation, 1 AS hops
      FROM audit.lineage WHERE child = 'test_masked.student'
    UNION
    SELECT l.parent, l.child, l.operation, up.hops + 1
      FROM audit.lineage l
      JOIN up ON l.child = CASE up.parent                      -- the current view reads the PII satellite
                             WHEN 'silver.v_student_current' THEN 'silver.sat_student_pii'
                             ELSE up.parent END
     WHERE up.hops < 10
)
SELECT DISTINCT hops, parent, operation, child FROM up ORDER BY hops;
-- Expected: test_masked.student <- silver.v_student_current (sat_student_pii) <- bronze.sis_student_raw
--           <- src_sis.student <- the workbook. Four hops from masked test data back to the source.


-- =============================================================================
-- STEP 6  Retention: review, purge, before/after  (Problem 4)
-- =============================================================================

-- 6a. The policy register.
SELECT policy_id, policy_name, applies_to, trigger_rule, retention_period_days, action
  FROM audit.retention_policy ORDER BY policy_id;

-- 6b. Dry run: what was past its retention date.
SELECT policy_id, target_object, system_name, records_due, oldest_expiry, max_days_overdue, action
  FROM reports.r02_retention_due_summary;
-- Expected: 6,755 student, 560 staff, 1,650 CRM records, plus 25,397 shadow copies.

-- 6c. Live run: what was actually done, with before and after counts.
SELECT policy_id, target_object, action, rows_before, rows_affected, rows_after
  FROM reports.r03_purge_results;

-- 6d. Real personal data per dataset, before vs after retention (only rows that changed).
SELECT dataset, layer, status_before, status_after, real_pii_rows_before, real_pii_rows_after
  FROM reports.r04_pii_holdings_before_after
 WHERE real_pii_rows_before <> real_pii_rows_after OR status_before IS DISTINCT FROM status_after;
-- Expected: git_repo_hr_migration FOUND_BY_SCAN -> PURGED (dropped);
--           the other seven sandboxes -> QUARANTINED; silver PII counts drop.

-- 6e. Olivia Saito: what retention did to each of her records.
SELECT e.system_name, e.business_key, e.policy_id, e.action, e.applied_at
  FROM audit.erasure_register e
 WHERE e.business_key IN ('STU0000006', 'EMP000006', 'CRM0000006');
-- Expected: SIS anonymised (RP-01), CRM deleted (RP-03). HRMS record is kept
--           because she is still employed.

-- 6f. Her student record in silver: PII blanked, but the enrolment history is kept.
SELECT sis_student_id, first_name, last_name, email, date_of_birth, anonymised_at, anonymised_by,
       program_name, enrolment_status, enrolment_year, completion_year
  FROM silver.v_student_current
 WHERE sis_student_id = 'STU0000006';

-- 6g. Proof: no personal data past its retention date is left anywhere in silver.
SELECT 'SIS' AS system, count(*) AS expired_pii_still_present
  FROM silver.v_student_current WHERE retention_expiry_date < DATE '2026-10-12' AND anonymised_at IS NULL AND email IS NOT NULL
UNION ALL
SELECT 'HRMS', count(*)
  FROM silver.v_employee_current WHERE retention_expiry_date < DATE '2026-10-12' AND anonymised_at IS NULL AND email IS NOT NULL
UNION ALL
SELECT 'ADV_CRM', count(*)
  FROM silver.v_constituent_current WHERE retention_expiry_date < DATE '2026-10-12' AND anonymised_at IS NULL AND email IS NOT NULL;
-- Expected: 0, 0, 0.

-- 6h. The fully expired sandbox is gone; the rest are quarantined with access revoked.
SELECT dataset, status, row_count, real_pii_rows,
       to_regclass(dataset) IS NOT NULL AS table_still_exists, notes
  FROM audit.dataset
 WHERE layer = 'dev_sandbox'
 ORDER BY status, dataset;


-- =============================================================================
-- STEP 7  Masked test data for developers  (Problem 2)
-- =============================================================================

-- 7a. Real vs masked: Anh Le's student record. Same shape, nothing real.
SELECT 'real (silver)' AS version, sis_student_id, first_name, last_name, email, phone, date_of_birth, program_name
  FROM silver.v_student_current WHERE sis_student_id = 'STU0000001'
UNION ALL
SELECT 'masked (test_masked)', sis_student_id, first_name, last_name, email, phone, date_of_birth, program_name
  FROM test_masked.student WHERE sis_student_id = test_masked.pseudo('STU0000001', 'STU');
-- Expected: masked ID, fake name, @example.invalid email, 0491 57x xxx phone, shifted DOB.
--           Program is kept, so the test data is still useful.

-- 7b. Masked records of one person still join across systems through person_ref.
WITH me AS (SELECT person_ref FROM test_masked.student WHERE sis_student_id = test_masked.pseudo('STU0000001', 'STU'))
SELECT 'SIS' AS system, sis_student_id AS masked_id, person_ref, first_name, last_name, email
  FROM test_masked.student WHERE person_ref = (SELECT person_ref FROM me)
UNION ALL
SELECT 'HRMS', hr_employee_id, person_ref, first_name, last_name, email
  FROM test_masked.employee WHERE person_ref = (SELECT person_ref FROM me)
UNION ALL
SELECT 'ADV_CRM', crm_contact_id, person_ref, first_name, last_name, email
  FROM test_masked.constituent WHERE person_ref = (SELECT person_ref FROM me);
-- Talking point: same fake identity in all three tables, so developers can test joins.

-- 7c. Leak check: every check must be 0.
SELECT check_name, failures, target,
       CASE WHEN target IS NULL THEN 'info' WHEN failures = target THEN 'PASS' ELSE 'FAIL' END AS result
  FROM reports.r08_masking_leak_check;
-- Expected: 9 checks PASS with 0 failures; 18,535 masked rows; 3,449 people joinable.


-- =============================================================================
-- STEP 8  Gold star schema: reporting without personal data
-- =============================================================================

-- 8a. Proof that gold holds no direct identifiers.
SELECT table_name, string_agg(column_name, ', ' ORDER BY ordinal_position) AS columns
  FROM information_schema.columns
 WHERE table_schema = 'gold'
 GROUP BY table_name ORDER BY table_name;

SELECT count(*) AS pii_like_columns_in_gold
  FROM information_schema.columns
 WHERE table_schema = 'gold'
   AND column_name ~* '(first_name|last_name|email|phone|birth|address|tax_file|bank)';
-- Expected: 0.

-- 8b. Anh Le in gold: a person key and flags, no name.
SELECT * FROM gold.dim_person
 WHERE person_id = (SELECT hp.person_id FROM silver.link_person_identity l JOIN silver.hub_person hp USING (person_hk)
                     WHERE l.system_name = 'SIS' AND l.business_key = 'STU0000001');

-- 8c. Business report from the star schema: enrolments by program.
SELECT * FROM reports.r10_enrolments_by_program;

-- 8d. A question you could not answer before identity resolution:
--     how much do donors give, split by how many systems they appear in?
SELECT dp.system_count, count(*) AS donors, round(sum(f.lifetime_donation_aud)) AS total_donated_aud,
       round(avg(f.lifetime_donation_aud)) AS avg_donation_aud
  FROM gold.fact_giving f JOIN gold.dim_person dp USING (person_key)
 WHERE f.is_donor
 GROUP BY dp.system_count ORDER BY dp.system_count;


-- =============================================================================
-- STEP 9  Subject access request and query performance
-- =============================================================================

-- 9a. "What do you hold about me?" Start from one email, find every linked record.
WITH found AS (
    SELECT l.person_hk
      FROM silver.v_constituent_current v
      JOIN silver.link_person_identity l ON l.system_name = 'ADV_CRM' AND l.business_key = v.crm_contact_id
     WHERE v.email = 'anh.le8386@example.com'
)
SELECT l.system_name, l.business_key, l.match_rule,
       coalesce(s.email, e.email, c.email) AS email_held,
       coalesce(s.program_name, e.position_title, c.contact_type) AS what_it_is
  FROM silver.link_person_identity l
  JOIN found USING (person_hk)
  LEFT JOIN silver.v_student_current s     ON l.system_name = 'SIS'     AND s.sis_student_id = l.business_key
  LEFT JOIN silver.v_employee_current e    ON l.system_name = 'HRMS'    AND e.hr_employee_id = l.business_key
  LEFT JOIN silver.v_constituent_current c ON l.system_name = 'ADV_CRM' AND c.crm_contact_id = l.business_key
 ORDER BY l.system_name;
-- Expected: one email finds all three records, including two with different emails.

-- 9b. ...and the shadow copies that still hold her data (quarantined sandboxes).
--     (git_repo_hr_migration is left out because retention dropped it.)
SELECT 'developer_laptop_export' AS sandbox, shadow_record_id, source_record_id, purpose, retention_expiry_date, masked FROM dev_sandbox.developer_laptop_export    WHERE source_record_id IN ('STU0000001', 'EMP000001', 'CRM0000001')
UNION ALL SELECT 'git_repo_alumni_portal',     shadow_record_id, source_record_id, purpose, retention_expiry_date, masked FROM dev_sandbox.git_repo_alumni_portal     WHERE source_record_id IN ('STU0000001', 'EMP000001', 'CRM0000001')
UNION ALL SELECT 'git_repo_legacy_admissions', shadow_record_id, source_record_id, purpose, retention_expiry_date, masked FROM dev_sandbox.git_repo_legacy_admissions WHERE source_record_id IN ('STU0000001', 'EMP000001', 'CRM0000001')
UNION ALL SELECT 'sandbox_dev_team_a',         shadow_record_id, source_record_id, purpose, retention_expiry_date, masked FROM dev_sandbox.sandbox_dev_team_a         WHERE source_record_id IN ('STU0000001', 'EMP000001', 'CRM0000001')
UNION ALL SELECT 'sandbox_test_team_b',        shadow_record_id, source_record_id, purpose, retention_expiry_date, masked FROM dev_sandbox.sandbox_test_team_b        WHERE source_record_id IN ('STU0000001', 'EMP000001', 'CRM0000001')
UNION ALL SELECT 'shared_test_drive',          shadow_record_id, source_record_id, purpose, retention_expiry_date, masked FROM dev_sandbox.shared_test_drive          WHERE source_record_id IN ('STU0000001', 'EMP000001', 'CRM0000001')
UNION ALL SELECT 'staging_crm_integration',    shadow_record_id, source_record_id, purpose, retention_expiry_date, masked FROM dev_sandbox.staging_crm_integration    WHERE source_record_id IN ('STU0000001', 'EMP000001', 'CRM0000001');
-- Expected: one unmasked copy (SHD012759, staging_crm_integration), still within its
--           approved retention (expires 2027-12-04). Honest limitation for the report:
--           quarantine stops access, but the copy should be replaced with test_masked data.

-- 9c. Index demo: the same email lookup with and without the index.
--     The index is dropped inside a transaction and restored by ROLLBACK.
EXPLAIN ANALYZE SELECT * FROM silver.sat_constituent_pii WHERE email = 'anh.le8386@example.com';
-- Expected: Index Scan using ix_sat_constituent_pii_email, well under 1 ms.

BEGIN;
DROP INDEX silver.ix_sat_constituent_pii_email;
EXPLAIN ANALYZE SELECT * FROM silver.sat_constituent_pii WHERE email = 'anh.le8386@example.com';
ROLLBACK;
-- Expected: Seq Scan reading all 5,850 rows, roughly 25x slower (about 0.6 ms vs 0.02 ms here).
--           Small table, so both are fast; the gap grows with the data. ROLLBACK puts the index back.


-- =============================================================================
-- STEP 10  End-to-end test (run from the terminal, not SQL)
--     python python/validate_pipeline.py      -> 31/31 checks passed
--     python python/reports.py                -> CSVs and charts in reports/output/
-- =============================================================================
