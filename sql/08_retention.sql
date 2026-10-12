-- =============================================================================
-- 08 Retention and purge engine
-- Design element: lifecycle management. Every review first writes the list of
-- records past their retention date to audit.retention_due_record (the
-- "use-by date" report). A dry run stops there. A live run then applies each
-- policy, records every action in audit.purge_log with before/after counts,
-- and adds erased records to audit.erasure_register so later loads cannot
-- bring the personal data back.
-- =============================================================================

CREATE OR REPLACE PROCEDURE audit.run_retention(
    p_run_id   INT,
    p_dry_run  BOOLEAN DEFAULT TRUE,
    p_as_of    DATE DEFAULT current_date)
LANGUAGE plpgsql AS $$
DECLARE
    v_review   INT;
    t          RECORD;
    b          RECORD;
    v_before   BIGINT;
    v_n        BIGINT;
    v_total    BIGINT := 0;
    v_due      BIGINT;
    v_set      TEXT;
BEGIN
    INSERT INTO audit.retention_review (run_id, as_of_date, dry_run)
    VALUES (p_run_id, p_as_of, p_dry_run) RETURNING review_id INTO v_review;

    -- =============================================== 1. Find everything that is due
    INSERT INTO audit.retention_due_record (review_id, policy_id, target_object, system_name, record_key, expired_on, days_overdue)
    SELECT v_review, 'RP-01', 'silver.sat_student_pii', 'SIS', sis_student_id, retention_expiry_date, p_as_of - retention_expiry_date
      FROM silver.v_student_current
     WHERE retention_expiry_date < p_as_of AND anonymised_at IS NULL AND first_name IS NOT NULL
    UNION ALL
    SELECT v_review, 'RP-02', 'silver.sat_employee_pii', 'HRMS', hr_employee_id, retention_expiry_date, p_as_of - retention_expiry_date
      FROM silver.v_employee_current
     WHERE retention_expiry_date < p_as_of AND anonymised_at IS NULL AND first_name IS NOT NULL
    UNION ALL
    SELECT v_review, 'RP-03', 'silver.sat_constituent_pii', 'ADV_CRM', crm_contact_id, retention_expiry_date, p_as_of - retention_expiry_date
      FROM silver.v_constituent_current
     WHERE retention_expiry_date < p_as_of AND first_name IS NOT NULL;

    -- RP-04: shadow copies, row by row, in every dev_sandbox table that still exists
    FOR t IN SELECT dataset FROM audit.dataset
              WHERE layer = 'dev_sandbox' AND to_regclass(dataset) IS NOT NULL ORDER BY dataset
    LOOP
        EXECUTE format(
            'INSERT INTO audit.retention_due_record (review_id, policy_id, target_object, system_name, record_key, expired_on, days_overdue)
             SELECT %s, %L, %L, source_system, shadow_record_id, retention_expiry_date, %L::DATE - retention_expiry_date
               FROM %s WHERE retention_expiry_date < %L::DATE',
            v_review, 'RP-04', t.dataset, p_as_of, t.dataset, p_as_of);
    END LOOP;

    -- RP-05: superseded bronze batches (one entry per batch)
    FOR b IN SELECT * FROM (VALUES ('bronze.hrms_employee_raw', 'HRMS'), ('bronze.sis_student_raw', 'SIS'),
                                   ('bronze.crm_constituent_raw', 'ADV_CRM')) v(tbl, sys)
              WHERE to_regclass(v.tbl) IS NOT NULL
    LOOP
        EXECUTE format(
            'INSERT INTO audit.retention_due_record (review_id, policy_id, target_object, system_name, record_key, expired_on, days_overdue)
             SELECT %s, %L, %L, %L, %L || pipeline_run_id, max(ingested_at)::DATE, %L::DATE - max(ingested_at)::DATE
               FROM %s WHERE pipeline_run_id < bronze.latest_batch(%L) GROUP BY pipeline_run_id',
            v_review, 'RP-05', b.tbl, b.sys, 'batch run_id=', p_as_of, b.tbl, b.tbl);
    END LOOP;

    SELECT count(*) INTO v_due FROM audit.retention_due_record WHERE review_id = v_review;

    IF p_dry_run THEN
        RAISE NOTICE '[DRY RUN] review % found % items past retention as of %', v_review, v_due, p_as_of;
        CALL audit.set_step_rows(p_run_id, v_due::INT, 0);
        RETURN;
    END IF;

    -- =============================================== 2. Apply the policies
    -- RP-01: anonymise student PII (every satellite version, so history holds no PII either)
    SELECT count(*) INTO v_before FROM silver.sat_student_pii WHERE anonymised_at IS NULL;
    UPDATE silver.sat_student_pii s
       SET first_name = NULL, last_name = NULL, date_of_birth = NULL, email = NULL, phone = NULL,
           home_address = NULL, visa_status = NULL, anonymised_at = clock_timestamp(), anonymised_by = 'RP-01'
      FROM silver.hub_student h
      JOIN audit.retention_due_record d ON d.review_id = v_review AND d.policy_id = 'RP-01' AND d.record_key = h.sis_student_id
     WHERE s.student_hk = h.student_hk AND s.anonymised_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
    INSERT INTO audit.purge_log (run_id, policy_id, target_object, action, rows_before, rows_affected, rows_after)
    VALUES (p_run_id, 'RP-01', 'silver.sat_student_pii', 'ANONYMISE', v_before, v_n, v_before - v_n);

    -- RP-02: anonymise former-staff PII including tax file numbers and bank details
    SELECT count(*) INTO v_before FROM silver.sat_employee_pii WHERE anonymised_at IS NULL;
    UPDATE silver.sat_employee_pii s
       SET first_name = NULL, last_name = NULL, date_of_birth = NULL, email = NULL, phone = NULL,
           home_address = NULL, tax_file_number = NULL, bank_bsb = NULL, bank_account = NULL,
           anonymised_at = clock_timestamp(), anonymised_by = 'RP-02'
      FROM silver.hub_employee h
      JOIN audit.retention_due_record d ON d.review_id = v_review AND d.policy_id = 'RP-02' AND d.record_key = h.hr_employee_id
     WHERE s.employee_hk = h.employee_hk AND s.anonymised_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
    INSERT INTO audit.purge_log (run_id, policy_id, target_object, action, rows_before, rows_affected, rows_after)
    VALUES (p_run_id, 'RP-02', 'silver.sat_employee_pii', 'ANONYMISE', v_before, v_n, v_before - v_n);

    -- RP-03: delete inactive non-donor contacts (PII and details); the hub keeps only the bare key
    SELECT count(*) INTO v_before FROM silver.sat_constituent_pii;
    DELETE FROM silver.sat_constituent_pii s
     USING silver.hub_constituent h, audit.retention_due_record d
     WHERE s.constituent_hk = h.constituent_hk
       AND d.review_id = v_review AND d.policy_id = 'RP-03' AND d.record_key = h.crm_contact_id;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
    INSERT INTO audit.purge_log (run_id, policy_id, target_object, action, rows_before, rows_affected, rows_after)
    VALUES (p_run_id, 'RP-03', 'silver.sat_constituent_pii', 'DELETE', v_before, v_n, v_before - v_n);

    SELECT count(*) INTO v_before FROM silver.sat_constituent_details;
    DELETE FROM silver.sat_constituent_details s
     USING silver.hub_constituent h, audit.retention_due_record d
     WHERE s.constituent_hk = h.constituent_hk
       AND d.review_id = v_review AND d.policy_id = 'RP-03' AND d.record_key = h.crm_contact_id;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
    INSERT INTO audit.purge_log (run_id, policy_id, target_object, action, rows_before, rows_affected, rows_after)
    VALUES (p_run_id, 'RP-03', 'silver.sat_constituent_details', 'DELETE', v_before, v_n, v_before - v_n);

    DELETE FROM silver.link_person_identity l
     USING audit.retention_due_record d
     WHERE d.review_id = v_review AND d.policy_id = 'RP-03'
       AND l.system_name = 'ADV_CRM' AND l.business_key = d.record_key;
    DELETE FROM silver.hub_person hp     -- people who were only that contact
     WHERE NOT EXISTS (SELECT 1 FROM silver.link_person_identity l WHERE l.person_hk = hp.person_hk);

    -- Remember what was erased so the next load does not reintroduce it
    INSERT INTO audit.erasure_register (system_name, business_key, policy_id, action, run_id)
    SELECT d.system_name, d.record_key, d.policy_id, p.action, p_run_id
      FROM audit.retention_due_record d JOIN audit.retention_policy p USING (policy_id)
     WHERE d.review_id = v_review AND d.policy_id IN ('RP-01', 'RP-02', 'RP-03')
    ON CONFLICT (system_name, business_key) DO NOTHING;

    -- RP-04: delete expired shadow copies; drop a table once nothing lawful is left in it;
    -- quarantine (revoke access to) whatever remains until it is re-provisioned from test_masked
    FOR t IN SELECT dataset FROM audit.dataset
              WHERE layer = 'dev_sandbox' AND to_regclass(dataset) IS NOT NULL ORDER BY dataset
    LOOP
        EXECUTE format('SELECT count(*) FROM %s', t.dataset) INTO v_before;
        EXECUTE format('DELETE FROM %s WHERE retention_expiry_date < %L::DATE', t.dataset, p_as_of);
        GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
        INSERT INTO audit.purge_log (run_id, policy_id, target_object, action, rows_before, rows_affected, rows_after)
        VALUES (p_run_id, 'RP-04', t.dataset, 'DELETE', v_before, v_n, v_before - v_n);
        CALL audit.record_lineage(p_run_id, t.dataset, '(purged)', 'PURGE', v_n, FALSE);

        IF v_before - v_n = 0 THEN
            EXECUTE format('DROP TABLE %s', t.dataset);
            INSERT INTO audit.purge_log (run_id, policy_id, target_object, action, rows_before, rows_affected, rows_after)
            VALUES (p_run_id, 'RP-04', t.dataset, 'DROP_TABLE', 0, 0, 0);
            UPDATE audit.dataset SET status = 'PURGED', row_count = 0, real_pii_rows = 0 WHERE dataset = t.dataset;
        ELSE
            EXECUTE format('REVOKE ALL ON TABLE %s FROM PUBLIC', t.dataset);
            UPDATE audit.dataset
               SET status = 'QUARANTINED', row_count = v_before - v_n,
                   notes = 'Expired rows purged; remaining rows are within approved retention but unregistered. '
                           || 'Access revoked; replace with test_masked data.'
             WHERE dataset = t.dataset;
        END IF;
    END LOOP;

    -- RP-05: keep only the latest bronze batch, and erase PII there for records actioned above
    FOR b IN SELECT * FROM (VALUES ('bronze.hrms_employee_raw', 'HRMS', 'hr_employee_id'),
                                   ('bronze.sis_student_raw', 'SIS', 'sis_student_id'),
                                   ('bronze.crm_constituent_raw', 'ADV_CRM', 'crm_contact_id')) v(tbl, sys, keycol)
              WHERE to_regclass(v.tbl) IS NOT NULL
    LOOP
        EXECUTE format('SELECT count(*) FROM %s', b.tbl) INTO v_before;
        EXECUTE format('DELETE FROM %s WHERE pipeline_run_id < bronze.latest_batch(%L)', b.tbl, b.tbl);
        GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
        INSERT INTO audit.purge_log (run_id, policy_id, target_object, action, rows_before, rows_affected, rows_after)
        VALUES (p_run_id, 'RP-05', b.tbl, 'DELETE', v_before, v_n, v_before - v_n);

        -- Columns to blank come from the catalogue's PII classification of this table
        SELECT string_agg(format('%I = NULL', column_name), ', ')
          INTO v_set
          FROM audit.pii_column
         WHERE dataset = b.tbl AND (sensitivity_level IN ('DIRECT', 'FINANCIAL') OR column_name = 'date_of_birth');

        IF v_set IS NOT NULL THEN
            EXECUTE format(
                'UPDATE %s r SET %s FROM audit.erasure_register e
                  WHERE e.system_name = %L AND e.action = %L AND e.business_key = r.%I',
                b.tbl, v_set, b.sys, 'ANONYMISE', b.keycol);
            GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
            INSERT INTO audit.purge_log (run_id, policy_id, target_object, action, rows_before, rows_affected, rows_after)
            VALUES (p_run_id, 'RP-05', b.tbl, 'ANONYMISE', NULL, v_n, NULL);
        END IF;

        EXECUTE format(
            'DELETE FROM %s r USING audit.erasure_register e
              WHERE e.system_name = %L AND e.action = %L AND e.business_key = r.%I',
            b.tbl, b.sys, 'DELETE', b.keycol);
        GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
        IF v_n > 0 THEN
            INSERT INTO audit.purge_log (run_id, policy_id, target_object, action, rows_before, rows_affected, rows_after)
            VALUES (p_run_id, 'RP-05', b.tbl, 'DELETE', NULL, v_n, NULL);
        END IF;
    END LOOP;

    UPDATE audit.retention_review SET dry_run = FALSE WHERE review_id = v_review;
    CALL audit.set_step_rows(p_run_id, v_due::INT, v_total::INT);
END;
$$;
