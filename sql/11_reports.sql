-- 11 Reports. Each view answers one question. Run them in psql, e.g.
--     SELECT * FROM reports.checks;
-- reports.checks is the end-to-end test: every row should say PASS.

-- Every step of the most recent pipeline run.
CREATE OR REPLACE VIEW reports.pipeline_runs AS
SELECT run_id, step_name, status, rows_read, rows_loaded, error_message,
       round(extract(epoch FROM finished_at - started_at)::NUMERIC, 1) AS seconds
  FROM audit.pipeline_run
 WHERE batch_id = (SELECT batch_id FROM audit.pipeline_run ORDER BY run_id DESC LIMIT 1)
 ORDER BY run_id;

-- Every failed step ever (they stay logged even though their work was rolled back).
CREATE OR REPLACE VIEW reports.failed_steps AS
SELECT run_id, step_name, error_message, started_at
  FROM audit.pipeline_run WHERE status = 'FAILED' ORDER BY run_id;

-- What retention did on its most recent run.
CREATE OR REPLACE VIEW reports.retention_results AS
SELECT l.policy_id, p.description, l.target, l.action, l.rows_before, l.rows_affected, l.rows_after
  FROM audit.purge_log l JOIN audit.retention_policy p USING (policy_id)
 WHERE l.run_id = (SELECT max(run_id) FROM audit.purge_log)
 ORDER BY l.policy_id;

-- Personal data that is past its use-by date right now (should be empty after a run).
CREATE OR REPLACE VIEW reports.retention_overdue AS
SELECT 'RP-01' AS policy_id, sis_student_id AS record_id, retention_expiry_date
  FROM silver.student_current WHERE retention_expiry_date < current_date AND anonymised_at IS NULL
UNION ALL
SELECT 'RP-02', hr_employee_id, retention_expiry_date
  FROM silver.employee_current WHERE retention_expiry_date < current_date AND anonymised_at IS NULL
UNION ALL
SELECT 'RP-03', crm_contact_id, retention_expiry_date
  FROM silver.constituent_current WHERE retention_expiry_date < current_date AND anonymised_at IS NULL
UNION ALL
SELECT 'RP-04', shadow_record_id, retention_expiry_date
  FROM dev_sandbox.shadow_extracts WHERE retention_expiry_date < current_date;

-- The catalogue: every dataset, its owner, its personal-data columns and where its data came from.
CREATE OR REPLACE VIEW reports.catalogue AS
SELECT d.dataset, d.layer, d.status, d.owner, d.real_pii,
       (SELECT count(*) FROM audit.pii_column c WHERE c.dataset = d.dataset) AS pii_columns,
       coalesce((SELECT string_agg(DISTINCT l.source, ', ') FROM audit.lineage l WHERE l.target = d.dataset),
                'unknown (no lineage)') AS comes_from
  FROM audit.dataset d
 ORDER BY d.layer, d.dataset;

-- How many people appear in one, two or three systems.
CREATE OR REPLACE VIEW reports.identity_overlap AS
SELECT system_count,
       concat_ws(' + ', CASE WHEN in_hrms THEN 'HRMS' END, CASE WHEN in_sis THEN 'SIS' END,
                        CASE WHEN in_crm THEN 'ADV_CRM' END) AS systems,
       count(*) AS people
  FROM gold.dim_person
 GROUP BY 1, 2
 ORDER BY 1, 2;

-- How accurate the matching is, compared with the answer key.
-- A "link" is a pair of records put in the same person.
--   precision = of the links we made, how many were right
--   recall    = of the links that should exist, how many we found
CREATE OR REPLACE VIEW reports.identity_accuracy AS
WITH r AS (
    SELECT l.person_id, k.true_person_id
      FROM silver.link_person l
      JOIN qa.identity_answer_key k ON k.source_system = l.system_name AND k.source_record_id = l.source_record_id
),
made    AS (SELECT sum(n * (n - 1) / 2) AS links FROM (SELECT count(*) n FROM r GROUP BY person_id) x),
should  AS (SELECT sum(n * (n - 1) / 2) AS links FROM (SELECT count(*) n FROM r GROUP BY true_person_id) x),
correct AS (SELECT sum(n * (n - 1) / 2) AS links FROM (SELECT count(*) n FROM r GROUP BY person_id, true_person_id) x)
SELECT (SELECT count(DISTINCT true_person_id) FROM r) AS real_people,
       (SELECT count(DISTINCT person_id) FROM r)      AS people_found,
       correct.links                                   AS correct_links,
       made.links - correct.links                      AS wrong_links,
       should.links - correct.links                    AS missed_links,
       round(100.0 * correct.links / made.links, 2)    AS precision_pct,
       round(100.0 * correct.links / should.links, 2)  AS recall_pct
  FROM made, should, correct;

-- Is any real personal data in the masked test tables? Every count should be 0.
CREATE OR REPLACE VIEW reports.masking_check AS
WITH real AS (
    SELECT silver.clean_email(email) AS email, silver.clean_phone(phone) AS phone,
           lower(first_name) AS first_name, lower(last_name) AS last_name, date_of_birth
      FROM src_hrms.employee
    UNION ALL
    SELECT silver.clean_email(email), silver.clean_phone(phone), lower(first_name), lower(last_name), date_of_birth
      FROM src_sis.student
    UNION ALL
    SELECT silver.clean_email(email), silver.clean_phone(phone), lower(first_name), lower(last_name), date_of_birth
      FROM src_crm.constituent
),
masked AS (
    SELECT hr_employee_id AS id, email, phone, lower(first_name) AS first_name, lower(last_name) AS last_name,
           date_of_birth FROM test_masked.employee
    UNION ALL
    SELECT sis_student_id, email, phone, lower(first_name), lower(last_name), date_of_birth FROM test_masked.student
    UNION ALL
    SELECT crm_contact_id, email, phone, lower(first_name), lower(last_name), date_of_birth FROM test_masked.constituent
)
SELECT 'real email addresses' AS check_name,
       (SELECT count(*) FROM masked WHERE email IN (SELECT email FROM real)) AS found
UNION ALL
SELECT 'real phone numbers', (SELECT count(*) FROM masked WHERE phone IN (SELECT phone FROM real))
UNION ALL
SELECT 'real first names', (SELECT count(*) FROM masked WHERE first_name IN (SELECT first_name FROM real))
UNION ALL
SELECT 'real name + date of birth', (SELECT count(*) FROM masked m JOIN real r USING (first_name, last_name, date_of_birth))
UNION ALL
SELECT 'real source IDs', (SELECT count(*) FROM masked
                            WHERE id IN (SELECT hr_employee_id FROM src_hrms.employee
                                         UNION ALL SELECT sis_student_id FROM src_sis.student
                                         UNION ALL SELECT crm_contact_id FROM src_crm.constituent))
UNION ALL
SELECT 'student keeps real date of birth',
       (SELECT count(*) FROM test_masked.student m JOIN src_sis.student s
            ON test_masked.pseudo(s.sis_student_id, 'STU') = m.sis_student_id
         WHERE m.date_of_birth = s.date_of_birth)
UNION ALL
SELECT 'anonymised people included',
       (SELECT count(*) FROM test_masked.student m JOIN silver.student_current s
            ON test_masked.pseudo(s.sis_student_id, 'STU') = m.sis_student_id
         WHERE s.anonymised_at IS NOT NULL);

-- End-to-end test. Every row should say PASS.
CREATE OR REPLACE VIEW reports.checks AS
WITH c (check_name, ok, detail) AS (
    SELECT 'every step of the last run succeeded',
           NOT EXISTS (SELECT 1 FROM reports.pipeline_runs WHERE status <> 'SUCCESS'),
           (SELECT count(*) FROM reports.pipeline_runs)::TEXT || ' steps'
    UNION ALL
    SELECT 'bronze has every source row',
           (SELECT count(*) FROM bronze.hrms_employee) = (SELECT count(*) FROM src_hrms.employee)
       AND (SELECT count(*) FROM bronze.sis_student) = (SELECT count(*) FROM src_sis.student)
       AND (SELECT count(*) FROM bronze.crm_constituent) = (SELECT count(*) FROM src_crm.constituent), ''
    UNION ALL
    SELECT 'silver has a hub row for every source record',
           (SELECT count(*) FROM silver.hub_employee) = (SELECT count(*) FROM src_hrms.employee)
       AND (SELECT count(*) FROM silver.hub_student) = (SELECT count(*) FROM src_sis.student)
       AND (SELECT count(*) FROM silver.hub_constituent) = (SELECT count(*) FROM src_crm.constituent), ''
    UNION ALL
    SELECT 'every source record is linked to one person',
           (SELECT count(*) FROM silver.link_person) = (SELECT count(*) FROM src_hrms.employee)
                                                      + (SELECT count(*) FROM src_sis.student)
                                                      + (SELECT count(*) FROM src_crm.constituent), ''
    UNION ALL
    SELECT 'matching precision is at least 99%',
           (SELECT precision_pct >= 99 FROM reports.identity_accuracy),
           (SELECT precision_pct || '% precision, ' || recall_pct || '% recall' FROM reports.identity_accuracy)
    UNION ALL
    SELECT 'masked data holds no real personal data',
           (SELECT sum(found) = 0 FROM reports.masking_check),
           (SELECT count(*) FROM test_masked.student) + (SELECT count(*) FROM test_masked.employee)
           + (SELECT count(*) FROM test_masked.constituent) || ' masked rows'
    UNION ALL
    SELECT 'no personal data past its retention date',
           NOT EXISTS (SELECT 1 FROM reports.retention_overdue), ''
    UNION ALL
    SELECT 'shadow copies are no longer FOUND_BY_SCAN',
           NOT EXISTS (SELECT 1 FROM audit.dataset WHERE layer = 'dev_sandbox' AND status = 'FOUND_BY_SCAN'),
           (SELECT status FROM audit.dataset WHERE dataset = 'dev_sandbox.shadow_extracts')
    UNION ALL
    SELECT 'every table is in the catalogue',
           NOT EXISTS (SELECT 1 FROM information_schema.tables t
                        WHERE t.table_type = 'BASE TABLE'
                          AND t.table_schema IN ('src_hrms', 'src_sis', 'src_crm', 'dev_sandbox',
                                                 'bronze', 'silver', 'gold', 'test_masked')
                          AND t.table_schema || '.' || t.table_name NOT IN (SELECT dataset FROM audit.dataset)), ''
    UNION ALL
    SELECT 'every registered dataset has lineage',
           NOT EXISTS (SELECT 1 FROM audit.dataset d
                        WHERE d.status = 'REGISTERED' AND d.layer <> 'qa'
                          AND d.dataset NOT IN (SELECT target FROM audit.lineage)), ''
)
SELECT check_name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, detail FROM c;
