-- =============================================================================
-- 10 Reports
-- Design element: reports and dashboards that prove each fix works. These are
-- plain views; python/reports.py prints them and saves CSVs and charts.
-- This script runs as the last pipeline step, because it reads tables that
-- earlier steps rebuild. Views are recreated from scratch each run so their
-- columns can change between versions.
-- =============================================================================

DROP SCHEMA IF EXISTS reports CASCADE;
CREATE SCHEMA reports;

-- R1 Pipeline audit: every step of the latest pipeline execution
CREATE OR REPLACE VIEW reports.r01_pipeline_runs AS
SELECT run_id, step_name, source_name, target_table, rows_read, rows_loaded, run_status, error_message,
       started_at, round(extract(epoch FROM completed_at - started_at)::NUMERIC, 2) AS seconds
  FROM audit.pipeline_run
 WHERE batch_id = (SELECT batch_id FROM audit.pipeline_run WHERE step_name = 'gold_build'
                     ORDER BY run_id DESC LIMIT 1)
 ORDER BY run_id;

-- R1b Every failed step ever recorded (shows failures survive their rollback)
CREATE OR REPLACE VIEW reports.r01b_failed_steps AS
SELECT run_id, batch_id, step_name, source_name, target_table, error_message, started_at
  FROM audit.pipeline_run WHERE run_status = 'FAILED' ORDER BY run_id;

-- R2 Records past their use-by date, found by the latest retention review
CREATE OR REPLACE VIEW reports.r02_retention_due_summary AS
SELECT d.policy_id, p.policy_name, d.target_object, d.system_name, count(*) AS records_due,
       min(d.expired_on) AS oldest_expiry, max(d.days_overdue) AS max_days_overdue,
       round(avg(d.days_overdue)) AS avg_days_overdue, p.action
  FROM audit.retention_due_record d JOIN audit.retention_policy p USING (policy_id)
 WHERE d.review_id = (SELECT max(review_id) FROM audit.retention_review r
                       WHERE r.run_id IN (SELECT run_id FROM reports.r01_pipeline_runs WHERE step_name = 'retention_review'))
 GROUP BY d.policy_id, p.policy_name, d.target_object, d.system_name, p.action
 ORDER BY d.policy_id, d.target_object, d.system_name;

CREATE OR REPLACE VIEW reports.r02b_retention_due_records AS
SELECT d.policy_id, d.target_object, d.system_name, d.record_key, d.expired_on, d.days_overdue
  FROM audit.retention_due_record d
 WHERE d.review_id = (SELECT max(review_id) FROM audit.retention_review r
                       WHERE r.run_id IN (SELECT run_id FROM reports.r01_pipeline_runs WHERE step_name = 'retention_review'))
 ORDER BY d.days_overdue DESC;

-- R2c Every retention review ever run: how much was due each time
CREATE OR REPLACE VIEW reports.r02c_retention_history AS
SELECT r.review_id, r.run_id, r.as_of_date, r.dry_run, r.reviewed_at,
       count(d.*) FILTER (WHERE d.policy_id <> 'RP-05') AS personal_records_due,
       count(d.*) FILTER (WHERE d.policy_id = 'RP-05') AS bronze_batches_due
  FROM audit.retention_review r LEFT JOIN audit.retention_due_record d USING (review_id)
 GROUP BY r.review_id ORDER BY r.review_id;

-- R3 What the live retention run did
CREATE OR REPLACE VIEW reports.r03_purge_results AS
SELECT policy_id, target_object, action, rows_before, rows_affected, rows_after, executed_at
  FROM audit.purge_log
 WHERE run_id IN (SELECT run_id FROM reports.r01_pipeline_runs WHERE step_name = 'retention_purge')
 ORDER BY purge_id;

-- R4 Personal-data holdings before and after retention
CREATE OR REPLACE VIEW reports.r04_pii_holdings_before_after AS
SELECT coalesce(b.dataset, a.dataset) AS dataset, coalesce(b.layer, a.layer) AS layer,
       b.status AS status_before, a.status AS status_after,
       coalesce(b.row_count, 0) AS rows_before, coalesce(a.row_count, 0) AS rows_after,
       coalesce(b.real_pii_rows, 0) AS real_pii_rows_before, coalesce(a.real_pii_rows, 0) AS real_pii_rows_after,
       coalesce(a.masked, b.masked) AS masked
  FROM (SELECT * FROM gold.fact_pii_holding WHERE phase = 'BEFORE_RETENTION') b
  FULL JOIN (SELECT * FROM gold.fact_pii_holding WHERE phase = 'AFTER_RETENTION') a USING (dataset)
 ORDER BY layer, dataset;

-- R5 Catalogue and lineage: every dataset, who owns it, where it came from
CREATE OR REPLACE VIEW reports.r05_catalogue_lineage AS
SELECT d.dataset, d.layer, d.status, d.owner, d.contains_real_pii, d.masked, d.row_count,
       (SELECT count(*) FROM audit.pii_column c WHERE c.dataset = d.dataset) AS pii_columns,
       coalesce((SELECT string_agg(DISTINCT l.parent, ', ') FROM audit.lineage l WHERE l.child = d.dataset),
                '(no lineage: origin unknown)') AS comes_from,
       (SELECT max(l.recorded_at) FROM audit.lineage l WHERE l.child = d.dataset OR l.parent = d.dataset) AS last_movement
  FROM audit.dataset d
 ORDER BY CASE d.layer WHEN 'source' THEN 1 WHEN 'bronze' THEN 2 WHEN 'silver' THEN 3 WHEN 'test_masked' THEN 4
                       WHEN 'gold' THEN 5 ELSE 6 END, d.dataset;

-- R6 Identity overlap: how many people appear in 1, 2 or 3 systems
CREATE OR REPLACE VIEW reports.r06_identity_overlap AS
SELECT system_count,
       concat_ws(' + ', CASE WHEN in_hrms THEN 'HRMS' END, CASE WHEN in_sis THEN 'SIS' END,
                        CASE WHEN in_crm THEN 'ADV_CRM' END) AS systems,
       count(*) AS people
  FROM gold.dim_person
 GROUP BY system_count, 2
 ORDER BY system_count, 2;

-- R7 Matcher accuracy against the answer key (pairwise precision and recall)
CREATE OR REPLACE VIEW reports.r07_identity_accuracy AS
WITH j AS (
    SELECT hp.person_id, k.true_person_id, l.match_confidence
      FROM silver.link_person_identity l
      JOIN silver.hub_person hp ON hp.person_hk = l.person_hk
      JOIN qa.identity_answer_key k ON k.source_system = l.system_name AND k.source_record_id = l.business_key
), pred AS (SELECT sum(n * (n - 1) / 2) AS pairs FROM (SELECT count(*) n FROM j GROUP BY person_id) x),
   truth AS (SELECT sum(n * (n - 1) / 2) AS pairs FROM (SELECT count(*) n FROM j GROUP BY true_person_id) x),
   tp AS (SELECT sum(n * (n - 1) / 2) AS pairs FROM (SELECT count(*) n FROM j GROUP BY person_id, true_person_id) x)
SELECT (SELECT count(*) FROM j) AS records_scored,
       (SELECT count(DISTINCT true_person_id) FROM j) AS true_people,
       (SELECT count(DISTINCT person_id) FROM j) AS predicted_people,
       tp.pairs AS correct_links, pred.pairs - tp.pairs AS wrong_links, truth.pairs - tp.pairs AS missed_links,
       round(100.0 * tp.pairs / nullif(pred.pairs, 0), 2) AS precision_pct,
       round(100.0 * tp.pairs / nullif(truth.pairs, 0), 2) AS recall_pct
  FROM pred, truth, tp;

-- Wrong merges broken down by the weakest rule involved
CREATE OR REPLACE VIEW reports.r07b_identity_errors_by_confidence AS
WITH j AS (
    SELECT hp.person_id, k.true_person_id, l.match_confidence, l.match_rule
      FROM silver.link_person_identity l
      JOIN silver.hub_person hp ON hp.person_hk = l.person_hk
      JOIN qa.identity_answer_key k ON k.source_system = l.system_name AND k.source_record_id = l.business_key
), impure AS (SELECT person_id FROM j GROUP BY person_id HAVING count(DISTINCT true_person_id) > 1)
SELECT match_confidence, count(*) AS records,
       count(*) FILTER (WHERE person_id IN (SELECT person_id FROM impure)) AS records_in_wrong_merges
  FROM j GROUP BY match_confidence ORDER BY match_confidence;

-- R8 Masking leak check: every row must be 0 except the two informational ones
CREATE OR REPLACE VIEW reports.r08_masking_leak_check AS
WITH real_people AS (
    SELECT 'SIS' sys, sis_student_id id, silver.clean_email(email) email, silver.clean_phone(phone::TEXT) phone,
           lower(btrim(first_name)) fn, lower(btrim(last_name)) ln, date_of_birth::DATE dob,
           NULL::TEXT tfn, NULL::TEXT acct FROM src_sis.student
    UNION ALL
    SELECT 'HRMS', hr_employee_id, silver.clean_email(email), silver.clean_phone(phone::TEXT),
           lower(btrim(first_name)), lower(btrim(last_name)), date_of_birth::DATE,
           regexp_replace(tax_file_number::TEXT, '[^0-9]', '', 'g'), bank_account::TEXT FROM src_hrms.employee
    UNION ALL
    SELECT 'ADV_CRM', crm_contact_id, silver.clean_email(email), silver.clean_phone(phone::TEXT),
           lower(btrim(first_name)), lower(btrim(last_name)), date_of_birth::DATE, NULL, NULL FROM src_crm.constituent
), masked AS (
    SELECT 'SIS' sys, sis_student_id id, person_ref, email, phone, lower(first_name) fn, lower(last_name) ln,
           date_of_birth dob, NULL::TEXT tfn, NULL::TEXT acct FROM test_masked.student
    UNION ALL
    SELECT 'HRMS', hr_employee_id, person_ref, email, phone, lower(first_name), lower(last_name), date_of_birth,
           tax_file_number, bank_account FROM test_masked.employee
    UNION ALL
    SELECT 'ADV_CRM', crm_contact_id, person_ref, email, phone, lower(first_name), lower(last_name), date_of_birth,
           NULL, NULL FROM test_masked.constituent
)
SELECT 'Real email addresses in masked data' AS check_name,
       (SELECT count(*) FROM masked m WHERE m.email IN (SELECT email FROM real_people WHERE email IS NOT NULL)) AS failures,
       0 AS target
UNION ALL SELECT 'Real phone numbers in masked data',
       (SELECT count(*) FROM masked m WHERE m.phone IN (SELECT phone FROM real_people WHERE phone IS NOT NULL)), 0
UNION ALL SELECT 'Real first + last name + DOB combinations',
       (SELECT count(*) FROM masked m JOIN real_people r ON r.fn = m.fn AND r.ln = m.ln AND r.dob = m.dob), 0
UNION ALL SELECT 'Masked record keeps its real date of birth',
       (SELECT count(*) FROM masked m JOIN real_people r
          ON r.sys = m.sys AND test_masked.pseudo(r.id, CASE r.sys WHEN 'SIS' THEN 'STU' WHEN 'HRMS' THEN 'EMP' ELSE 'CRM' END) = m.id
       WHERE r.dob = m.dob), 0
UNION ALL SELECT 'Real first names used in masked data',
       (SELECT count(*) FROM masked m WHERE m.fn IN (SELECT fn FROM real_people)), 0
UNION ALL SELECT 'Tax file numbers or bank accounts present',
       (SELECT count(*) FROM masked WHERE tfn IS NOT NULL OR acct IS NOT NULL), 0
UNION ALL SELECT 'Real source IDs used as masked IDs',
       (SELECT count(*) FROM masked m WHERE m.id IN (SELECT id FROM real_people)), 0
UNION ALL SELECT 'Duplicate pseudonymised IDs',
       (SELECT count(*) - count(DISTINCT id) FROM masked), 0
UNION ALL SELECT 'Records erased by retention but provisioned',
       (SELECT count(*) FROM masked m JOIN real_people r
          ON r.sys = m.sys AND test_masked.pseudo(r.id, CASE r.sys WHEN 'SIS' THEN 'STU' WHEN 'HRMS' THEN 'EMP' ELSE 'CRM' END) = m.id
        JOIN audit.erasure_register e ON e.system_name = r.sys AND e.business_key = r.id), 0
UNION ALL SELECT '(info) masked rows provisioned', (SELECT count(*) FROM masked), NULL
UNION ALL SELECT '(info) masked people present in 2+ masked tables (joins still work)',
       (SELECT count(*) FROM (SELECT person_ref FROM masked GROUP BY person_ref HAVING count(DISTINCT sys) > 1) x), NULL;

-- R9 Data-quality findings of the latest silver load, against the seeded test cases
CREATE OR REPLACE VIEW reports.r09_dq_issues AS
SELECT i.system_name, i.rule_name, count(*) AS issues,
       count(*) FILTER (WHERE q.source_record_id IS NOT NULL) AS matches_seeded_case,
       string_agg(i.record_key, ', ' ORDER BY i.record_key) AS records
  FROM audit.dq_issue i
  LEFT JOIN qa.dq_test_cases q ON q.source_system = i.system_name AND q.source_record_id = i.record_key
 WHERE i.run_id IN (SELECT run_id FROM reports.r01_pipeline_runs WHERE step_name = 'silver_vault_load')
 GROUP BY i.system_name, i.rule_name
 ORDER BY i.system_name, i.rule_name;

-- R10 Business report: enrolments by program and status (from the star schema)
CREATE OR REPLACE VIEW reports.r10_enrolments_by_program AS
SELECT p.study_level, p.program_name,
       count(*) AS enrolments,
       count(*) FILTER (WHERE f.enrolment_status = 'Enrolled') AS currently_enrolled,
       count(*) FILTER (WHERE f.enrolment_status = 'Completed') AS completed,
       count(*) FILTER (WHERE f.is_international) AS international,
       count(*) FILTER (WHERE dp.in_hrms) AS also_staff,
       count(*) FILTER (WHERE dp.in_crm) AS also_in_crm,
       round(avg(f.gpa), 2) AS avg_gpa
  FROM gold.fact_enrolment f
  JOIN gold.dim_program p ON p.program_key = f.program_key
  JOIN gold.dim_person dp ON dp.person_key = f.person_key
 GROUP BY p.study_level, p.program_name
 ORDER BY p.study_level, enrolments DESC;
