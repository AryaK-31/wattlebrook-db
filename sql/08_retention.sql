-- 08 Retention: remove personal data that is past its use-by date.
--   RP-01..RP-03  anonymise the person's details in silver (every version of the row)
--                 and blank the same details in bronze.
--   RP-04         delete shadow copies past their approved date. Whatever is left
--                 is still within its approved date, so the table is quarantined
--                 (nobody can read it) instead of dropped.
-- hash_diff is not changed when a row is anonymised, so the next load sees "no change"
-- and does not copy the personal data back in from the source system.

CREATE OR REPLACE PROCEDURE audit.run_retention(p_run_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_before INT;
    v_done   INT;
BEGIN
    -- RP-01 students -------------------------------------------------------
    SELECT count(*) INTO v_before FROM silver.student_current WHERE anonymised_at IS NULL;

    UPDATE silver.sat_student
       SET first_name = NULL, last_name = NULL, date_of_birth = NULL, email = NULL, phone = NULL,
           home_address = NULL, visa_status = NULL, anonymised_at = now()
     WHERE anonymised_at IS NULL
       AND student_hk IN (SELECT student_hk FROM silver.student_current
                           WHERE retention_expiry_date < current_date AND anonymised_at IS NULL);
    GET DIAGNOSTICS v_done = ROW_COUNT;

    INSERT INTO audit.purge_log (run_id, policy_id, target, action, rows_before, rows_affected, rows_after)
    VALUES (p_run_id, 'RP-01', 'silver.sat_student', 'ANONYMISE', v_before, v_done, v_before - v_done);

    -- RP-02 former staff ---------------------------------------------------
    SELECT count(*) INTO v_before FROM silver.employee_current WHERE anonymised_at IS NULL;

    UPDATE silver.sat_employee
       SET first_name = NULL, last_name = NULL, date_of_birth = NULL, email = NULL, phone = NULL,
           home_address = NULL, tax_file_number = NULL, bank_bsb = NULL, bank_account = NULL,
           anonymised_at = now()
     WHERE anonymised_at IS NULL
       AND employee_hk IN (SELECT employee_hk FROM silver.employee_current
                            WHERE retention_expiry_date < current_date AND anonymised_at IS NULL);
    GET DIAGNOSTICS v_done = ROW_COUNT;

    INSERT INTO audit.purge_log (run_id, policy_id, target, action, rows_before, rows_affected, rows_after)
    VALUES (p_run_id, 'RP-02', 'silver.sat_employee', 'ANONYMISE', v_before, v_done, v_before - v_done);

    -- RP-03 CRM contacts who are not donors ---------------------------------
    SELECT count(*) INTO v_before FROM silver.constituent_current WHERE anonymised_at IS NULL;

    UPDATE silver.sat_constituent
       SET first_name = NULL, last_name = NULL, date_of_birth = NULL, email = NULL, phone = NULL,
           home_address = NULL, employer = NULL, anonymised_at = now()
     WHERE anonymised_at IS NULL
       AND constituent_hk IN (SELECT constituent_hk FROM silver.constituent_current
                               WHERE retention_expiry_date < current_date AND anonymised_at IS NULL);
    GET DIAGNOSTICS v_done = ROW_COUNT;

    INSERT INTO audit.purge_log (run_id, policy_id, target, action, rows_before, rows_affected, rows_after)
    VALUES (p_run_id, 'RP-03', 'silver.sat_constituent', 'ANONYMISE', v_before, v_done, v_before - v_done);

    -- Bronze is reloaded from the sources on every run, so blank the same people there too.
    UPDATE bronze.sis_student SET first_name = NULL, last_name = NULL, date_of_birth = NULL, email = NULL,
                                  phone = NULL, home_address = NULL, visa_status = NULL
     WHERE sis_student_id IN (SELECT sis_student_id FROM silver.student_current WHERE anonymised_at IS NOT NULL);

    UPDATE bronze.hrms_employee SET first_name = NULL, last_name = NULL, date_of_birth = NULL, email = NULL,
                                    phone = NULL, home_address = NULL, tax_file_number = NULL,
                                    bank_bsb = NULL, bank_account = NULL
     WHERE hr_employee_id IN (SELECT hr_employee_id FROM silver.employee_current WHERE anonymised_at IS NOT NULL);

    UPDATE bronze.crm_constituent SET first_name = NULL, last_name = NULL, date_of_birth = NULL, email = NULL,
                                      phone = NULL, home_address = NULL, employer = NULL
     WHERE crm_contact_id IN (SELECT crm_contact_id FROM silver.constituent_current WHERE anonymised_at IS NOT NULL);

    -- RP-04 shadow copies ---------------------------------------------------
    SELECT count(*) INTO v_before FROM dev_sandbox.shadow_extracts;

    DELETE FROM dev_sandbox.shadow_extracts WHERE retention_expiry_date < current_date;
    GET DIAGNOSTICS v_done = ROW_COUNT;

    INSERT INTO audit.purge_log (run_id, policy_id, target, action, rows_before, rows_affected, rows_after)
    VALUES (p_run_id, 'RP-04', 'dev_sandbox.shadow_extracts', 'DELETE', v_before, v_done, v_before - v_done);
    INSERT INTO audit.lineage (run_id, source, target, operation, row_count)
    VALUES (p_run_id, 'dev_sandbox.shadow_extracts', '(deleted)', 'PURGE', v_done);

    REVOKE ALL ON dev_sandbox.shadow_extracts FROM PUBLIC;
    UPDATE audit.dataset
       SET status = CASE WHEN v_before - v_done = 0 THEN 'PURGED' ELSE 'QUARANTINED' END
     WHERE dataset = 'dev_sandbox.shadow_extracts';
END;
$$;
