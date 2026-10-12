-- =============================================================================
-- 06 Masked test data provisioning
-- Design element: test data management. Developers get realistic data for all
-- three systems without any real personal data:
--   * IDs are pseudonymised with a keyed hash (HMAC-SHA256). The same input
--     always gives the same pseudonym, so joins between masked tables still
--     work (person_ref links one person's masked records across systems), but
--     nobody can recompute a pseudonym without the key.
--   * The key is generated randomly inside the database on first run. It is
--     never written to the repository.
--   * Names come from a fake-name list that shares no names with the real
--     data; dates of birth are shifted by 15-350 days either way; emails and
--     phones are replaced; tax file numbers, bank details and street
--     addresses are removed; donation amounts are rounded into bands.
--   * Records whose PII was erased by retention are not provisioned.
-- =============================================================================

CREATE TABLE IF NOT EXISTS audit.masking_key (
    key_id      SERIAL PRIMARY KEY,
    secret      BYTEA NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO audit.masking_key (secret)
SELECT gen_random_bytes(32)
WHERE NOT EXISTS (SELECT 1 FROM audit.masking_key);

-- Hex digest of the keyed hash, domain-separated so 'STU' and 'EMP' pseudonyms differ.
CREATE OR REPLACE FUNCTION test_masked.keyed_hex(p_value TEXT, p_domain TEXT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT encode(hmac(convert_to(p_domain || ':' || p_value, 'UTF8'),
                       (SELECT secret FROM audit.masking_key ORDER BY key_id LIMIT 1), 'sha256'), 'hex');
$$;

CREATE OR REPLACE FUNCTION test_masked.pseudo(p_value TEXT, p_domain TEXT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT p_domain || '-' || upper(left(test_masked.keyed_hex(p_value, p_domain), 12));
$$;

-- Keyed integer in [0, p_mod)
CREATE OR REPLACE FUNCTION test_masked.keyed_int(p_value TEXT, p_domain TEXT, p_mod INT)
RETURNS INT LANGUAGE sql STABLE AS $$
    SELECT (('x' || left(test_masked.keyed_hex(p_value, p_domain), 8))::BIT(32)::BIGINT % p_mod)::INT;
$$;

CREATE OR REPLACE FUNCTION test_masked.fake_first(p_id TEXT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT (ARRAY['Ari', 'Bo', 'Cass', 'Dana', 'Eli', 'Frankie', 'Gale', 'Hollis', 'Indy', 'Jules',
                  'Kit', 'Lane', 'Morgan', 'Noor', 'Oakley', 'Parker', 'Quinn', 'Reese', 'Sage', 'Tatum',
                  'Uma', 'Vale', 'Wren', 'Yael', 'Zion', 'Rowan', 'Sky', 'Jordan', 'Emery', 'Remy'])
           [1 + test_masked.keyed_int(p_id, 'FN', 30)];
$$;

CREATE OR REPLACE FUNCTION test_masked.fake_last(p_id TEXT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT (ARRAY['Ashdown', 'Birchwood', 'Coldwater', 'Dunmore', 'Eastwick', 'Fernhill', 'Glenrock',
                  'Hollowell', 'Ironbark', 'Juniper', 'Kestrel', 'Larkspur', 'Millbrook', 'Northcote', 'Oakridge',
                  'Pinecrest', 'Quarrington', 'Riverside', 'Stonebridge', 'Thornbury', 'Underwood', 'Westbrook',
                  'Yarrow', 'Zephyr', 'Ambleside', 'Bellmount', 'Copperfield', 'Driftwood', 'Elmstead', 'Foxglove'])
           [1 + test_masked.keyed_int(p_id, 'LN', 30)];
$$;

-- Shift by 15-350 days earlier or later, so the year often changes and no row keeps its real DOB.
CREATE OR REPLACE FUNCTION test_masked.shift_date(p_date DATE, p_id TEXT)
RETURNS DATE LANGUAGE sql STABLE AS $$
    SELECT p_date + (CASE WHEN test_masked.keyed_int(p_id, 'DS', 2) = 0 THEN -1 ELSE 1 END)
                    * (15 + test_masked.keyed_int(p_id, 'DD', 336));
$$;

-- 0491 57x xxx: a block the source systems never issue, so a masked number cannot be a real one.
CREATE OR REPLACE FUNCTION test_masked.fake_phone(p_id TEXT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT '049157' || lpad(test_masked.keyed_int(p_id, 'PH', 10000)::TEXT, 4, '0');
$$;

CREATE OR REPLACE PROCEDURE test_masked.provision_masked_data(p_run_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_rows BIGINT := 0;
    v_n    BIGINT;
BEGIN
    DROP TABLE IF EXISTS test_masked.student, test_masked.employee, test_masked.constituent CASCADE;

    -- ---------------------------------------------------------------- SIS
    CREATE TABLE test_masked.student AS
    SELECT test_masked.pseudo(s.sis_student_id, 'STU')                AS sis_student_id,
           test_masked.pseudo(hp.person_id, 'PER')                    AS person_ref,
           test_masked.fake_first(s.sis_student_id)                   AS first_name,
           test_masked.fake_last(s.sis_student_id)                    AS last_name,
           test_masked.shift_date(s.date_of_birth, s.sis_student_id)  AS date_of_birth,
           lower(test_masked.pseudo(s.sis_student_id, 'STU')) || '@example.invalid' AS email,
           test_masked.fake_phone(s.sis_student_id)                   AS phone,
           s.suburb, s.postcode, s.international_flag, s.visa_status,
           s.program_code, s.program_name, s.study_level, s.enrolment_status,
           s.enrolment_year, s.completion_year, s.gpa, s.outstanding_fees_aud
      FROM silver.v_student_current s
      JOIN silver.link_person_identity l ON l.system_name = 'SIS' AND l.business_key = s.sis_student_id
      JOIN silver.hub_person hp ON hp.person_hk = l.person_hk
     WHERE s.anonymised_at IS NULL AND s.first_name IS NOT NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_rows := v_rows + v_n;
    ALTER TABLE test_masked.student ADD PRIMARY KEY (sis_student_id);   -- fails loudly on a pseudonym collision
    CALL audit.record_lineage(p_run_id, 'silver.v_student_current', 'test_masked.student', 'MASK', v_n, TRUE);

    -- --------------------------------------------------------------- HRMS
    CREATE TABLE test_masked.employee AS
    SELECT test_masked.pseudo(e.hr_employee_id, 'EMP')                AS hr_employee_id,
           test_masked.pseudo(hp.person_id, 'PER')                    AS person_ref,
           test_masked.fake_first(e.hr_employee_id)                   AS first_name,
           test_masked.fake_last(e.hr_employee_id)                    AS last_name,
           test_masked.shift_date(e.date_of_birth, e.hr_employee_id)  AS date_of_birth,
           lower(test_masked.pseudo(e.hr_employee_id, 'EMP')) || '@example.invalid' AS email,
           test_masked.fake_phone(e.hr_employee_id)                   AS phone,
           e.suburb, e.postcode,
           NULL::TEXT AS tax_file_number, NULL::TEXT AS bank_bsb, NULL::TEXT AS bank_account,
           e.department, e.position_title, e.salary_band, e.employment_status,
           e.employment_start_date, e.employment_end_date
      FROM silver.v_employee_current e
      JOIN silver.link_person_identity l ON l.system_name = 'HRMS' AND l.business_key = e.hr_employee_id
      JOIN silver.hub_person hp ON hp.person_hk = l.person_hk
     WHERE e.anonymised_at IS NULL AND e.first_name IS NOT NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_rows := v_rows + v_n;
    ALTER TABLE test_masked.employee ADD PRIMARY KEY (hr_employee_id);
    CALL audit.record_lineage(p_run_id, 'silver.v_employee_current', 'test_masked.employee', 'MASK', v_n, TRUE);

    -- ------------------------------------------------------------ ADV_CRM
    CREATE TABLE test_masked.constituent AS
    SELECT test_masked.pseudo(c.crm_contact_id, 'CRM')                AS crm_contact_id,
           test_masked.pseudo(hp.person_id, 'PER')                    AS person_ref,
           test_masked.fake_first(c.crm_contact_id)                   AS first_name,
           test_masked.fake_last(c.crm_contact_id)                    AS last_name,
           test_masked.shift_date(c.date_of_birth, c.crm_contact_id)  AS date_of_birth,
           lower(test_masked.pseudo(c.crm_contact_id, 'CRM')) || '@example.invalid' AS email,
           test_masked.fake_phone(c.crm_contact_id)                   AS phone,
           c.suburb, c.postcode, c.contact_type, c.alumni_year, c.donor_flag,
           round(c.lifetime_donation_aud, -3) AS lifetime_donation_band_aud,
           c.engagement_score, c.last_contact_date
      FROM silver.v_constituent_current c
      JOIN silver.link_person_identity l ON l.system_name = 'ADV_CRM' AND l.business_key = c.crm_contact_id
      JOIN silver.hub_person hp ON hp.person_hk = l.person_hk
     WHERE c.anonymised_at IS NULL AND c.first_name IS NOT NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_rows := v_rows + v_n;
    ALTER TABLE test_masked.constituent ADD PRIMARY KEY (crm_contact_id);
    CALL audit.record_lineage(p_run_id, 'silver.v_constituent_current', 'test_masked.constituent', 'MASK', v_n, TRUE);

    CREATE INDEX ON test_masked.student (person_ref);
    CREATE INDEX ON test_masked.employee (person_ref);
    CREATE INDEX ON test_masked.constituent (person_ref);

    CALL audit.register_dataset('test_masked.student', 'test_masked', 'test', FALSE, TRUE, 'Data Platform Team');
    CALL audit.register_dataset('test_masked.employee', 'test_masked', 'test', FALSE, TRUE, 'Data Platform Team');
    CALL audit.register_dataset('test_masked.constituent', 'test_masked', 'test', FALSE, TRUE, 'Data Platform Team');
    CALL audit.set_step_rows(p_run_id, v_rows::INT, v_rows::INT);
END;
$$;
