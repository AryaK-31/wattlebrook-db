-- 06 Identity resolution: work out which HRMS, SIS and CRM records are the same person.
-- No record is deleted. hub_person holds one row per person and link_person says
-- which source records belong to them and which rule matched them.
--
-- Rules (on cleaned values from the latest bronze load):
--   R1  same email address                                        HIGH
--   R2  same surname + date of birth + phone number               HIGH
--   R3  same first name + surname + date of birth,
--       only between records from different systems               MEDIUM
-- Matches chain together: if A matches B and B matches C, all three are one person.

CREATE TABLE IF NOT EXISTS silver.hub_person (
    person_id   TEXT PRIMARY KEY,
    load_dts    TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS silver.link_person (
    person_id         TEXT NOT NULL REFERENCES silver.hub_person,
    system_name       TEXT NOT NULL,       -- HRMS, SIS or ADV_CRM
    source_record_id  TEXT NOT NULL,
    match_rule        TEXT NOT NULL,       -- e.g. 'R1+R2', or 'NONE' for a person found in one system only
    confidence        TEXT NOT NULL CHECK (confidence IN ('HIGH', 'MEDIUM', 'SINGLE')),
    load_dts          TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (system_name, source_record_id)
);
CREATE INDEX IF NOT EXISTS link_person_person_idx ON silver.link_person (person_id);

CREATE OR REPLACE PROCEDURE silver.resolve_identities(p_run_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_changed INT;
BEGIN
    -- 1. One row per source record, with the values used for matching.
    DROP TABLE IF EXISTS rec, pair;
    CREATE TEMP TABLE rec AS
    SELECT 'HRMS:' || hr_employee_id AS k, 'HRMS' AS sys, hr_employee_id AS id, silver.clean_email(email) AS email,
           silver.clean_phone(phone) AS phone, lower(btrim(first_name)) AS first_name,
           lower(btrim(last_name)) AS last_name, date_of_birth AS dob
      FROM bronze.hrms_employee
    UNION ALL
    SELECT 'SIS:' || sis_student_id, 'SIS', sis_student_id, silver.clean_email(email), silver.clean_phone(phone),
           lower(btrim(first_name)), lower(btrim(last_name)), date_of_birth
      FROM bronze.sis_student
    UNION ALL
    SELECT 'ADV_CRM:' || crm_contact_id, 'ADV_CRM', crm_contact_id, silver.clean_email(email), silver.clean_phone(phone),
           lower(btrim(first_name)), lower(btrim(last_name)), date_of_birth
      FROM bronze.crm_constituent;

    -- Every record starts in its own group, named after itself.
    ALTER TABLE rec ADD COLUMN grp TEXT;
    UPDATE rec SET grp = k;
    CREATE INDEX ON rec (k);
    ANALYZE rec;

    -- 2. Pairs of records that match a rule.
    CREATE TEMP TABLE pair AS
    SELECT a.k AS a, b.k AS b, 'R1' AS rule
      FROM rec a JOIN rec b ON a.email = b.email AND a.k < b.k
    UNION ALL
    SELECT a.k, b.k, 'R2'
      FROM rec a JOIN rec b ON a.last_name = b.last_name AND a.dob = b.dob AND a.phone = b.phone
                           AND a.k < b.k
    UNION ALL
    SELECT a.k, b.k, 'R3'
      FROM rec a JOIN rec b ON a.first_name = b.first_name AND a.last_name = b.last_name
                           AND a.dob = b.dob AND a.sys < b.sys;

    -- 3. Merge groups: keep giving each record the smallest group name among the
    --    records it matches, until nothing changes.
    LOOP
        UPDATE rec r SET grp = m.grp
          FROM (SELECT p.a AS k, min(other.grp) AS grp
                  FROM (SELECT a, b FROM pair UNION ALL SELECT b, a FROM pair) p
                  JOIN rec other ON other.k = p.b
                 GROUP BY p.a) m
         WHERE r.k = m.k AND m.grp < r.grp;
        GET DIAGNOSTICS v_changed = ROW_COUNT;
        EXIT WHEN v_changed = 0;
    END LOOP;

    -- 4. Save. person_id comes from the group name, so it stays the same between runs.
    TRUNCATE silver.link_person;
    DELETE FROM silver.hub_person;

    INSERT INTO silver.hub_person
    SELECT DISTINCT 'P-' || upper(left(md5(grp), 10)), now() FROM rec;

    INSERT INTO silver.link_person
    SELECT 'P-' || upper(left(md5(r.grp), 10)), r.sys, r.id,
           coalesce(m.rules, 'NONE'),
           CASE WHEN m.rules IS NULL THEN 'SINGLE'
                WHEN m.rules LIKE '%R1%' OR m.rules LIKE '%R2%' THEN 'HIGH'
                ELSE 'MEDIUM' END,
           now()
      FROM rec r
      LEFT JOIN (SELECT k, string_agg(DISTINCT rule, '+' ORDER BY rule) AS rules
                   FROM (SELECT a AS k, rule FROM pair UNION ALL SELECT b, rule FROM pair) x
                  GROUP BY k) m ON m.k = r.k;

    UPDATE audit.pipeline_run SET rows_read = (SELECT count(*) FROM rec),
                                  rows_loaded = (SELECT count(*) FROM silver.hub_person)
     WHERE run_id = p_run_id;
    INSERT INTO audit.lineage (run_id, source, target, operation, row_count) VALUES
    (p_run_id, 'bronze (all three systems)', 'silver.hub_person',  'MATCH', (SELECT count(*) FROM silver.hub_person)),
    (p_run_id, 'bronze (all three systems)', 'silver.link_person', 'MATCH', (SELECT count(*) FROM silver.link_person));
END;
$$;
