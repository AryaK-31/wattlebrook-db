CREATE TABLE IF NOT EXISTS audit.masking_key (
    key_id SERIAL PRIMARY KEY,
    salt TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT clock_timestamp()
);

INSERT INTO audit.masking_key (salt) 
SELECT 'WBU_SECURE_HMAC_SALT_2026_x89f!'
WHERE NOT EXISTS (SELECT 1 FROM audit.masking_key);

CREATE OR REPLACE FUNCTION test_masked.pseudo(p_id TEXT, p_prefix TEXT) 
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT p_prefix || '-' || upper(left(md5((SELECT salt FROM audit.masking_key LIMIT 1) || p_id), 8));
$$;

CREATE OR REPLACE FUNCTION test_masked.shift_date(p_dob DATE, p_id TEXT) 
RETURNS DATE LANGUAGE sql STABLE AS $$
    SELECT p_dob + (1 + (abs(hashtext(p_id)) % 90)) * INTERVAL '1 day';
$$;

CREATE OR REPLACE PROCEDURE test_masked.provision_masked_data()
LANGUAGE plpgsql AS $$
BEGIN
    DROP TABLE IF EXISTS test_masked.student CASCADE;
    
    CREATE TABLE test_masked.student AS
    SELECT 
        test_masked.pseudo(sis_student_id, 'STU') AS sis_student_id,
        'Sample_' || left(md5(sis_student_id), 4) AS first_name,
        'Testerson' AS last_name,
        test_masked.shift_date(date_of_birth::DATE, sis_student_id) AS date_of_birth,
        lower(test_masked.pseudo(sis_student_id, 'stu')) || '@example.invalid' AS email,
        '04' || lpad((abs(hashtext(sis_student_id)) % 100000000)::text, 8, '0') AS phone,
        program, enrolment_status, study_level, international_flag, enrolment_year
    FROM bronze.sis_student_raw;
END;
$$;