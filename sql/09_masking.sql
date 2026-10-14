-- 09 Masked test data for developers, for all three systems.
--  - IDs are replaced with a keyed hash (HMAC). The same ID always gets the same
--    pseudonym, so the masked tables still join, but nobody can work backwards
--    without the key. The key is created randomly inside the database, never in git.
--  - Names come from a list of made-up names that do not appear in the real data.
--  - Dates of birth move 15 to 350 days earlier or later.
--  - Emails and phone numbers are replaced. Tax file numbers, bank details and
--    street addresses are left out.
--  - People whose details were anonymised by retention are not included.

CREATE TABLE IF NOT EXISTS audit.masking_key (
    id   INT PRIMARY KEY DEFAULT 1,
    key  BYTEA NOT NULL
);
INSERT INTO audit.masking_key (key) SELECT gen_random_bytes(32)
 WHERE NOT EXISTS (SELECT 1 FROM audit.masking_key);

-- 'STU0000001' -> 'STU-4F0A9C21B7E3'
CREATE OR REPLACE FUNCTION test_masked.pseudo(p_value TEXT, p_prefix TEXT) RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT p_prefix || '-' || upper(left(encode(hmac(convert_to(p_value, 'UTF8'), (SELECT key FROM audit.masking_key), 'sha256'), 'hex'), 12));
$$;

-- A number from 1 to p_max that is always the same for the same input.
CREATE OR REPLACE FUNCTION test_masked.pick(p_value TEXT, p_max INT) RETURNS INT
LANGUAGE sql STABLE AS $$
    SELECT 1 + abs(hashtext(test_masked.pseudo(p_value, ''))) % p_max;
$$;

CREATE OR REPLACE FUNCTION test_masked.fake_first_name(p_id TEXT) RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT (ARRAY['Ari', 'Bo', 'Cass', 'Dana', 'Eli', 'Frankie', 'Gale', 'Hollis', 'Indy', 'Jules',
                  'Kit', 'Lane', 'Morgan', 'Noor', 'Oakley', 'Parker', 'Quinn', 'Reese', 'Sage', 'Tatum',
                  'Uma', 'Vale', 'Wren', 'Yael', 'Zion', 'Rowan', 'Sky', 'Jordan', 'Emery', 'Remy'])
           [test_masked.pick(p_id || ':first', 30)];
$$;

CREATE OR REPLACE FUNCTION test_masked.fake_last_name(p_id TEXT) RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT (ARRAY['Ashdown', 'Birchwood', 'Coldwater', 'Dunmore', 'Eastwick', 'Fernhill', 'Glenrock',
                  'Hollowell', 'Ironbark', 'Juniper', 'Kestrel', 'Larkspur', 'Millbrook', 'Northcote',
                  'Oakridge', 'Pinecrest', 'Quarrington', 'Riverside', 'Stonebridge', 'Thornbury',
                  'Underwood', 'Westbrook', 'Yarrow', 'Zephyr', 'Ambleside', 'Bellmount', 'Copperfield',
                  'Driftwood', 'Elmstead', 'Foxglove'])
           [test_masked.pick(p_id || ':last', 30)];
$$;

CREATE OR REPLACE FUNCTION test_masked.shift_date(p_date DATE, p_id TEXT) RETURNS DATE
LANGUAGE sql STABLE AS $$
    SELECT p_date + CASE WHEN test_masked.pick(p_id || ':sign', 2) = 1 THEN -1 ELSE 1 END
                    * (14 + test_masked.pick(p_id || ':days', 336));
$$;

-- 0491 57x xxx is a range the source systems never use, so a masked number is never real.
CREATE OR REPLACE FUNCTION test_masked.fake_phone(p_id TEXT) RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT '049157' || lpad(test_masked.pick(p_id || ':phone', 9999)::TEXT, 4, '0');
$$;

CREATE TABLE IF NOT EXISTS test_masked.employee (
    hr_employee_id         TEXT PRIMARY KEY,
    person_ref             TEXT,       -- masked person_id: links the same person across masked tables
    first_name             TEXT,
    last_name              TEXT,
    date_of_birth          DATE,
    email                  TEXT,
    phone                  TEXT,
    postcode               TEXT,
    department             TEXT,
    position_title         TEXT,
    salary_band            TEXT,
    employment_status      TEXT,
    employment_start_date  DATE,
    employment_end_date    DATE
);

CREATE TABLE IF NOT EXISTS test_masked.student (
    sis_student_id         TEXT PRIMARY KEY,
    person_ref             TEXT,
    first_name             TEXT,
    last_name              TEXT,
    date_of_birth          DATE,
    email                  TEXT,
    phone                  TEXT,
    postcode               TEXT,
    program_code           TEXT,
    study_level            TEXT,
    enrolment_status       TEXT,
    enrolment_year         INT,
    completion_year        INT,
    international_flag     TEXT,
    gpa                    NUMERIC(4, 2)
);

CREATE TABLE IF NOT EXISTS test_masked.constituent (
    crm_contact_id         TEXT PRIMARY KEY,
    person_ref             TEXT,
    first_name             TEXT,
    last_name              TEXT,
    date_of_birth          DATE,
    email                  TEXT,
    phone                  TEXT,
    postcode               TEXT,
    contact_type           TEXT,
    alumni_year            INT,
    donor_flag             TEXT,
    donation_band_aud      NUMERIC(12, 0),  -- rounded to the nearest $1,000
    engagement_score       INT
);

CREATE OR REPLACE PROCEDURE test_masked.provision(p_run_id INT)
LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE test_masked.employee, test_masked.student, test_masked.constituent;

    INSERT INTO test_masked.employee
    SELECT test_masked.pseudo(e.hr_employee_id, 'EMP'), test_masked.pseudo(l.person_id, 'PER'),
           test_masked.fake_first_name(e.hr_employee_id), test_masked.fake_last_name(e.hr_employee_id),
           test_masked.shift_date(e.date_of_birth, e.hr_employee_id),
           lower(test_masked.pseudo(e.hr_employee_id, 'emp')) || '@example.invalid',
           test_masked.fake_phone(e.hr_employee_id),
           e.postcode, e.department, e.position_title, e.salary_band, e.employment_status,
           e.employment_start_date, e.employment_end_date
      FROM silver.employee_current e
      JOIN silver.link_person l ON l.system_name = 'HRMS' AND l.source_record_id = e.hr_employee_id
     WHERE e.anonymised_at IS NULL;

    INSERT INTO test_masked.student
    SELECT test_masked.pseudo(s.sis_student_id, 'STU'), test_masked.pseudo(l.person_id, 'PER'),
           test_masked.fake_first_name(s.sis_student_id), test_masked.fake_last_name(s.sis_student_id),
           test_masked.shift_date(s.date_of_birth, s.sis_student_id),
           lower(test_masked.pseudo(s.sis_student_id, 'stu')) || '@example.invalid',
           test_masked.fake_phone(s.sis_student_id),
           s.postcode, s.program_code, s.study_level, s.enrolment_status, s.enrolment_year,
           s.completion_year, s.international_flag, s.gpa
      FROM silver.student_current s
      JOIN silver.link_person l ON l.system_name = 'SIS' AND l.source_record_id = s.sis_student_id
     WHERE s.anonymised_at IS NULL;

    INSERT INTO test_masked.constituent
    SELECT test_masked.pseudo(c.crm_contact_id, 'CRM'), test_masked.pseudo(l.person_id, 'PER'),
           test_masked.fake_first_name(c.crm_contact_id), test_masked.fake_last_name(c.crm_contact_id),
           test_masked.shift_date(c.date_of_birth, c.crm_contact_id),
           lower(test_masked.pseudo(c.crm_contact_id, 'crm')) || '@example.invalid',
           test_masked.fake_phone(c.crm_contact_id),
           c.postcode, c.contact_type, c.alumni_year, c.donor_flag,
           round(c.lifetime_donation_aud, -3), c.engagement_score
      FROM silver.constituent_current c
      JOIN silver.link_person l ON l.system_name = 'ADV_CRM' AND l.source_record_id = c.crm_contact_id
     WHERE c.anonymised_at IS NULL;

    INSERT INTO audit.lineage (run_id, source, target, operation, row_count, masked) VALUES
    (p_run_id, 'silver.sat_employee',    'test_masked.employee',    'MASK', (SELECT count(*) FROM test_masked.employee),    TRUE),
    (p_run_id, 'silver.sat_student',     'test_masked.student',     'MASK', (SELECT count(*) FROM test_masked.student),     TRUE),
    (p_run_id, 'silver.sat_constituent', 'test_masked.constituent', 'MASK', (SELECT count(*) FROM test_masked.constituent), TRUE);
END;
$$;
