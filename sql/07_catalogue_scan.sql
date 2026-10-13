-- 07 Discovery scan: look at every table in the database, record which columns
-- hold personal data, and add any table nobody registered to the catalogue.
-- This is how the shadow copies in dev_sandbox show up.

CREATE OR REPLACE FUNCTION audit.pii_category(p_column TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_column IN ('first_name', 'last_name', 'email', 'phone', 'home_address') THEN 'DIRECT'
        WHEN p_column IN ('date_of_birth', 'suburb', 'postcode')                       THEN 'QUASI'
        WHEN p_column IN ('visa_status', 'gpa', 'international_flag', 'sensitive_value') THEN 'SENSITIVE'
        WHEN p_column IN ('tax_file_number', 'bank_bsb', 'bank_account', 'salary_band',
                          'lifetime_donation_aud', 'outstanding_fees_aud')            THEN 'FINANCIAL'
    END;
$$;

CREATE OR REPLACE PROCEDURE audit.scan_catalogue(p_run_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_found INT;
BEGIN
    -- Personal-data columns in every table
    INSERT INTO audit.pii_column (dataset, column_name, category)
    SELECT c.table_schema || '.' || c.table_name, c.column_name, audit.pii_category(c.column_name)
      FROM information_schema.columns c
      JOIN information_schema.tables t USING (table_schema, table_name)
     WHERE t.table_type = 'BASE TABLE'
       AND c.table_schema IN ('src_hrms', 'src_sis', 'src_crm', 'dev_sandbox',
                              'bronze', 'silver', 'gold', 'test_masked')
       AND audit.pii_category(c.column_name) IS NOT NULL
    ON CONFLICT DO NOTHING;

    -- Tables that are not in the catalogue
    INSERT INTO audit.dataset (dataset, layer, owner, real_pii, status)
    SELECT t.table_schema || '.' || t.table_name, t.table_schema, 'UNKNOWN',
           EXISTS (SELECT 1 FROM audit.pii_column p
                    WHERE p.dataset = t.table_schema || '.' || t.table_name AND p.category = 'DIRECT'),
           'FOUND_BY_SCAN'
      FROM information_schema.tables t
     WHERE t.table_type = 'BASE TABLE'
       AND t.table_schema IN ('src_hrms', 'src_sis', 'src_crm', 'dev_sandbox',
                              'bronze', 'silver', 'gold', 'test_masked')
    ON CONFLICT (dataset) DO NOTHING;
    GET DIAGNOSTICS v_found = ROW_COUNT;

    UPDATE audit.pipeline_run SET rows_loaded = v_found WHERE run_id = p_run_id;
END;
$$;
