-- =============================================================================
-- 04 Silver: Data Vault 2.0
-- Design elements: hubs (one per business key), satellites (descriptive
-- history, insert-only, change detected by hash_diff), the person hub and
-- identity link (filled by 05), data-quality checks, and a retention expiry
-- date on every satellite row that carries personal data.
--
-- Personal data is split from operational data (sat_*_pii vs sat_*_details),
-- so masking and retention act on the PII satellites without touching the
-- records the university must keep.
-- =============================================================================

-- ---------------------------------------------------------------- helpers
CREATE OR REPLACE FUNCTION silver.hash_key(p_business_key TEXT)
RETURNS CHAR(32) LANGUAGE sql IMMUTABLE AS $$
    SELECT md5(upper(btrim(p_business_key)));
$$;

-- Collapse spaces; fix all-caps / all-lower names; leave mixed case alone (e.g. O'Brien, McKay).
CREATE OR REPLACE FUNCTION silver.clean_name(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN v IS NULL OR v = '' THEN NULL
             WHEN v = upper(v) OR v = lower(v) THEN initcap(v)
             ELSE v
           END
    FROM (SELECT btrim(regexp_replace(p, '\s+', ' ', 'g')) AS v) x;
$$;

CREATE OR REPLACE FUNCTION silver.clean_email(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(lower(btrim(p)), '');
$$;

-- Normalise Australian mobiles to ten digits: '+61 412 345 678', '0412 345 678' -> '0412345678'.
CREATE OR REPLACE FUNCTION silver.clean_phone(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN d ~ '^61[0-9]{9}$' THEN '0' || substr(d, 3)
             WHEN d ~ '^[0-9]{9}$'   THEN '0' || d          -- leading zero lost by a spreadsheet
             WHEN d = ''             THEN NULL
             ELSE d
           END
    FROM (SELECT regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') AS d) x;
$$;

CREATE OR REPLACE FUNCTION silver.retention_days(p_policy TEXT)
RETURNS INT LANGUAGE sql STABLE AS $$
    SELECT retention_period_days FROM audit.retention_policy WHERE policy_id = p_policy;
$$;

-- Reference data for the matcher: common nicknames -> canonical first name.
CREATE TABLE IF NOT EXISTS silver.ref_nickname (
    nickname   TEXT PRIMARY KEY,
    canonical  TEXT NOT NULL
);
INSERT INTO silver.ref_nickname VALUES
('alex', 'alexander'), ('ben', 'benjamin'), ('chris', 'christopher'), ('dan', 'daniel'), ('liz', 'elizabeth'),
('bella', 'isabella'), ('jake', 'jacob'), ('jim', 'james'), ('kate', 'katherine'), ('matt', 'matthew'),
('mike', 'michael'), ('nick', 'nicholas'), ('becky', 'rebecca'), ('bob', 'robert'), ('sam', 'samuel'),
('tom', 'thomas'), ('tori', 'victoria'), ('will', 'william'), ('maggie', 'margaret'), ('trish', 'patricia'),
('jen', 'jennifer'), ('josh', 'joshua'), ('seb', 'sebastian'), ('andy', 'andrew'), ('tony', 'anthony')
ON CONFLICT (nickname) DO NOTHING;
CALL audit.register_dataset('silver.ref_nickname', 'silver', 'warehouse', FALSE, FALSE, 'Data Platform Team');
INSERT INTO audit.lineage (parent, child, operation, rows_moved)
SELECT 'reference data (04_silver_vault.sql)', 'silver.ref_nickname', 'GENERATE', 25
WHERE NOT EXISTS (SELECT 1 FROM audit.lineage WHERE child = 'silver.ref_nickname');

CREATE OR REPLACE FUNCTION silver.canonical_first(p TEXT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT coalesce((SELECT canonical FROM silver.ref_nickname WHERE nickname = lower(btrim(p))), lower(btrim(p)));
$$;

-- ------------------------------------------------------------------- hubs
CREATE TABLE IF NOT EXISTS silver.hub_student (
    student_hk       CHAR(32) PRIMARY KEY,
    sis_student_id   TEXT UNIQUE NOT NULL,
    load_dts         TIMESTAMPTZ NOT NULL,
    record_source    TEXT NOT NULL,
    pipeline_run_id  INT NOT NULL
);
CREATE TABLE IF NOT EXISTS silver.hub_employee (
    employee_hk      CHAR(32) PRIMARY KEY,
    hr_employee_id   TEXT UNIQUE NOT NULL,
    load_dts         TIMESTAMPTZ NOT NULL,
    record_source    TEXT NOT NULL,
    pipeline_run_id  INT NOT NULL
);
CREATE TABLE IF NOT EXISTS silver.hub_constituent (
    constituent_hk   CHAR(32) PRIMARY KEY,
    crm_contact_id   TEXT UNIQUE NOT NULL,
    load_dts         TIMESTAMPTZ NOT NULL,
    record_source    TEXT NOT NULL,
    pipeline_run_id  INT NOT NULL
);
CREATE TABLE IF NOT EXISTS silver.hub_person (
    person_hk        CHAR(32) PRIMARY KEY,
    person_id        TEXT UNIQUE NOT NULL,
    load_dts         TIMESTAMPTZ NOT NULL,
    pipeline_run_id  INT NOT NULL
);

-- ------------------------------------------------------------------- links
-- One row per source record: which person it belongs to and why.
CREATE TABLE IF NOT EXISTS silver.link_person_identity (
    link_hk           CHAR(32) PRIMARY KEY,
    person_hk         CHAR(32) NOT NULL REFERENCES silver.hub_person (person_hk),
    system_name       TEXT NOT NULL CHECK (system_name IN ('HRMS', 'SIS', 'ADV_CRM')),
    business_key      TEXT NOT NULL,
    source_hk         CHAR(32) NOT NULL,
    match_rule        TEXT NOT NULL,
    match_confidence  TEXT NOT NULL CHECK (match_confidence IN ('HIGH', 'MEDIUM', 'SINGLE')),
    load_dts          TIMESTAMPTZ NOT NULL,
    pipeline_run_id   INT NOT NULL,
    UNIQUE (system_name, business_key)
);

-- -------------------------------------------------------------- satellites
CREATE TABLE IF NOT EXISTS silver.sat_student_pii (
    student_hk            CHAR(32) NOT NULL REFERENCES silver.hub_student (student_hk),
    load_dts              TIMESTAMPTZ NOT NULL,
    hash_diff             CHAR(32) NOT NULL,
    first_name            TEXT,
    last_name             TEXT,
    date_of_birth         DATE,
    email                 TEXT,
    phone                 TEXT,
    home_address          TEXT,
    suburb                TEXT,
    postcode              TEXT,
    visa_status           TEXT,
    international_flag    TEXT,
    retention_expiry_date DATE,
    anonymised_at         TIMESTAMPTZ,
    anonymised_by         VARCHAR(10),
    record_source         TEXT NOT NULL,
    pipeline_run_id       INT NOT NULL,
    PRIMARY KEY (student_hk, load_dts)
);
CREATE TABLE IF NOT EXISTS silver.sat_student_enrolment (
    student_hk            CHAR(32) NOT NULL REFERENCES silver.hub_student (student_hk),
    load_dts              TIMESTAMPTZ NOT NULL,
    hash_diff             CHAR(32) NOT NULL,
    program_code          TEXT,
    program_name          TEXT,
    study_level           TEXT,
    enrolment_status      TEXT,
    enrolment_year        INT,
    completion_year       INT,
    gpa                   NUMERIC(4, 2),
    outstanding_fees_aud  NUMERIC(12, 2),
    last_activity_date    DATE,
    record_source         TEXT NOT NULL,
    pipeline_run_id       INT NOT NULL,
    PRIMARY KEY (student_hk, load_dts)
);
CREATE TABLE IF NOT EXISTS silver.sat_employee_pii (
    employee_hk           CHAR(32) NOT NULL REFERENCES silver.hub_employee (employee_hk),
    load_dts              TIMESTAMPTZ NOT NULL,
    hash_diff             CHAR(32) NOT NULL,
    first_name            TEXT,
    last_name             TEXT,
    date_of_birth         DATE,
    email                 TEXT,
    phone                 TEXT,
    home_address          TEXT,
    suburb                TEXT,
    postcode              TEXT,
    tax_file_number       TEXT,
    bank_bsb              TEXT,
    bank_account          TEXT,
    retention_expiry_date DATE,
    anonymised_at         TIMESTAMPTZ,
    anonymised_by         VARCHAR(10),
    record_source         TEXT NOT NULL,
    pipeline_run_id       INT NOT NULL,
    PRIMARY KEY (employee_hk, load_dts)
);
CREATE TABLE IF NOT EXISTS silver.sat_employee_details (
    employee_hk           CHAR(32) NOT NULL REFERENCES silver.hub_employee (employee_hk),
    load_dts              TIMESTAMPTZ NOT NULL,
    hash_diff             CHAR(32) NOT NULL,
    department            TEXT,
    position_title        TEXT,
    salary_band           TEXT,
    employment_status     TEXT,
    employment_start_date DATE,
    employment_end_date   DATE,
    record_source         TEXT NOT NULL,
    pipeline_run_id       INT NOT NULL,
    PRIMARY KEY (employee_hk, load_dts)
);
CREATE TABLE IF NOT EXISTS silver.sat_constituent_pii (
    constituent_hk        CHAR(32) NOT NULL REFERENCES silver.hub_constituent (constituent_hk),
    load_dts              TIMESTAMPTZ NOT NULL,
    hash_diff             CHAR(32) NOT NULL,
    first_name            TEXT,
    last_name             TEXT,
    date_of_birth         DATE,
    email                 TEXT,
    phone                 TEXT,
    home_address          TEXT,
    suburb                TEXT,
    postcode              TEXT,
    employer              TEXT,
    retention_expiry_date DATE,
    anonymised_at         TIMESTAMPTZ,
    anonymised_by         VARCHAR(10),
    record_source         TEXT NOT NULL,
    pipeline_run_id       INT NOT NULL,
    PRIMARY KEY (constituent_hk, load_dts)
);
CREATE TABLE IF NOT EXISTS silver.sat_constituent_details (
    constituent_hk        CHAR(32) NOT NULL REFERENCES silver.hub_constituent (constituent_hk),
    load_dts              TIMESTAMPTZ NOT NULL,
    hash_diff             CHAR(32) NOT NULL,
    contact_type          TEXT,
    alumni_year           INT,
    donor_flag            TEXT,
    lifetime_donation_aud NUMERIC(12, 2),
    engagement_score      INT,
    last_contact_date     DATE,
    record_source         TEXT NOT NULL,
    pipeline_run_id       INT NOT NULL,
    PRIMARY KEY (constituent_hk, load_dts)
);

-- Current-row views (latest satellite row per hub key). Most consumers use these.
CREATE OR REPLACE VIEW silver.v_student_current AS
SELECT h.sis_student_id, h.student_hk,
       p.first_name, p.last_name, p.date_of_birth, p.email, p.phone, p.home_address, p.suburb, p.postcode,
       p.visa_status, p.international_flag, p.retention_expiry_date, p.anonymised_at, p.anonymised_by,
       e.program_code, e.program_name, e.study_level, e.enrolment_status, e.enrolment_year,
       e.completion_year, e.gpa, e.outstanding_fees_aud, e.last_activity_date
FROM silver.hub_student h
LEFT JOIN LATERAL (SELECT * FROM silver.sat_student_pii s WHERE s.student_hk = h.student_hk
                   ORDER BY s.load_dts DESC LIMIT 1) p ON TRUE
LEFT JOIN LATERAL (SELECT * FROM silver.sat_student_enrolment s WHERE s.student_hk = h.student_hk
                   ORDER BY s.load_dts DESC LIMIT 1) e ON TRUE;

CREATE OR REPLACE VIEW silver.v_employee_current AS
SELECT h.hr_employee_id, h.employee_hk,
       p.first_name, p.last_name, p.date_of_birth, p.email, p.phone, p.home_address, p.suburb, p.postcode,
       p.tax_file_number, p.bank_bsb, p.bank_account, p.retention_expiry_date, p.anonymised_at, p.anonymised_by,
       d.department, d.position_title, d.salary_band, d.employment_status,
       d.employment_start_date, d.employment_end_date
FROM silver.hub_employee h
LEFT JOIN LATERAL (SELECT * FROM silver.sat_employee_pii s WHERE s.employee_hk = h.employee_hk
                   ORDER BY s.load_dts DESC LIMIT 1) p ON TRUE
LEFT JOIN LATERAL (SELECT * FROM silver.sat_employee_details s WHERE s.employee_hk = h.employee_hk
                   ORDER BY s.load_dts DESC LIMIT 1) d ON TRUE;

CREATE OR REPLACE VIEW silver.v_constituent_current AS
SELECT h.crm_contact_id, h.constituent_hk,
       p.first_name, p.last_name, p.date_of_birth, p.email, p.phone, p.home_address, p.suburb, p.postcode,
       p.employer, p.retention_expiry_date, p.anonymised_at, p.anonymised_by,
       d.contact_type, d.alumni_year, d.donor_flag, d.lifetime_donation_aud, d.engagement_score, d.last_contact_date
FROM silver.hub_constituent h
LEFT JOIN LATERAL (SELECT * FROM silver.sat_constituent_pii s WHERE s.constituent_hk = h.constituent_hk
                   ORDER BY s.load_dts DESC LIMIT 1) p ON TRUE
LEFT JOIN LATERAL (SELECT * FROM silver.sat_constituent_details s WHERE s.constituent_hk = h.constituent_hk
                   ORDER BY s.load_dts DESC LIMIT 1) d ON TRUE;

-- ------------------------------------------------------- load procedure
CREATE OR REPLACE PROCEDURE silver.load_vault(p_run_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_now     TIMESTAMPTZ := clock_timestamp();
    v_read    BIGINT := 0;
    v_loaded  BIGINT := 0;
    v_n       BIGINT;
    v_sis     BIGINT;
    v_hr      BIGINT;
    v_crm     BIGINT;
BEGIN
    -- ============ Stage the latest bronze batch of each system, cleaned and typed
    DROP TABLE IF EXISTS stg_sis, stg_hr, stg_crm;

    CREATE TEMP TABLE stg_sis ON COMMIT DROP AS
    SELECT silver.hash_key(sis_student_id) AS hk, btrim(sis_student_id) AS bk,
           silver.clean_name(first_name) AS first_name, silver.clean_name(last_name) AS last_name,
           date_of_birth::DATE AS date_of_birth, silver.clean_email(email) AS email,
           silver.clean_phone(phone::TEXT) AS phone, btrim(home_address) AS home_address,
           btrim(suburb) AS suburb, btrim(postcode::TEXT) AS postcode,
           visa_status, international_flag,
           program_code, program_name, study_level, enrolment_status,
           enrolment_year::INT AS enrolment_year, completion_year::INT AS completion_year,
           gpa::NUMERIC(4, 2) AS gpa, outstanding_fees_aud::NUMERIC(12, 2) AS outstanding_fees_aud,
           last_activity_date::DATE AS last_activity_date
    FROM bronze.sis_student_raw
    WHERE pipeline_run_id = bronze.latest_batch('bronze.sis_student_raw');

    CREATE TEMP TABLE stg_hr ON COMMIT DROP AS
    SELECT silver.hash_key(hr_employee_id) AS hk, btrim(hr_employee_id) AS bk,
           silver.clean_name(first_name) AS first_name, silver.clean_name(last_name) AS last_name,
           date_of_birth::DATE AS date_of_birth, silver.clean_email(email) AS email,
           silver.clean_phone(phone::TEXT) AS phone, btrim(home_address) AS home_address,
           btrim(suburb) AS suburb, btrim(postcode::TEXT) AS postcode,
           regexp_replace(tax_file_number::TEXT, '[^0-9]', '', 'g') AS tax_file_number,
           bank_bsb::TEXT AS bank_bsb, bank_account::TEXT AS bank_account,
           department, position_title, salary_band, employment_status,
           employment_start_date::DATE AS employment_start_date, employment_end_date::DATE AS employment_end_date
    FROM bronze.hrms_employee_raw
    WHERE pipeline_run_id = bronze.latest_batch('bronze.hrms_employee_raw');

    CREATE TEMP TABLE stg_crm ON COMMIT DROP AS
    SELECT silver.hash_key(crm_contact_id) AS hk, btrim(crm_contact_id) AS bk,
           silver.clean_name(first_name) AS first_name, silver.clean_name(last_name) AS last_name,
           date_of_birth::DATE AS date_of_birth, silver.clean_email(email) AS email,
           silver.clean_phone(phone::TEXT) AS phone, btrim(home_address) AS home_address,
           btrim(suburb) AS suburb, btrim(postcode::TEXT) AS postcode, employer,
           contact_type, alumni_year::INT AS alumni_year, donor_flag,
           lifetime_donation_aud::NUMERIC(12, 2) AS lifetime_donation_aud,
           engagement_score::INT AS engagement_score, last_contact_date::DATE AS last_contact_date
    FROM bronze.crm_constituent_raw
    WHERE pipeline_run_id = bronze.latest_batch('bronze.crm_constituent_raw');

    SELECT count(*) INTO v_sis FROM stg_sis;
    SELECT count(*) INTO v_hr FROM stg_hr;
    SELECT count(*) INTO v_crm FROM stg_crm;
    v_read := v_sis + v_hr + v_crm;

    -- ============ Data-quality checks (logged, rows still loaded and visible in reports)
    INSERT INTO audit.dq_issue (run_id, system_name, record_key, rule_name, detail)
    SELECT p_run_id, 'SIS', bk, 'DOB_IN_FUTURE', 'date_of_birth ' || date_of_birth
      FROM stg_sis WHERE date_of_birth > current_date
    UNION ALL
    SELECT p_run_id, 'SIS', bk, 'ENROLLED_BEFORE_AGE_15', 'enrolled ' || enrolment_year || ', born ' || date_of_birth
      FROM stg_sis WHERE enrolment_year < extract(year FROM date_of_birth) + 15
    UNION ALL
    SELECT p_run_id, 'HRMS', bk, 'DOB_IN_FUTURE', 'date_of_birth ' || date_of_birth
      FROM stg_hr WHERE date_of_birth > current_date
    UNION ALL
    SELECT p_run_id, 'HRMS', bk, 'HIRED_BEFORE_AGE_15', 'started ' || employment_start_date || ', born ' || date_of_birth
      FROM stg_hr WHERE employment_start_date < date_of_birth + INTERVAL '15 years'
    UNION ALL
    SELECT p_run_id, 'HRMS', bk, 'END_BEFORE_START', employment_start_date || ' to ' || employment_end_date
      FROM stg_hr WHERE employment_end_date < employment_start_date
    UNION ALL
    SELECT p_run_id, 'ADV_CRM', bk, 'DOB_IN_FUTURE', 'date_of_birth ' || date_of_birth
      FROM stg_crm WHERE date_of_birth > current_date
    UNION ALL
    SELECT p_run_id, 'ADV_CRM', bk, 'GRADUATED_BEFORE_AGE_15', 'alumni ' || alumni_year || ', born ' || date_of_birth
      FROM stg_crm WHERE alumni_year < extract(year FROM date_of_birth) + 15
    UNION ALL
    SELECT p_run_id, s.sys, s.bk, 'INVALID_EMAIL', s.email
      FROM (SELECT 'SIS' sys, bk, email FROM stg_sis UNION ALL SELECT 'HRMS', bk, email FROM stg_hr
            UNION ALL SELECT 'ADV_CRM', bk, email FROM stg_crm) s
     WHERE s.email IS NOT NULL AND s.email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$';

    -- Records whose PII was erased by retention must not be reloaded from the source.
    UPDATE stg_sis s SET first_name = NULL, last_name = NULL, date_of_birth = NULL, email = NULL, phone = NULL,
                         home_address = NULL, visa_status = NULL
      FROM audit.erasure_register e WHERE e.system_name = 'SIS' AND e.business_key = s.bk;
    UPDATE stg_hr s SET first_name = NULL, last_name = NULL, date_of_birth = NULL, email = NULL, phone = NULL,
                        home_address = NULL, tax_file_number = NULL, bank_bsb = NULL, bank_account = NULL
      FROM audit.erasure_register e WHERE e.system_name = 'HRMS' AND e.business_key = s.bk;
    DELETE FROM stg_crm s USING audit.erasure_register e
     WHERE e.system_name = 'ADV_CRM' AND e.business_key = s.bk AND e.action = 'DELETE';

    -- ============ Hubs (insert new business keys only)
    INSERT INTO silver.hub_student (student_hk, sis_student_id, load_dts, record_source, pipeline_run_id)
    SELECT hk, bk, v_now, 'SIS', p_run_id FROM stg_sis ON CONFLICT (student_hk) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    INSERT INTO silver.hub_employee (employee_hk, hr_employee_id, load_dts, record_source, pipeline_run_id)
    SELECT hk, bk, v_now, 'HRMS', p_run_id FROM stg_hr ON CONFLICT (employee_hk) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    INSERT INTO silver.hub_constituent (constituent_hk, crm_contact_id, load_dts, record_source, pipeline_run_id)
    SELECT hk, bk, v_now, 'ADV_CRM', p_run_id FROM stg_crm ON CONFLICT (constituent_hk) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    -- ============ Satellites: insert a new row only when the hash_diff changed
    -- Student PII (retention clock RP-01 starts at completion/withdrawal)
    INSERT INTO silver.sat_student_pii
    SELECT s.hk, v_now, s.hd, s.first_name, s.last_name, s.date_of_birth, s.email, s.phone, s.home_address,
           s.suburb, s.postcode, s.visa_status, s.international_flag,
           CASE WHEN s.enrolment_status IN ('Completed', 'Withdrawn')
                THEN s.last_activity_date + silver.retention_days('RP-01') END,
           NULL, NULL, 'SIS', p_run_id
    FROM (SELECT x.*, md5(concat_ws('|', coalesce(first_name, '~'), coalesce(last_name, '~'),
                 coalesce(date_of_birth::TEXT, '~'), coalesce(email, '~'), coalesce(phone, '~'),
                 coalesce(home_address, '~'), coalesce(suburb, '~'), coalesce(postcode, '~'),
                 coalesce(visa_status, '~'), coalesce(international_flag, '~'),
                 coalesce(enrolment_status, '~'), coalesce(last_activity_date::TEXT, '~'))) AS hd
          FROM stg_sis x) s
    LEFT JOIN LATERAL (SELECT hash_diff FROM silver.sat_student_pii c WHERE c.student_hk = s.hk
                       ORDER BY c.load_dts DESC LIMIT 1) cur ON TRUE
    WHERE cur.hash_diff IS DISTINCT FROM s.hd
      AND NOT EXISTS (SELECT 1 FROM audit.erasure_register e      -- already anonymised: keep it that way
                      WHERE e.system_name = 'SIS' AND e.business_key = s.bk AND cur.hash_diff IS NOT NULL);
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    INSERT INTO silver.sat_student_enrolment
    SELECT s.hk, v_now, s.hd, s.program_code, s.program_name, s.study_level, s.enrolment_status,
           s.enrolment_year, s.completion_year, s.gpa, s.outstanding_fees_aud, s.last_activity_date, 'SIS', p_run_id
    FROM (SELECT x.*, md5(concat_ws('|', coalesce(program_code, '~'), coalesce(enrolment_status, '~'),
                 coalesce(enrolment_year::TEXT, '~'), coalesce(completion_year::TEXT, '~'), coalesce(gpa::TEXT, '~'),
                 coalesce(outstanding_fees_aud::TEXT, '~'), coalesce(last_activity_date::TEXT, '~'))) AS hd
          FROM stg_sis x) s
    LEFT JOIN LATERAL (SELECT hash_diff FROM silver.sat_student_enrolment c WHERE c.student_hk = s.hk
                       ORDER BY c.load_dts DESC LIMIT 1) cur ON TRUE
    WHERE cur.hash_diff IS DISTINCT FROM s.hd;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    -- Employee PII (retention clock RP-02 starts when employment ends)
    INSERT INTO silver.sat_employee_pii
    SELECT s.hk, v_now, s.hd, s.first_name, s.last_name, s.date_of_birth, s.email, s.phone, s.home_address,
           s.suburb, s.postcode, s.tax_file_number, s.bank_bsb, s.bank_account,
           CASE WHEN s.employment_status = 'Former'
                THEN s.employment_end_date + silver.retention_days('RP-02') END,
           NULL, NULL, 'HRMS', p_run_id
    FROM (SELECT x.*, md5(concat_ws('|', coalesce(first_name, '~'), coalesce(last_name, '~'),
                 coalesce(date_of_birth::TEXT, '~'), coalesce(email, '~'), coalesce(phone, '~'),
                 coalesce(home_address, '~'), coalesce(suburb, '~'), coalesce(postcode, '~'),
                 coalesce(tax_file_number, '~'), coalesce(bank_bsb, '~'), coalesce(bank_account, '~'),
                 coalesce(employment_status, '~'), coalesce(employment_end_date::TEXT, '~'))) AS hd
          FROM stg_hr x) s
    LEFT JOIN LATERAL (SELECT hash_diff FROM silver.sat_employee_pii c WHERE c.employee_hk = s.hk
                       ORDER BY c.load_dts DESC LIMIT 1) cur ON TRUE
    WHERE cur.hash_diff IS DISTINCT FROM s.hd
      AND NOT EXISTS (SELECT 1 FROM audit.erasure_register e
                      WHERE e.system_name = 'HRMS' AND e.business_key = s.bk AND cur.hash_diff IS NOT NULL);
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    INSERT INTO silver.sat_employee_details
    SELECT s.hk, v_now, s.hd, s.department, s.position_title, s.salary_band, s.employment_status,
           s.employment_start_date, s.employment_end_date, 'HRMS', p_run_id
    FROM (SELECT x.*, md5(concat_ws('|', coalesce(department, '~'), coalesce(position_title, '~'),
                 coalesce(salary_band, '~'), coalesce(employment_status, '~'),
                 coalesce(employment_start_date::TEXT, '~'), coalesce(employment_end_date::TEXT, '~'))) AS hd
          FROM stg_hr x) s
    LEFT JOIN LATERAL (SELECT hash_diff FROM silver.sat_employee_details c WHERE c.employee_hk = s.hk
                       ORDER BY c.load_dts DESC LIMIT 1) cur ON TRUE
    WHERE cur.hash_diff IS DISTINCT FROM s.hd;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    -- Constituent PII (retention clock RP-03 applies to non-donors from last contact)
    INSERT INTO silver.sat_constituent_pii
    SELECT s.hk, v_now, s.hd, s.first_name, s.last_name, s.date_of_birth, s.email, s.phone, s.home_address,
           s.suburb, s.postcode, s.employer,
           CASE WHEN s.donor_flag = 'N' THEN s.last_contact_date + silver.retention_days('RP-03') END,
           NULL, NULL, 'ADV_CRM', p_run_id
    FROM (SELECT x.*, md5(concat_ws('|', coalesce(first_name, '~'), coalesce(last_name, '~'),
                 coalesce(date_of_birth::TEXT, '~'), coalesce(email, '~'), coalesce(phone, '~'),
                 coalesce(home_address, '~'), coalesce(suburb, '~'), coalesce(postcode, '~'),
                 coalesce(employer, '~'), coalesce(donor_flag, '~'), coalesce(last_contact_date::TEXT, '~'))) AS hd
          FROM stg_crm x) s
    LEFT JOIN LATERAL (SELECT hash_diff FROM silver.sat_constituent_pii c WHERE c.constituent_hk = s.hk
                       ORDER BY c.load_dts DESC LIMIT 1) cur ON TRUE
    WHERE cur.hash_diff IS DISTINCT FROM s.hd;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    INSERT INTO silver.sat_constituent_details
    SELECT s.hk, v_now, s.hd, s.contact_type, s.alumni_year, s.donor_flag, s.lifetime_donation_aud,
           s.engagement_score, s.last_contact_date, 'ADV_CRM', p_run_id
    FROM (SELECT x.*, md5(concat_ws('|', coalesce(contact_type, '~'), coalesce(alumni_year::TEXT, '~'),
                 coalesce(donor_flag, '~'), coalesce(lifetime_donation_aud::TEXT, '~'),
                 coalesce(engagement_score::TEXT, '~'), coalesce(last_contact_date::TEXT, '~'))) AS hd
          FROM stg_crm x) s
    LEFT JOIN LATERAL (SELECT hash_diff FROM silver.sat_constituent_details c WHERE c.constituent_hk = s.hk
                       ORDER BY c.load_dts DESC LIMIT 1) cur ON TRUE
    WHERE cur.hash_diff IS DISTINCT FROM s.hd;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_loaded := v_loaded + v_n;

    -- ============ Catalogue and lineage
    CALL audit.record_lineage(p_run_id, 'bronze.sis_student_raw', 'silver.hub_student', 'VAULT_LOAD', v_sis);
    CALL audit.record_lineage(p_run_id, 'bronze.sis_student_raw', 'silver.sat_student_pii', 'VAULT_LOAD', v_sis);
    CALL audit.record_lineage(p_run_id, 'bronze.sis_student_raw', 'silver.sat_student_enrolment', 'VAULT_LOAD', v_sis);
    CALL audit.record_lineage(p_run_id, 'bronze.hrms_employee_raw', 'silver.hub_employee', 'VAULT_LOAD', v_hr);
    CALL audit.record_lineage(p_run_id, 'bronze.hrms_employee_raw', 'silver.sat_employee_pii', 'VAULT_LOAD', v_hr);
    CALL audit.record_lineage(p_run_id, 'bronze.hrms_employee_raw', 'silver.sat_employee_details', 'VAULT_LOAD', v_hr);
    CALL audit.record_lineage(p_run_id, 'bronze.crm_constituent_raw', 'silver.hub_constituent', 'VAULT_LOAD', v_crm);
    CALL audit.record_lineage(p_run_id, 'bronze.crm_constituent_raw', 'silver.sat_constituent_pii', 'VAULT_LOAD', v_crm);
    CALL audit.record_lineage(p_run_id, 'bronze.crm_constituent_raw', 'silver.sat_constituent_details', 'VAULT_LOAD', v_crm);

    CALL audit.register_dataset('silver.hub_student', 'silver', 'warehouse', FALSE, FALSE, 'Data Platform Team');
    CALL audit.register_dataset('silver.hub_employee', 'silver', 'warehouse', FALSE, FALSE, 'Data Platform Team');
    CALL audit.register_dataset('silver.hub_constituent', 'silver', 'warehouse', FALSE, FALSE, 'Data Platform Team');
    CALL audit.register_dataset('silver.sat_student_pii', 'silver', 'warehouse', TRUE, FALSE, 'Student Administration');
    CALL audit.register_dataset('silver.sat_student_enrolment', 'silver', 'warehouse', FALSE, FALSE, 'Student Administration');
    CALL audit.register_dataset('silver.sat_employee_pii', 'silver', 'warehouse', TRUE, FALSE, 'People & Culture');
    CALL audit.register_dataset('silver.sat_employee_details', 'silver', 'warehouse', FALSE, FALSE, 'People & Culture');
    CALL audit.register_dataset('silver.sat_constituent_pii', 'silver', 'warehouse', TRUE, FALSE, 'Advancement Office');
    CALL audit.register_dataset('silver.sat_constituent_details', 'silver', 'warehouse', FALSE, FALSE, 'Advancement Office');

    CALL audit.set_step_rows(p_run_id, v_read::INT, v_loaded::INT);
END;
$$;
