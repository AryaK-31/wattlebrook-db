-- =============================================================================
-- 09 Gold: star schema for reporting
-- Design element: dimensional model. Gold holds no direct personal data: the
-- person dimension carries the resolved person_id, system membership flags
-- and an age band, never names, emails, phones or exact dates of birth.
--   Dimensions: dim_person, dim_program, dim_system, dim_date
--   Facts:      fact_enrolment (one row per SIS record)
--               fact_giving (one row per CRM contact)
--               fact_pii_holding (personal-data holdings per dataset,
--                                 before and after retention)
-- =============================================================================

CREATE OR REPLACE PROCEDURE gold.build_star_schema(p_run_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_rows BIGINT := 0;
    v_n1 BIGINT; v_n2 BIGINT; v_n3 BIGINT; v_n4 BIGINT;
    t RECORD;
BEGIN
    DROP TABLE IF EXISTS gold.fact_enrolment, gold.fact_giving, gold.fact_pii_holding,
                         gold.dim_person, gold.dim_program, gold.dim_system, gold.dim_date CASCADE;

    -- ------------------------------------------------------------ dim_date
    CREATE TABLE gold.dim_date AS
    SELECT to_char(d, 'YYYYMMDD')::INT AS date_key, d::DATE AS full_date,
           extract(year FROM d)::INT AS year, extract(quarter FROM d)::INT AS quarter,
           extract(month FROM d)::INT AS month, to_char(d, 'Mon') AS month_name
      FROM generate_series(DATE '1990-01-01', DATE '2030-12-31', INTERVAL '1 day') d;
    ALTER TABLE gold.dim_date ADD PRIMARY KEY (date_key);

    -- ---------------------------------------------------------- dim_system
    CREATE TABLE gold.dim_system (
        system_key   INT PRIMARY KEY,
        system_name  TEXT UNIQUE NOT NULL,
        description  TEXT NOT NULL,
        data_owner   TEXT NOT NULL
    );
    INSERT INTO gold.dim_system VALUES
        (1, 'HRMS', 'Human Resources Management System', 'People & Culture'),
        (2, 'SIS', 'Student Information System', 'Student Administration'),
        (3, 'ADV_CRM', 'Advancement CRM (alumni and donors)', 'Advancement Office'),
        (4, 'DEV_SANDBOX', 'Uncontrolled developer and test copies', 'UNKNOWN');

    -- --------------------------------------------------------- dim_program
    CREATE TABLE gold.dim_program AS
    SELECT row_number() OVER (ORDER BY program_code)::INT AS program_key, program_code, program_name, study_level
      FROM (SELECT DISTINCT program_code, program_name, study_level
              FROM silver.v_student_current WHERE program_code IS NOT NULL) p;
    ALTER TABLE gold.dim_program ADD PRIMARY KEY (program_key);

    -- ---------------------------------------------------------- dim_person
    -- Aggregated per person first, so a person never fans out into several rows.
    CREATE TABLE gold.dim_person AS
    WITH links AS (
        SELECT hp.person_id, l.system_name, l.business_key, l.match_confidence
          FROM silver.link_person_identity l JOIN silver.hub_person hp ON hp.person_hk = l.person_hk
    ), dob AS (
        SELECT l.person_id, min(coalesce(s.date_of_birth, e.date_of_birth, c.date_of_birth)) AS dob
          FROM links l
          LEFT JOIN silver.v_student_current s ON l.system_name = 'SIS' AND s.sis_student_id = l.business_key
          LEFT JOIN silver.v_employee_current e ON l.system_name = 'HRMS' AND e.hr_employee_id = l.business_key
          LEFT JOIN silver.v_constituent_current c ON l.system_name = 'ADV_CRM' AND c.crm_contact_id = l.business_key
         GROUP BY l.person_id
    )
    SELECT row_number() OVER (ORDER BY l.person_id)::INT AS person_key,
           l.person_id,
           bool_or(l.system_name = 'HRMS')    AS in_hrms,
           bool_or(l.system_name = 'SIS')     AS in_sis,
           bool_or(l.system_name = 'ADV_CRM') AS in_crm,
           count(DISTINCT l.system_name)::INT AS system_count,
           CASE WHEN bool_or(l.match_confidence = 'MEDIUM') THEN 'MEDIUM'
                WHEN bool_or(l.match_confidence = 'HIGH')   THEN 'HIGH'
                ELSE 'SINGLE' END             AS match_confidence,
           CASE WHEN max(d.dob) IS NULL THEN 'Unknown (erased)'
                WHEN age(max(d.dob)) < INTERVAL '25 years' THEN 'Under 25'
                WHEN age(max(d.dob)) < INTERVAL '40 years' THEN '25-39'
                WHEN age(max(d.dob)) < INTERVAL '60 years' THEN '40-59'
                ELSE '60+' END                AS age_band
      FROM links l LEFT JOIN dob d ON d.person_id = l.person_id
     GROUP BY l.person_id;
    ALTER TABLE gold.dim_person ADD PRIMARY KEY (person_key);
    CREATE UNIQUE INDEX ON gold.dim_person (person_id);

    -- ------------------------------------------------------ fact_enrolment
    CREATE TABLE gold.fact_enrolment AS
    SELECT row_number() OVER (ORDER BY s.sis_student_id)::INT AS enrolment_key,
           dp.person_key, pg.program_key, ds.system_key,
           s.enrolment_year, s.completion_year, s.enrolment_status,
           to_char(s.last_activity_date, 'YYYYMMDD')::INT AS last_activity_date_key,
           s.gpa, s.outstanding_fees_aud,
           (s.international_flag = 'Y') AS is_international
      FROM silver.v_student_current s
      JOIN silver.link_person_identity l ON l.system_name = 'SIS' AND l.business_key = s.sis_student_id
      JOIN silver.hub_person hp ON hp.person_hk = l.person_hk
      JOIN gold.dim_person dp ON dp.person_id = hp.person_id
      LEFT JOIN gold.dim_program pg ON pg.program_code = s.program_code
      JOIN gold.dim_system ds ON ds.system_name = 'SIS';
    ALTER TABLE gold.fact_enrolment ADD PRIMARY KEY (enrolment_key);
    ALTER TABLE gold.fact_enrolment ADD FOREIGN KEY (person_key) REFERENCES gold.dim_person (person_key);
    ALTER TABLE gold.fact_enrolment ADD FOREIGN KEY (program_key) REFERENCES gold.dim_program (program_key);
    CREATE INDEX ON gold.fact_enrolment (person_key);
    CREATE INDEX ON gold.fact_enrolment (program_key, enrolment_year);

    -- --------------------------------------------------------- fact_giving
    CREATE TABLE gold.fact_giving AS
    SELECT row_number() OVER (ORDER BY c.crm_contact_id)::INT AS giving_key,
           dp.person_key, ds.system_key, c.contact_type, c.alumni_year, (c.donor_flag = 'Y') AS is_donor,
           c.lifetime_donation_aud, c.engagement_score,
           to_char(c.last_contact_date, 'YYYYMMDD')::INT AS last_contact_date_key
      FROM silver.v_constituent_current c
      JOIN silver.link_person_identity l ON l.system_name = 'ADV_CRM' AND l.business_key = c.crm_contact_id
      JOIN silver.hub_person hp ON hp.person_hk = l.person_hk
      JOIN gold.dim_person dp ON dp.person_id = hp.person_id
      JOIN gold.dim_system ds ON ds.system_name = 'ADV_CRM'
     WHERE c.contact_type IS NOT NULL;
    ALTER TABLE gold.fact_giving ADD PRIMARY KEY (giving_key);
    ALTER TABLE gold.fact_giving ADD FOREIGN KEY (person_key) REFERENCES gold.dim_person (person_key);

    -- ---------------------------------------------------- fact_pii_holding
    -- Latest BEFORE and AFTER snapshots of personal-data holdings per dataset.
    CREATE TABLE gold.fact_pii_holding AS
    SELECT s.phase, s.dataset, s.layer,
           coalesce(ds.system_key,
                    CASE WHEN s.layer = 'dev_sandbox' THEN 4 END) AS system_key,
           s.status, s.contains_real_pii, s.masked, s.row_count, s.real_pii_rows,
           to_char(s.taken_at, 'YYYYMMDD')::INT AS snapshot_date_key
      FROM audit.pii_holding_snapshot s
      LEFT JOIN gold.dim_system ds ON ds.system_name = CASE
             WHEN s.dataset ~ '(hrms|employee)' THEN 'HRMS'
             WHEN s.dataset ~ '(sis|student)' THEN 'SIS'
             WHEN s.dataset ~ '(crm|constituent)' THEN 'ADV_CRM' END
     WHERE s.run_id IN (SELECT max(run_id) FROM audit.pii_holding_snapshot GROUP BY phase);

    SELECT count(*) INTO v_n1 FROM gold.dim_person;
    SELECT count(*) INTO v_n2 FROM gold.fact_enrolment;
    SELECT count(*) INTO v_n3 FROM gold.fact_giving;
    SELECT count(*) INTO v_n4 FROM gold.fact_pii_holding;
    v_rows := v_n1 + v_n2 + v_n3 + v_n4;

    CALL audit.record_lineage(p_run_id, 'silver.link_person_identity + silver.v_*_current', 'gold.dim_person', 'AGGREGATE', v_n1);
    CALL audit.record_lineage(p_run_id, 'generate_series(1990..2030)', 'gold.dim_date', 'GENERATE', 0);
    CALL audit.record_lineage(p_run_id, 'reference data (09_gold_star_schema.sql)', 'gold.dim_system', 'GENERATE', 4);
    CALL audit.record_lineage(p_run_id, 'silver.v_student_current', 'gold.dim_program', 'AGGREGATE', 0);
    CALL audit.record_lineage(p_run_id, 'silver.v_student_current', 'gold.fact_enrolment', 'AGGREGATE', v_n2);
    CALL audit.record_lineage(p_run_id, 'silver.v_constituent_current', 'gold.fact_giving', 'AGGREGATE', v_n3);
    CALL audit.record_lineage(p_run_id, 'audit.pii_holding_snapshot', 'gold.fact_pii_holding', 'AGGREGATE', v_n4);
    CALL audit.register_dataset('gold.dim_person', 'gold', 'warehouse', FALSE, FALSE, 'Data Platform Team');
    CALL audit.register_dataset('gold.dim_program', 'gold', 'warehouse', FALSE, FALSE, 'Data Platform Team');
    CALL audit.register_dataset('gold.dim_system', 'gold', 'warehouse', FALSE, FALSE, 'Data Platform Team');
    CALL audit.register_dataset('gold.dim_date', 'gold', 'warehouse', FALSE, FALSE, 'Data Platform Team');
    CALL audit.register_dataset('gold.fact_enrolment', 'gold', 'warehouse', FALSE, FALSE, 'Data Platform Team');
    CALL audit.register_dataset('gold.fact_giving', 'gold', 'warehouse', FALSE, FALSE, 'Data Platform Team');
    CALL audit.register_dataset('gold.fact_pii_holding', 'gold', 'warehouse', FALSE, FALSE, 'Data Platform Team');
    -- Gold is built after the final discovery scan, so refresh its catalogue row counts here.
    FOR t IN SELECT dataset FROM audit.dataset WHERE layer = 'gold' AND to_regclass(dataset) IS NOT NULL LOOP
        EXECUTE format('UPDATE audit.dataset SET row_count = (SELECT count(*) FROM %s), real_pii_rows = 0,
                               last_scanned_at = clock_timestamp() WHERE dataset = %L', t.dataset, t.dataset);
    END LOOP;
    CALL audit.set_step_rows(p_run_id, v_rows::INT, v_rows::INT);
END;
$$;
