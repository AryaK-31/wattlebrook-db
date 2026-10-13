-- Demo queries for the presentation. Run them one at a time in psql after the pipeline.
-- They only read data, except the failure demo at the end, which undoes itself.

-- 1. The problem: Anh Le is in all three systems with three different IDs, emails and phone formats.
SELECT 'HRMS' AS system, hr_employee_id AS id, first_name, last_name, email, phone FROM src_hrms.employee WHERE hr_employee_id = 'EMP000001'
UNION ALL
SELECT 'SIS', sis_student_id, first_name, last_name, email, phone FROM src_sis.student WHERE sis_student_id = 'STU0000001'
UNION ALL
SELECT 'ADV_CRM', crm_contact_id, first_name, last_name, email, phone FROM src_crm.constituent WHERE crm_contact_id = 'CRM0000001';

-- 2. Identity matching linked the three records to one person, and says which rules matched.
SELECT * FROM silver.link_person
 WHERE person_id = (SELECT person_id FROM silver.link_person WHERE source_record_id = 'STU0000001');

-- 3. The same person in the masked test data: fake name, email and phone, same person_ref everywhere.
SELECT 'HRMS' AS system, hr_employee_id AS id, person_ref, first_name, last_name, email, phone FROM test_masked.employee
 WHERE person_ref = (SELECT person_ref FROM test_masked.student WHERE sis_student_id = test_masked.pseudo('STU0000001', 'STU'))
UNION ALL
SELECT 'SIS', sis_student_id, person_ref, first_name, last_name, email, phone FROM test_masked.student
 WHERE sis_student_id = test_masked.pseudo('STU0000001', 'STU');

-- 4. Pipeline log, catalogue and lineage.
SELECT * FROM reports.pipeline_runs;
SELECT * FROM reports.catalogue;
SELECT * FROM audit.lineage ORDER BY lineage_id DESC LIMIT 20;

-- 5. Retention: what was removed, and proof nothing overdue is left.
SELECT * FROM reports.retention_results;
SELECT count(*) AS still_overdue FROM reports.retention_overdue;

-- 6. Shadow copies that are left (still within their approved date), by where they were found.
SELECT environment, count(*) AS copies, min(retention_expiry_date) AS next_expiry
  FROM dev_sandbox.shadow_extracts GROUP BY environment ORDER BY copies DESC;

-- 7. Identity results and accuracy, masking check, and the end-to-end test.
SELECT * FROM reports.identity_overlap;
SELECT * FROM reports.identity_accuracy;
SELECT * FROM reports.masking_check;
SELECT * FROM reports.checks;

-- 8. Index demo: look up everything held about one email address.
EXPLAIN ANALYZE SELECT * FROM silver.sat_student WHERE email = 'anh.le1@student.wattlebrook.edu.au';

-- 9. Failure demo. Add a column the pipeline does not expect, run the pipeline (the
--    bronze_sis step fails and is rolled back), look at the log, then remove the column.
--    ALTER TABLE src_sis.student ADD COLUMN surprise TEXT;
--    (run: python python/run_pipeline.py)
--    SELECT * FROM reports.failed_steps;
--    ALTER TABLE src_sis.student DROP COLUMN surprise;
