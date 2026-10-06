CREATE OR REPLACE PROCEDURE gold.build_star_schema()
LANGUAGE plpgsql AS $$
BEGIN
    DROP TABLE IF EXISTS gold.dim_person CASCADE;

    CREATE TABLE gold.dim_person AS
    SELECT 
        p.person_id,
        p.created_at,
        COALESCE(l_hr.source_record_id, 'NONE') AS hr_employee_id,
        COALESCE(l_sis.source_record_id, 'NONE') AS sis_student_id,
        COALESCE(l_crm.source_record_id, 'NONE') AS crm_contact_id,
        (CASE WHEN l_hr.link_id IS NOT NULL THEN 1 ELSE 0 END +
         CASE WHEN l_sis.link_id IS NOT NULL THEN 1 ELSE 0 END +
         CASE WHEN l_crm.link_id IS NOT NULL THEN 1 ELSE 0 END) AS system_count
    FROM silver.hub_person p
    LEFT JOIN silver.link_person_identity l_hr ON p.person_id = l_hr.person_id AND l_hr.system_name = 'HRMS'
    LEFT JOIN silver.link_person_identity l_sis ON p.person_id = l_sis.person_id AND l_sis.system_name = 'SIS'
    LEFT JOIN silver.link_person_identity l_crm ON p.person_id = l_crm.person_id AND l_crm.system_name = 'CRM';
END;
$$;