-- 10 Gold: a small star schema for reporting. No names, emails, phones or dates of birth.

CREATE TABLE IF NOT EXISTS gold.dim_person (
    person_key     SERIAL PRIMARY KEY,
    person_id      TEXT UNIQUE NOT NULL,
    in_hrms        BOOLEAN NOT NULL,
    in_sis         BOOLEAN NOT NULL,
    in_crm         BOOLEAN NOT NULL,
    system_count   INT NOT NULL,
    confidence     TEXT NOT NULL            -- weakest match used to build this person
);

CREATE TABLE IF NOT EXISTS gold.dim_program (
    program_key    SERIAL PRIMARY KEY,
    program_code   TEXT UNIQUE NOT NULL,
    program_name   TEXT,
    study_level    TEXT
);

CREATE TABLE IF NOT EXISTS gold.fact_enrolment (
    person_key        INT REFERENCES gold.dim_person,
    program_key       INT REFERENCES gold.dim_program,
    enrolment_year    INT,
    completion_year   INT,
    enrolment_status  TEXT,
    is_international  BOOLEAN,
    gpa               NUMERIC(4, 2),
    fees_owing_aud    NUMERIC(12, 2)
);

CREATE TABLE IF NOT EXISTS gold.fact_giving (
    person_key            INT REFERENCES gold.dim_person,
    contact_type          TEXT,
    alumni_year           INT,
    is_donor              BOOLEAN,
    lifetime_donation_aud NUMERIC(12, 2),
    engagement_score      INT
);

CREATE OR REPLACE PROCEDURE gold.build(p_run_id INT)
LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE gold.fact_enrolment, gold.fact_giving, gold.dim_person, gold.dim_program RESTART IDENTITY;

    INSERT INTO gold.dim_person (person_id, in_hrms, in_sis, in_crm, system_count, confidence)
    SELECT person_id,
           bool_or(system_name = 'HRMS'), bool_or(system_name = 'SIS'), bool_or(system_name = 'ADV_CRM'),
           count(DISTINCT system_name),
           CASE WHEN bool_or(confidence = 'MEDIUM') THEN 'MEDIUM'
                WHEN bool_or(confidence = 'HIGH')   THEN 'HIGH'
                ELSE 'SINGLE' END
      FROM silver.link_person
     GROUP BY person_id;

    INSERT INTO gold.dim_program (program_code, program_name, study_level)
    SELECT DISTINCT program_code, program_name, study_level FROM silver.student_current;

    INSERT INTO gold.fact_enrolment
    SELECT p.person_key, g.program_key, s.enrolment_year, s.completion_year, s.enrolment_status,
           s.international_flag = 'Y', s.gpa, s.outstanding_fees_aud
      FROM silver.student_current s
      JOIN silver.link_person l ON l.system_name = 'SIS' AND l.source_record_id = s.sis_student_id
      JOIN gold.dim_person p ON p.person_id = l.person_id
      JOIN gold.dim_program g ON g.program_code = s.program_code;

    INSERT INTO gold.fact_giving
    SELECT p.person_key, c.contact_type, c.alumni_year, c.donor_flag = 'Y', c.lifetime_donation_aud,
           c.engagement_score
      FROM silver.constituent_current c
      JOIN silver.link_person l ON l.system_name = 'ADV_CRM' AND l.source_record_id = c.crm_contact_id
      JOIN gold.dim_person p ON p.person_id = l.person_id;

    INSERT INTO audit.lineage (run_id, source, target, operation, row_count) VALUES
    (p_run_id, 'silver.link_person',  'gold.dim_person',     'BUILD', (SELECT count(*) FROM gold.dim_person)),
    (p_run_id, 'silver.sat_student',  'gold.dim_program',    'BUILD', (SELECT count(*) FROM gold.dim_program)),
    (p_run_id, 'silver.sat_student',  'gold.fact_enrolment', 'BUILD', (SELECT count(*) FROM gold.fact_enrolment)),
    (p_run_id, 'silver.sat_constituent', 'gold.fact_giving', 'BUILD', (SELECT count(*) FROM gold.fact_giving));
END;
$$;
