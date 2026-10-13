-- Hubs and the link: demonstration queries.
--
-- Run after a clean pipeline run:  python python/run_pipeline.py --reset
-- Run them one at a time in psql. They only read data.
-- Anh Le (STU0000001, EMP000001, CRM0000001) is followed throughout.
--
-- The idea in one line:
--   A HUB holds one row per business key: the ID a system uses, plus an md5 hash of it.
--   The LINK (silver.link_person) says which source records belong to which person.
--   Personal details live in the satellites, so neither hubs nor the link hold any.
--
-- Numbers below are from a clean run on 13 Oct 2026. Retention uses today's date,
-- so a later run can give slightly different counts.


-- 1. The four hubs and how many keys each holds
SELECT 'hub_student' AS hub, count(*) AS keys, 'sis_student_id' AS business_key FROM silver.hub_student
UNION ALL SELECT 'hub_employee',    count(*), 'hr_employee_id' FROM silver.hub_employee
UNION ALL SELECT 'hub_constituent', count(*), 'crm_contact_id' FROM silver.hub_constituent
UNION ALL SELECT 'hub_person',      count(*), 'person_id'      FROM silver.hub_person;
-- Expected: 15,000 students, 5,000 employees, 7,500 constituents and 20,399 people.
-- Talking point: the first three match the source record counts. hub_person is smaller than
--                27,500 because one person can have records in several systems.


-- 2. What a hub row looks like: keys and load details only, nothing personal
SELECT * FROM silver.hub_student WHERE sis_student_id = 'STU0000001';

SELECT table_name, string_agg(column_name, ', ' ORDER BY ordinal_position) AS columns
  FROM information_schema.columns
 WHERE table_schema = 'silver' AND table_name IN ('hub_student', 'hub_employee', 'hub_constituent', 'hub_person')
 GROUP BY table_name ORDER BY table_name;
-- Expected: business key, hash key, load_dts and record_source. No name, email or date of birth.


-- 3. The hash key is the md5 of the business key, so the same record always gets the same key
SELECT sis_student_id, student_hk, md5(sis_student_id) AS recomputed, student_hk = md5(sis_student_id) AS matches
  FROM silver.hub_student WHERE sis_student_id = 'STU0000001';

SELECT count(*) FILTER (WHERE student_hk = md5(sis_student_id)) AS matching_rows, count(*) AS total_rows
  FROM silver.hub_student;
-- Expected: matches = true; 15,000 of 15,000 rows. This is why reloading a record never creates
--           a duplicate hub row (the load uses ON CONFLICT DO NOTHING).


-- 4. Each source record has exactly one hub row (business keys are unique)
SELECT 'hub_student' AS hub, count(*) AS rows, count(DISTINCT sis_student_id) AS distinct_keys FROM silver.hub_student
UNION ALL SELECT 'hub_employee',    count(*), count(DISTINCT hr_employee_id) FROM silver.hub_employee
UNION ALL SELECT 'hub_constituent', count(*), count(DISTINCT crm_contact_id) FROM silver.hub_constituent
UNION ALL SELECT 'hub_person',      count(*), count(DISTINCT person_id)      FROM silver.hub_person;
-- Expected: rows equal distinct_keys on every line.


-- 5. Without the link, the three source hubs know nothing about each other
SELECT 'student hub' AS hub, sis_student_id AS business_key, student_hk AS hash_key
  FROM silver.hub_student WHERE sis_student_id = 'STU0000001'
UNION ALL
SELECT 'employee hub', hr_employee_id, employee_hk
  FROM silver.hub_employee WHERE hr_employee_id = 'EMP000001'
UNION ALL
SELECT 'constituent hub', crm_contact_id, constituent_hk
  FROM silver.hub_constituent WHERE crm_contact_id = 'CRM0000001';
-- Expected: three unrelated keys and hashes. Nothing here says they are the same person.


-- 6. The person hub: one row per person, with a stable ID and nothing else
SELECT * FROM silver.hub_person
 WHERE person_id = (SELECT person_id FROM silver.link_person WHERE source_record_id = 'STU0000001');
-- Expected: P-3EBCF1622F. The ID is built from the group of records that matched.


-- 7. The link: three rows, one person, and the rule that matched each record
SELECT * FROM silver.link_person
 WHERE source_record_id IN ('STU0000001', 'EMP000001', 'CRM0000001')
 ORDER BY system_name;
-- Expected: three rows with the same person_id, match_rule R2+R3, confidence HIGH.
-- Talking point: this is the whole idea. The source systems share no ID, yet the link ties
--                three IDs to one person and records why.


-- 8. Following the link from the person hub to all three source hubs
SELECT p.person_id,
       l.system_name,
       l.source_record_id,
       l.match_rule,
       l.confidence,
       coalesce(hs.sis_student_id, he.hr_employee_id, hc.crm_contact_id) AS found_in_hub
  FROM silver.hub_person p
  JOIN silver.link_person l ON l.person_id = p.person_id
  LEFT JOIN silver.hub_student     hs ON l.system_name = 'SIS'     AND hs.sis_student_id = l.source_record_id
  LEFT JOIN silver.hub_employee    he ON l.system_name = 'HRMS'    AND he.hr_employee_id = l.source_record_id
  LEFT JOIN silver.hub_constituent hc ON l.system_name = 'ADV_CRM' AND hc.crm_contact_id = l.source_record_id
 WHERE p.person_id = (SELECT person_id FROM silver.link_person WHERE source_record_id = 'STU0000001')
 ORDER BY l.system_name;
-- Expected: one person, three records, and found_in_hub filled in for each (none empty).


-- 9. Using the link: one person to everything held about them
SELECT l.person_id, l.system_name, l.source_record_id,
       coalesce(s.email, e.email, c.email) AS email_held,
       coalesce(s.program_name, e.position_title, c.contact_type) AS what_it_is
  FROM silver.link_person l
  LEFT JOIN silver.student_current     s ON l.system_name = 'SIS'     AND s.sis_student_id = l.source_record_id
  LEFT JOIN silver.employee_current    e ON l.system_name = 'HRMS'    AND e.hr_employee_id = l.source_record_id
  LEFT JOIN silver.constituent_current c ON l.system_name = 'ADV_CRM' AND c.crm_contact_id = l.source_record_id
 WHERE l.person_id = (SELECT person_id FROM silver.link_person WHERE source_record_id = 'STU0000001')
 ORDER BY l.system_name;
-- Expected: three different emails for one person. The details come from the satellites;
--           the link only supplies the connection.


-- 10. The link has one row per source record, so rows are records, not people
SELECT system_name, count(*) AS link_rows FROM silver.link_person GROUP BY system_name ORDER BY system_name;

SELECT count(*) AS link_rows, count(DISTINCT person_id) AS people FROM silver.link_person;
-- Expected: ADV_CRM 7,500, HRMS 5,000, SIS 15,000. In total 27,500 link rows for 20,399 people.
--           Every source record is linked, including those whose personal data retention erased.


-- 11. How many records each person has
SELECT records_per_person, count(*) AS people
  FROM (SELECT person_id, count(*) AS records_per_person FROM silver.link_person GROUP BY person_id) x
 GROUP BY records_per_person ORDER BY records_per_person;
-- Expected: 13,974 people with 1 record, 5,749 with 2, 676 with 3.

-- 11b. The same, by which systems the person appears in
SELECT systems, count(*) AS people
  FROM (SELECT person_id, string_agg(system_name, ' + ' ORDER BY system_name) AS systems
          FROM silver.link_person GROUP BY person_id) x
 GROUP BY systems ORDER BY people DESC;
-- Expected: the 676 with three records are the "ADV_CRM + HRMS + SIS" row.


-- 12. Why each link exists: the rule and its confidence
SELECT confidence, count(*) AS link_rows FROM silver.link_person GROUP BY confidence ORDER BY confidence;

SELECT match_rule, confidence, count(*) AS link_rows
  FROM silver.link_person GROUP BY match_rule, confidence ORDER BY link_rows DESC;
-- Expected: SINGLE 13,974 (rule NONE: matched nothing), HIGH 10,576, MEDIUM 2,950.
-- Talking point: R1 is same email, R2 is same surname + date of birth + phone, R3 is same
--                name + date of birth in a different system. A record gets MEDIUM only when
--                R3 is its only rule, so the weakest links are easy to find and review.


-- 13. A MEDIUM link going wrong, checked against the answer key
SELECT l.person_id, l.system_name, l.source_record_id, l.match_rule, l.confidence, k.true_person_id
  FROM silver.link_person l
  JOIN qa.identity_answer_key k ON k.source_system = l.system_name AND k.source_record_id = l.source_record_id
 WHERE l.confidence = 'MEDIUM'
   AND l.person_id IN (SELECT l2.person_id
                         FROM silver.link_person l2
                         JOIN qa.identity_answer_key k2
                           ON k2.source_system = l2.system_name AND k2.source_record_id = l2.source_record_id
                        GROUP BY l2.person_id HAVING count(DISTINCT k2.true_person_id) > 1)
 ORDER BY l.person_id, l.system_name
 LIMIT 6;
-- Expected: pairs of records merged into one person_id but with DIFFERENT true_person_id values:
--           different people who share a name and date of birth ("false friends").
-- Talking point: this is why R3 alone is only MEDIUM confidence. See reports.identity_accuracy.


-- 14. Integrity: hubs and link agree with each other
SELECT 'links with no source hub row' AS check_name, count(*) AS problems
  FROM silver.link_person l
 WHERE NOT EXISTS (SELECT 1 FROM silver.hub_student     h WHERE l.system_name = 'SIS'     AND h.sis_student_id = l.source_record_id)
   AND NOT EXISTS (SELECT 1 FROM silver.hub_employee    h WHERE l.system_name = 'HRMS'    AND h.hr_employee_id = l.source_record_id)
   AND NOT EXISTS (SELECT 1 FROM silver.hub_constituent h WHERE l.system_name = 'ADV_CRM' AND h.crm_contact_id = l.source_record_id)
UNION ALL
SELECT 'source hub rows with no link',
       (SELECT count(*) FROM silver.hub_student h WHERE NOT EXISTS
            (SELECT 1 FROM silver.link_person l WHERE l.system_name = 'SIS' AND l.source_record_id = h.sis_student_id))
     + (SELECT count(*) FROM silver.hub_employee h WHERE NOT EXISTS
            (SELECT 1 FROM silver.link_person l WHERE l.system_name = 'HRMS' AND l.source_record_id = h.hr_employee_id))
     + (SELECT count(*) FROM silver.hub_constituent h WHERE NOT EXISTS
            (SELECT 1 FROM silver.link_person l WHERE l.system_name = 'ADV_CRM' AND l.source_record_id = h.crm_contact_id))
UNION ALL
SELECT 'link rows with no person hub row', count(*)
  FROM silver.link_person l WHERE NOT EXISTS (SELECT 1 FROM silver.hub_person p WHERE p.person_id = l.person_id)
UNION ALL
SELECT 'people with no link rows', count(*)
  FROM silver.hub_person p WHERE NOT EXISTS (SELECT 1 FROM silver.link_person l WHERE l.person_id = p.person_id);
-- Expected: 0 on every line. The end-to-end check "every source record is linked to one person"
--           (reports.checks) tests the same thing.


-- 15. The link survives retention. Olivia Saito's student and CRM records were anonymised,
--     yet the link still ties them to her staff record.
SELECT l.system_name, l.source_record_id, l.match_rule, l.confidence,
       CASE l.system_name
            WHEN 'SIS'     THEN (SELECT anonymised_at IS NOT NULL FROM silver.student_current     WHERE sis_student_id = l.source_record_id)
            WHEN 'HRMS'    THEN (SELECT anonymised_at IS NOT NULL FROM silver.employee_current    WHERE hr_employee_id = l.source_record_id)
            WHEN 'ADV_CRM' THEN (SELECT anonymised_at IS NOT NULL FROM silver.constituent_current WHERE crm_contact_id = l.source_record_id)
       END AS personal_data_erased
  FROM silver.link_person l
 WHERE l.person_id = (SELECT person_id FROM silver.link_person WHERE source_record_id = 'STU0000006')
 ORDER BY l.system_name;
-- Expected: ADV_CRM CRM0000006 erased, HRMS EMP000006 not erased (still employed), SIS STU0000006 erased.
-- Talking point: retention blanks the personal details in the satellites but keeps the record and
--                its link, so you can still say how many people were affected without keeping
--                their details.
