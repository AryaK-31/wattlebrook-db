-- 02 Source tables. These stand in for the three operational systems and the
-- shadow copies. load_source_data.py fills them from the Excel workbook.

CREATE TABLE IF NOT EXISTS src_hrms.employee (
    hr_employee_id         TEXT PRIMARY KEY,
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
    employment_status      TEXT,    -- Current / Former
    employment_start_date  DATE,
    employment_end_date    DATE
);

CREATE TABLE IF NOT EXISTS src_sis.student (
    sis_student_id         TEXT PRIMARY KEY,
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
    enrolment_status       TEXT,    -- Enrolled / Deferred / Completed / Withdrawn
    enrolment_year         INT,
    completion_year        INT,
    international_flag     TEXT,
    visa_status            TEXT,
    gpa                    NUMERIC(4, 2),
    outstanding_fees_aud   NUMERIC(12, 2),
    last_activity_date     DATE
);

CREATE TABLE IF NOT EXISTS src_crm.constituent (
    crm_contact_id         TEXT PRIMARY KEY,
    first_name             TEXT,
    last_name              TEXT,
    date_of_birth          DATE,
    email                  TEXT,
    phone                  TEXT,
    home_address           TEXT,
    suburb                 TEXT,
    postcode               TEXT,
    contact_type           TEXT,    -- Alumni / Donor / Alumni & Donor
    alumni_year            INT,
    employer               TEXT,
    donor_flag             TEXT,
    lifetime_donation_aud  NUMERIC(12, 2),
    engagement_score       INT,
    last_contact_date      DATE
);

-- The copies developers made between 2012 and 2026. Nobody registered this table.
CREATE TABLE IF NOT EXISTS dev_sandbox.shadow_extracts (
    shadow_record_id         TEXT PRIMARY KEY,
    environment              TEXT,    -- where the copy was found
    source_system            TEXT,
    source_record_id         TEXT,
    extracted_date           DATE,
    purpose                  TEXT,
    approved_retention_days  INT,
    retention_expiry_date    DATE,
    pii_classification       TEXT,
    masked                   TEXT,
    catalogued               TEXT,
    lineage_tracked          TEXT,
    access_group             TEXT,
    last_accessed_date       DATE,
    first_name               TEXT,
    last_name                TEXT,
    email                    TEXT,
    date_of_birth            DATE,
    phone                    TEXT,
    home_address             TEXT,
    sensitive_value          TEXT
);

-- Which real person each source record belongs to. Only used to score identity matching.
CREATE TABLE IF NOT EXISTS qa.identity_answer_key (
    source_system      TEXT,
    source_record_id   TEXT,
    true_person_id     TEXT,
    false_friend_of    TEXT,
    PRIMARY KEY (source_system, source_record_id)
);
