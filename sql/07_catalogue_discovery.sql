-- =============================================================================
-- 07 Active metadata catalogue: discovery scan
-- Design element: data fabric / catalogue (imitated in Postgres). The scan
-- walks every table in the database, classifies personal-data columns by
-- name, records them in audit.pii_column, refreshes row counts, and adds any
-- table that nobody registered as FOUND_BY_SCAN. This is how the shadow
-- copies in dev_sandbox enter the catalogue. A PII holdings snapshot is taken
-- each time, so reports can compare before and after retention.
-- =============================================================================

CREATE OR REPLACE FUNCTION audit.classify_column(p_column TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN p_column ~* '^(first_name|last_name|full_name|email|phone|home_address|address)$' THEN 'DIRECT'
             WHEN p_column ~* '^(tax_file_number|tfn|bank_bsb|bank_account|salary_band|lifetime_donation_aud|outstanding_fees_aud)$' THEN 'FINANCIAL'
             WHEN p_column ~* '^(visa_status|gpa|international_flag|sensitive_value|employer)$' THEN 'SENSITIVE'
             WHEN p_column ~* '^(date_of_birth|dob|postcode|suburb)$' THEN 'QUASI'
           END;
$$;

CREATE OR REPLACE PROCEDURE audit.scan_for_pii(p_run_id INT, p_phase TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    t           RECORD;
    v_dataset   TEXT;
    v_rows      BIGINT;
    v_real      BOOLEAN;
    v_masked    BOOLEAN;
    v_unmasked  BIGINT;
    v_found     INT := 0;
    v_pii_rows  BIGINT;
    v_cond      TEXT;
    v_scanned   INT := 0;
BEGIN
    FOR t IN
        SELECT table_schema, table_name
          FROM information_schema.tables
         WHERE table_type = 'BASE TABLE'
           AND table_schema IN ('src_hrms', 'src_sis', 'src_crm', 'dev_sandbox', 'bronze', 'silver', 'gold', 'test_masked')
         ORDER BY 1, 2
    LOOP
        v_dataset := t.table_schema || '.' || t.table_name;
        v_scanned := v_scanned + 1;
        EXECUTE format('SELECT count(*) FROM %I.%I', t.table_schema, t.table_name) INTO v_rows;

        INSERT INTO audit.pii_column (dataset, column_name, sensitivity_level, detected_by)
        SELECT v_dataset, c.column_name, audit.classify_column(c.column_name), 'column-name rule'
          FROM information_schema.columns c
         WHERE c.table_schema = t.table_schema AND c.table_name = t.table_name
           AND audit.classify_column(c.column_name) IS NOT NULL
        ON CONFLICT (dataset, column_name) DO NOTHING;

        IF NOT EXISTS (SELECT 1 FROM audit.dataset WHERE dataset = v_dataset) THEN
            -- Unregistered table: decide whether it holds real, unmasked personal data.
            v_unmasked := NULL;
            IF EXISTS (SELECT 1 FROM information_schema.columns
                        WHERE table_schema = t.table_schema AND table_name = t.table_name AND column_name = 'email') THEN
                EXECUTE format('SELECT count(*) FROM %I.%I WHERE email IS NOT NULL AND email NOT ILIKE %L',
                               t.table_schema, t.table_name, '%@example.invalid') INTO v_unmasked;
            END IF;
            v_real := coalesce(v_unmasked > 0,
                               EXISTS (SELECT 1 FROM audit.pii_column WHERE dataset = v_dataset AND sensitivity_level = 'DIRECT'));
            v_masked := NOT v_real;

            INSERT INTO audit.dataset (dataset, layer, environment, contains_real_pii, masked, owner, status, notes)
            VALUES (v_dataset,
                    CASE WHEN t.table_schema = 'dev_sandbox' THEN 'dev_sandbox' ELSE 'source' END,
                    t.table_name, v_real, v_masked, 'UNKNOWN', 'FOUND_BY_SCAN',
                    'Not registered by any pipeline; no lineage recorded. '
                    || coalesce(v_unmasked, 0) || ' rows hold unmasked email addresses.');
            v_found := v_found + 1;
        END IF;

        -- Rows that still hold real personal data: any DIRECT column filled, and not a masked email.
        -- Masked datasets hold only fake values, so they count as zero.
        SELECT string_agg(format('%I IS NOT NULL', column_name), ' OR ')
          INTO v_cond
          FROM audit.pii_column WHERE dataset = v_dataset AND sensitivity_level = 'DIRECT';
        IF v_cond IS NULL OR (SELECT masked FROM audit.dataset WHERE dataset = v_dataset) THEN
            v_pii_rows := 0;
        ELSE
            IF EXISTS (SELECT 1 FROM audit.pii_column WHERE dataset = v_dataset AND column_name = 'email') THEN
                v_cond := format('(%s) AND (email IS NULL OR email NOT ILIKE %L)', v_cond, '%@example.invalid');
            END IF;
            EXECUTE format('SELECT count(*) FROM %I.%I WHERE %s', t.table_schema, t.table_name, v_cond) INTO v_pii_rows;
        END IF;

        UPDATE audit.dataset SET row_count = v_rows, real_pii_rows = v_pii_rows, last_scanned_at = clock_timestamp()
         WHERE dataset = v_dataset;
    END LOOP;

    -- Catalogue entries whose table no longer exists
    UPDATE audit.dataset d
       SET status = 'PURGED', row_count = 0, real_pii_rows = 0, last_scanned_at = clock_timestamp()
     WHERE d.status <> 'PURGED' AND to_regclass(d.dataset) IS NULL;

    INSERT INTO audit.pii_holding_snapshot (run_id, phase, dataset, layer, status, contains_real_pii, masked, row_count, real_pii_rows)
    SELECT p_run_id, p_phase, dataset, layer, status, contains_real_pii, masked, coalesce(row_count, 0), coalesce(real_pii_rows, 0)
      FROM audit.dataset
     WHERE contains_real_pii OR masked;

    CALL audit.set_step_rows(p_run_id, v_scanned, v_found);
END;
$$;
