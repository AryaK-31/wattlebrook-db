-- Hubs
CREATE TABLE IF NOT EXISTS silver.hub_student (
    student_hash_key CHAR(32) PRIMARY KEY,
    sis_student_id TEXT UNIQUE NOT NULL,
    load_dts TIMESTAMPTZ NOT NULL,
    record_source TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS silver.hub_employee (
    employee_hash_key CHAR(32) PRIMARY KEY,
    hr_employee_id TEXT UNIQUE NOT NULL,
    load_dts TIMESTAMPTZ NOT NULL,
    record_source TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS silver.hub_constituent (
    constituent_hash_key CHAR(32) PRIMARY KEY,
    crm_contact_id TEXT UNIQUE NOT NULL,
    load_dts TIMESTAMPTZ NOT NULL,
    record_source TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS silver.hub_person (
    person_id TEXT PRIMARY KEY,
    created_at TIMESTAMPTZ DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS silver.link_person_identity (
    link_id SERIAL PRIMARY KEY,
    person_id TEXT REFERENCES silver.hub_person(person_id),
    system_name TEXT NOT NULL,
    source_record_id TEXT NOT NULL,
    match_rule TEXT NOT NULL,
    match_confidence TEXT CHECK (match_confidence IN ('HIGH', 'MEDIUM', 'SINGLE')),
    load_dts TIMESTAMPTZ DEFAULT clock_timestamp()
);

-- Satellites
CREATE TABLE IF NOT EXISTS silver.sat_student_details (
    student_hash_key CHAR(32) REFERENCES silver.hub_student(student_hash_key),
    load_dts TIMESTAMPTZ NOT NULL,
    first_name TEXT,
    last_name TEXT,
    date_of_birth DATE,
    email TEXT,
    phone TEXT,
    program TEXT,
    hash_diff CHAR(32) NOT NULL,
    PRIMARY KEY (student_hash_key, load_dts)
);

-- Identity Resolution Engine
CREATE OR REPLACE PROCEDURE silver.resolve_identities()
LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE TABLE silver.link_person_identity CASCADE;
    TRUNCATE TABLE silver.hub_person CASCADE;

    CREATE TEMP TABLE tmp_candidates ON COMMIT DROP AS
    SELECT 'HRMS' AS sys, hr_employee_id AS src_id, lower(trim(email)) AS email, 
           lower(trim(first_name || ' ' || last_name)) AS full_name, date_of_birth AS dob
    FROM bronze.hrms_employee_raw
    UNION ALL
    SELECT 'SIS' AS sys, sis_student_id AS src_id, lower(trim(email)) AS email, 
           lower(trim(first_name || ' ' || last_name)) AS full_name, date_of_birth AS dob
    FROM bronze.sis_student_raw
    UNION ALL
    SELECT 'CRM' AS sys, crm_contact_id AS src_id, lower(trim(email)) AS email, 
           lower(trim(first_name || ' ' || last_name)) AS full_name, date_of_birth AS dob
    FROM bronze.crm_constituent_raw;

    WITH email_clusters AS (
        SELECT email, 'P-' || lpad(dense_rank() OVER (ORDER BY email)::text, 6, '0') AS gen_person_id
        FROM tmp_candidates WHERE email IS NOT NULL AND email <> ''
        GROUP BY email
    )
    INSERT INTO silver.hub_person (person_id)
    SELECT DISTINCT gen_person_id FROM email_clusters;

    INSERT INTO silver.link_person_identity (person_id, system_name, source_record_id, match_rule, match_confidence)
    SELECT c.gen_person_id, t.sys, t.src_id, 'R1_EXACT_EMAIL', 'HIGH'
    FROM tmp_candidates t
    JOIN (
        SELECT email, 'P-' || lpad(dense_rank() OVER (ORDER BY email)::text, 6, '0') AS gen_person_id
        FROM tmp_candidates WHERE email IS NOT NULL AND email <> ''
        GROUP BY email
    ) c ON t.email = c.email;
END;
$$;