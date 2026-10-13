-- 05 Silver: Data Vault 2.0.
-- Hub      = one row per business key (the ID used by the source system).
-- Satellite = the descriptive data for that key. Rows are only added, never
--             overwritten: a new row is inserted when hash_diff shows the data changed.
-- Every satellite row gets a retention_expiry_date (its "use-by date").

-- ---------------------------------------------------------- cleaning helpers

-- '  PRIYA ' -> 'Priya'. Mixed-case names such as O'Brien are left as they are.
CREATE OR REPLACE FUNCTION silver.clean_name(p TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN btrim(p) IN (upper(btrim(p)), lower(btrim(p))) THEN initcap(btrim(p))
                ELSE btrim(p) END;
$$;

CREATE OR REPLACE FUNCTION silver.clean_email(p TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(lower(btrim(p)), '');
$$;

-- '+61 412 345 678' and '0412 345 678' -> '0412345678'
CREATE OR REPLACE FUNCTION silver.clean_phone(p TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN d LIKE '61%' AND length(d) = 11 THEN '0' || substr(d, 3) ELSE nullif(d, '') END
      FROM (SELECT regexp_replace(p, '[^0-9]', '', 'g') AS d) x;
$$;

-- --------------------------------------------------------------------- hubs

CREATE TABLE IF NOT EXISTS silver.hub_employee (
    employee_hk     CHAR(32) PRIMARY KEY,      -- md5 of the business key
    hr_employee_id  TEXT NOT NULL UNIQUE,
    load_dts        TIMESTAMPTZ NOT NULL,
    record_source   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS silver.hub_student (
    student_hk      CHAR(32) PRIMARY KEY,
    sis_student_id  TEXT NOT NULL UNIQUE,
    load_dts        TIMESTAMPTZ NOT NULL,
    record_source   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS silver.hub_constituent (
    constituent_hk  CHAR(32) PRIMARY KEY,
    crm_contact_id  TEXT NOT NULL UNIQUE,
    load_dts        TIMESTAMPTZ NOT NULL,
    record_source   TEXT NOT NULL
);

-- --------------------------------------------------------------- satellites

CREATE TABLE IF NOT EXISTS silver.sat_employee (
    employee_hk            CHAR(32) NOT NULL REFERENCES silver.hub_employee,
    load_dts               TIMESTAMPTZ NOT NULL,
    hash_diff              CHAR(32) NOT NULL,
    first_name             TEXT,
    last_name              TEXT,
    date_of_birth          DATE,
    email                  TEXT,
    phone                  TEXT,
    home_address           TEXT,
    suburb                 TEXT,
    postcode               TEXT,
    tax_file_number        TEXT,
    bank_bsb               TEXT,
    bank_account           TEXT,
    department             TEXT,
    position_title         TEXT,
    salary_band            TEXT,
    employment_status      TEXT,
    employment_start_date  DATE,
    employment_end_date    DATE,
    retention_expiry_date  DATE,               -- RP-02: end date + 7 years, former staff only
    anonymised_at          TIMESTAMPTZ,
    record_source          TEXT NOT NULL,
    PRIMARY KEY (employee_hk, load_dts)
);

CREATE TABLE IF NOT EXISTS silver.sat_student (
    student_hk             CHAR(32) NOT NULL REFERENCES silver.hub_student,
    load_dts               TIMESTAMPTZ NOT NULL,
    hash_diff              CHAR(32) NOT NULL,
    first_name             TEXT,
    last_name              TEXT,
    date_of_birth          DATE,
    email                  TEXT,
    phone                  TEXT,
    home_address           TEXT,
    suburb                 TEXT,
    postcode               TEXT,
    program_code           TEXT,
    program_name           TEXT,
    study_level            TEXT,
    enrolment_status       TEXT,
    enrolment_year         INT,
    completion_year        INT,
    international_flag     TEXT,
    visa_status            TEXT,
    gpa                    NUMERIC(4, 2),
    outstanding_fees_aud   NUMERIC(12, 2),
    last_activity_date     DATE,
    retention_expiry_date  DATE,               -- RP-01: last activity + 7 years, completed/withdrawn only
    anonymised_at          TIMESTAMPTZ,
    record_source          TEXT NOT NULL,
    PRIMARY KEY (student_hk, load_dts)
);

CREATE TABLE IF NOT EXISTS silver.sat_constituent (
    constituent_hk         CHAR(32) NOT NULL REFERENCES silver.hub_constituent,
    load_dts               TIMESTAMPTZ NOT NULL,
    hash_diff              CHAR(32) NOT NULL,
    first_name             TEXT,
    last_name              TEXT,
    date_of_birth          DATE,
    email                  TEXT,
    phone                  TEXT,
    home_address           TEXT,
    suburb                 TEXT,
    postcode               TEXT,
    contact_type           TEXT,
    alumni_year            INT,
    employer               TEXT,
    donor_flag             TEXT,
    lifetime_donation_aud  NUMERIC(12, 2),
    engagement_score       INT,
    last_contact_date      DATE,
    retention_expiry_date  DATE,               -- RP-03: last contact + 7 years, non-donors only
    anonymised_at          TIMESTAMPTZ,
    record_source          TEXT NOT NULL,
    PRIMARY KEY (constituent_hk, load_dts)
);

CREATE INDEX IF NOT EXISTS sat_employee_email_idx    ON silver.sat_employee (email);
CREATE INDEX IF NOT EXISTS sat_student_email_idx     ON silver.sat_student (email);
CREATE INDEX IF NOT EXISTS sat_constituent_email_idx ON silver.sat_constituent (email);

-- ---------------------------------------------- latest satellite row per key

CREATE OR REPLACE VIEW silver.employee_current AS
SELECT DISTINCT ON (h.employee_hk) h.hr_employee_id, s.*
  FROM silver.hub_employee h JOIN silver.sat_employee s USING (employee_hk)
 ORDER BY h.employee_hk, s.load_dts DESC;

CREATE OR REPLACE VIEW silver.student_current AS
SELECT DISTINCT ON (h.student_hk) h.sis_student_id, s.*
  FROM silver.hub_student h JOIN silver.sat_student s USING (student_hk)
 ORDER BY h.student_hk, s.load_dts DESC;

CREATE OR REPLACE VIEW silver.constituent_current AS
SELECT DISTINCT ON (h.constituent_hk) h.crm_contact_id, s.*
  FROM silver.hub_constituent h JOIN silver.sat_constituent s USING (constituent_hk)
 ORDER BY h.constituent_hk, s.load_dts DESC;

-- -------------------------------------------------------------- load step

CREATE OR REPLACE PROCEDURE silver.load_vault(p_run_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_rows  INT;
    v_total INT := 0;
BEGIN
    -- Employees ------------------------------------------------------------
    INSERT INTO silver.hub_employee
    SELECT md5(hr_employee_id), hr_employee_id, now(), 'HRMS'
      FROM bronze.hrms_employee
    ON CONFLICT DO NOTHING;

    INSERT INTO silver.sat_employee
    SELECT n.*
      FROM (SELECT md5(b.hr_employee_id) AS employee_hk, now() AS load_dts,
                   md5(ROW(b.first_name, b.last_name, b.date_of_birth, b.email, b.phone, b.home_address,
                           b.suburb, b.postcode, b.tax_file_number, b.bank_bsb, b.bank_account, b.department,
                           b.position_title, b.salary_band, b.employment_status, b.employment_start_date,
                           b.employment_end_date)::TEXT) AS hash_diff,
                   silver.clean_name(b.first_name), silver.clean_name(b.last_name), b.date_of_birth,
                   silver.clean_email(b.email), silver.clean_phone(b.phone), btrim(b.home_address),
                   b.suburb, b.postcode, b.tax_file_number, b.bank_bsb, b.bank_account, b.department,
                   b.position_title, b.salary_band, b.employment_status, b.employment_start_date,
                   b.employment_end_date,
                   CASE WHEN b.employment_status = 'Former' THEN b.employment_end_date + 2555 END,
                   NULL::TIMESTAMPTZ, 'HRMS'
              FROM bronze.hrms_employee b) n
      LEFT JOIN silver.employee_current c ON c.employee_hk = n.employee_hk
     WHERE c.hash_diff IS DISTINCT FROM n.hash_diff;    -- new key, or the data changed
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_total := v_total + v_rows;
    INSERT INTO audit.lineage (run_id, source, target, operation, row_count) VALUES
    (p_run_id, 'bronze.hrms_employee', 'silver.hub_employee', 'VAULT_LOAD', (SELECT count(*) FROM silver.hub_employee)),
    (p_run_id, 'bronze.hrms_employee', 'silver.sat_employee', 'VAULT_LOAD', v_rows);

    -- Students -------------------------------------------------------------
    INSERT INTO silver.hub_student
    SELECT md5(sis_student_id), sis_student_id, now(), 'SIS'
      FROM bronze.sis_student
    ON CONFLICT DO NOTHING;

    INSERT INTO silver.sat_student
    SELECT n.*
      FROM (SELECT md5(b.sis_student_id) AS student_hk, now() AS load_dts,
                   md5(ROW(b.first_name, b.last_name, b.date_of_birth, b.email, b.phone, b.home_address,
                           b.suburb, b.postcode, b.program_code, b.enrolment_status, b.enrolment_year,
                           b.completion_year, b.international_flag, b.visa_status, b.gpa,
                           b.outstanding_fees_aud, b.last_activity_date)::TEXT) AS hash_diff,
                   silver.clean_name(b.first_name), silver.clean_name(b.last_name), b.date_of_birth,
                   silver.clean_email(b.email), silver.clean_phone(b.phone), btrim(b.home_address),
                   b.suburb, b.postcode, b.program_code, b.program_name, b.study_level, b.enrolment_status,
                   b.enrolment_year, b.completion_year, b.international_flag, b.visa_status, b.gpa,
                   b.outstanding_fees_aud, b.last_activity_date,
                   CASE WHEN b.enrolment_status IN ('Completed', 'Withdrawn') THEN b.last_activity_date + 2555 END,
                   NULL::TIMESTAMPTZ, 'SIS'
              FROM bronze.sis_student b) n
      LEFT JOIN silver.student_current c ON c.student_hk = n.student_hk
     WHERE c.hash_diff IS DISTINCT FROM n.hash_diff;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_total := v_total + v_rows;
    INSERT INTO audit.lineage (run_id, source, target, operation, row_count) VALUES
    (p_run_id, 'bronze.sis_student', 'silver.hub_student', 'VAULT_LOAD', (SELECT count(*) FROM silver.hub_student)),
    (p_run_id, 'bronze.sis_student', 'silver.sat_student', 'VAULT_LOAD', v_rows);

    -- CRM contacts ---------------------------------------------------------
    INSERT INTO silver.hub_constituent
    SELECT md5(crm_contact_id), crm_contact_id, now(), 'ADV_CRM'
      FROM bronze.crm_constituent
    ON CONFLICT DO NOTHING;

    INSERT INTO silver.sat_constituent
    SELECT n.*
      FROM (SELECT md5(b.crm_contact_id) AS constituent_hk, now() AS load_dts,
                   md5(ROW(b.first_name, b.last_name, b.date_of_birth, b.email, b.phone, b.home_address,
                           b.suburb, b.postcode, b.contact_type, b.alumni_year, b.employer, b.donor_flag,
                           b.lifetime_donation_aud, b.engagement_score, b.last_contact_date)::TEXT) AS hash_diff,
                   silver.clean_name(b.first_name), silver.clean_name(b.last_name), b.date_of_birth,
                   silver.clean_email(b.email), silver.clean_phone(b.phone), btrim(b.home_address),
                   b.suburb, b.postcode, b.contact_type, b.alumni_year, b.employer, b.donor_flag,
                   b.lifetime_donation_aud, b.engagement_score, b.last_contact_date,
                   CASE WHEN b.donor_flag = 'N' THEN b.last_contact_date + 2555 END,
                   NULL::TIMESTAMPTZ, 'ADV_CRM'
              FROM bronze.crm_constituent b) n
      LEFT JOIN silver.constituent_current c ON c.constituent_hk = n.constituent_hk
     WHERE c.hash_diff IS DISTINCT FROM n.hash_diff;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_total := v_total + v_rows;
    INSERT INTO audit.lineage (run_id, source, target, operation, row_count) VALUES
    (p_run_id, 'bronze.crm_constituent', 'silver.hub_constituent', 'VAULT_LOAD', (SELECT count(*) FROM silver.hub_constituent)),
    (p_run_id, 'bronze.crm_constituent', 'silver.sat_constituent', 'VAULT_LOAD', v_rows);

    UPDATE audit.pipeline_run SET rows_loaded = v_total WHERE run_id = p_run_id;
END;
$$;
