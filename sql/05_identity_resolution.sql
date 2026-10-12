-- =============================================================================
-- 05 Identity resolution (person hub + identity link)
-- Design element: recognise that one person can have an HRMS, an SIS and a
-- CRM record without deleting any of them. Each source record keeps its own
-- hub; the person hub and link say which records belong to the same person
-- and which rule decided it.
--
-- Matching rules (applied to cleaned current satellite data):
--   R1_EMAIL           same normalised email address                    -> HIGH
--   R2_SURNAME_DOB_PHONE same surname + date of birth + mobile number  -> HIGH
--   R3_NAME_DOB        same canonical first name + surname + DOB         -> MEDIUM
--                      accepted only when the match is unambiguous and the
--                      two groups share no system (one person cannot hold
--                      two student records)
--   R0_PRIOR_LINK      record whose PII was erased by retention keeps the
--                      person it was linked to before                   -> HIGH
-- Records matched by nothing are their own person (SINGLE).
--
-- Groups are formed as connected components: if A matches B and B matches C,
-- all three are one person. A group keeps the person_id its members had in
-- the previous run (survivorship), so IDs stay stable across runs even when
-- retention deletes one of the records.
-- =============================================================================

CREATE OR REPLACE PROCEDURE silver.resolve_identities(p_run_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_now      TIMESTAMPTZ := clock_timestamp();
    v_changed  BIGINT;
    v_iter     INT := 0;
    v_nodes    BIGINT;
    v_people   BIGINT;
BEGIN
    DROP TABLE IF EXISTS tmp_node, tmp_edge, tmp_r3, tmp_prior, tmp_group_sys, tmp_unique_partner, tmp_group_id;

    -- ---------------------------------------------------- 1. candidate records
    CREATE TEMP TABLE tmp_node ON COMMIT DROP AS
    SELECT 'SIS:' || sis_student_id AS node, 'SIS' AS sys, sis_student_id AS bk, student_hk AS source_hk,
           email, phone, lower(last_name) AS surname, silver.canonical_first(first_name) AS first_c,
           date_of_birth AS dob, (anonymised_at IS NULL AND first_name IS NOT NULL) AS has_pii
      FROM silver.v_student_current
    UNION ALL
    SELECT 'HRMS:' || hr_employee_id, 'HRMS', hr_employee_id, employee_hk,
           email, phone, lower(last_name), silver.canonical_first(first_name),
           date_of_birth, (anonymised_at IS NULL AND first_name IS NOT NULL)
      FROM silver.v_employee_current
    UNION ALL
    SELECT 'ADV_CRM:' || crm_contact_id, 'ADV_CRM', crm_contact_id, constituent_hk,
           email, phone, lower(last_name), silver.canonical_first(first_name),
           date_of_birth, (anonymised_at IS NULL AND first_name IS NOT NULL)
      FROM silver.v_constituent_current
     WHERE NOT EXISTS (SELECT 1 FROM audit.erasure_register e      -- RP-03 deleted: no longer a person record
                        WHERE e.system_name = 'ADV_CRM' AND e.business_key = crm_contact_id AND e.action = 'DELETE');
    ALTER TABLE tmp_node ADD COLUMN label TEXT;
    UPDATE tmp_node SET label = node;
    CREATE INDEX ON tmp_node (node);
    CREATE INDEX ON tmp_node (email);
    CREATE INDEX ON tmp_node (surname, dob);
    ANALYZE tmp_node;

    -- ---------------------------------------------------- 2. edges from rules
    CREATE TEMP TABLE tmp_edge (a TEXT, b TEXT, rule TEXT) ON COMMIT DROP;

    -- R1: identical email
    INSERT INTO tmp_edge
    SELECT x.node, y.node, 'R1_EMAIL'
      FROM tmp_node x JOIN tmp_node y ON x.email = y.email AND x.node < y.node
     WHERE x.has_pii AND y.has_pii AND x.email IS NOT NULL;

    -- R2: surname + DOB + phone
    INSERT INTO tmp_edge
    SELECT x.node, y.node, 'R2_SURNAME_DOB_PHONE'
      FROM tmp_node x JOIN tmp_node y
        ON x.surname = y.surname AND x.dob = y.dob AND x.phone = y.phone AND x.node < y.node
     WHERE x.has_pii AND y.has_pii AND x.phone IS NOT NULL;

    -- R0: records with erased PII keep their previous person
    CREATE TEMP TABLE tmp_prior ON COMMIT DROP AS
    SELECT l.system_name || ':' || l.business_key AS node, l.person_hk, hp.person_id
      FROM silver.link_person_identity l JOIN silver.hub_person hp ON hp.person_hk = l.person_hk;
    INSERT INTO tmp_edge
    SELECT x.node, p2.node, 'R0_PRIOR_LINK'
      FROM tmp_node x
      JOIN tmp_prior p1 ON p1.node = x.node
      JOIN tmp_prior p2 ON p2.person_hk = p1.person_hk AND p2.node <> x.node
     WHERE NOT x.has_pii;

    -- ------------------------------------- 3. connected components (pass 1)
    LOOP
        UPDATE tmp_node n SET label = m.min_label
          FROM (SELECT e.node, min(t.label) AS min_label
                  FROM (SELECT a AS node, b AS other FROM tmp_edge UNION ALL SELECT b, a FROM tmp_edge) e
                  JOIN tmp_node t ON t.node = e.other
                 GROUP BY e.node) m
         WHERE n.node = m.node AND m.min_label < n.label;
        GET DIAGNOSTICS v_changed = ROW_COUNT;
        v_iter := v_iter + 1;
        EXIT WHEN v_changed = 0 OR v_iter > 50;
    END LOOP;

    -- ------------------------------------ 4. R3 name + DOB, with safeguards
    CREATE TEMP TABLE tmp_r3 ON COMMIT DROP AS
    SELECT x.node AS a, y.node AS b, x.label AS la, y.label AS lb
      FROM tmp_node x JOIN tmp_node y
        ON x.first_c = y.first_c AND x.surname = y.surname AND x.dob = y.dob AND x.label < y.label
     WHERE x.has_pii AND y.has_pii;

    -- Systems already present in each group, and groups with exactly one R3 partner
    CREATE TEMP TABLE tmp_group_sys ON COMMIT DROP AS
    SELECT label, array_agg(DISTINCT sys) AS systems FROM tmp_node GROUP BY label;
    CREATE INDEX ON tmp_group_sys (label);
    CREATE TEMP TABLE tmp_unique_partner ON COMMIT DROP AS
    SELECT g FROM (SELECT la AS g, lb AS other FROM tmp_r3 UNION SELECT lb, la FROM tmp_r3) p
     GROUP BY g HAVING count(DISTINCT other) = 1;

    INSERT INTO tmp_edge
    SELECT r.a, r.b, 'R3_NAME_DOB'
      FROM tmp_r3 r
      JOIN tmp_unique_partner ua ON ua.g = r.la                  -- unambiguous on both sides
      JOIN tmp_unique_partner ub ON ub.g = r.lb
      JOIN tmp_group_sys sa ON sa.label = r.la
      JOIN tmp_group_sys sb ON sb.label = r.lb
     WHERE NOT (sa.systems && sb.systems);                      -- no shared system

    v_iter := 0;
    LOOP
        UPDATE tmp_node n SET label = m.min_label
          FROM (SELECT e.node, min(t.label) AS min_label
                  FROM (SELECT a AS node, b AS other FROM tmp_edge UNION ALL SELECT b, a FROM tmp_edge) e
                  JOIN tmp_node t ON t.node = e.other
                 GROUP BY e.node) m
         WHERE n.node = m.node AND m.min_label < n.label;
        GET DIAGNOSTICS v_changed = ROW_COUNT;
        v_iter := v_iter + 1;
        EXIT WHEN v_changed = 0 OR v_iter > 50;
    END LOOP;

    -- ------------------------------------------------ 5. write hub and link
    -- Survivorship: a group keeps the person_id most of its members had last run, so IDs
    -- stay stable when a member is deleted. If an old group split, the larger part keeps
    -- the ID. New groups get an ID derived from their smallest record key.
    CREATE TEMP TABLE tmp_group_id ON COMMIT DROP AS
    WITH votes AS (
        SELECT n.label, p.person_id, count(*) AS c
          FROM tmp_node n JOIN tmp_prior p ON p.node = n.node GROUP BY n.label, p.person_id
    ), best AS (
        SELECT DISTINCT ON (label) label, person_id, c FROM votes ORDER BY label, c DESC, person_id
    ), claimed AS (
        SELECT label, person_id, row_number() OVER (PARTITION BY person_id ORDER BY c DESC, label) AS rk FROM best
    )
    SELECT g.label, c.person_id AS kept_id, 'P-' || upper(left(md5(g.label), 10)) AS fresh_id
      FROM (SELECT DISTINCT label FROM tmp_node) g
      LEFT JOIN claimed c ON c.label = g.label AND c.rk = 1;
    UPDATE tmp_group_id SET kept_id = CASE
             WHEN fresh_id IN (SELECT kept_id FROM tmp_group_id WHERE kept_id IS NOT NULL)
             THEN 'P-' || upper(left(md5(label || '#' || p_run_id), 10))
             ELSE fresh_id END
     WHERE kept_id IS NULL;
    ALTER TABLE tmp_group_id DROP COLUMN fresh_id;
    ALTER TABLE tmp_group_id RENAME COLUMN kept_id TO person_id;
    CREATE INDEX ON tmp_group_id (label);

    TRUNCATE silver.link_person_identity;
    DELETE FROM silver.hub_person;

    INSERT INTO silver.hub_person (person_hk, person_id, load_dts, pipeline_run_id)
    SELECT silver.hash_key(person_id), person_id, v_now, p_run_id FROM tmp_group_id;

    INSERT INTO silver.link_person_identity
           (link_hk, person_hk, system_name, business_key, source_hk, match_rule, match_confidence, load_dts, pipeline_run_id)
    SELECT silver.hash_key(n.node), silver.hash_key(g.person_id), n.sys, n.bk, n.source_hk,
           coalesce(r.rules, 'NO_MATCH'),
           CASE WHEN r.rules IS NULL THEN 'SINGLE'
                WHEN r.rules ~ 'R0_|R1_|R2_' THEN 'HIGH'
                ELSE 'MEDIUM' END,
           v_now, p_run_id
      FROM tmp_node n
      JOIN tmp_group_id g ON g.label = n.label
      LEFT JOIN (SELECT node, string_agg(DISTINCT rule, '+' ORDER BY rule) AS rules
                   FROM (SELECT a AS node, rule FROM tmp_edge UNION ALL SELECT b, rule FROM tmp_edge) e
                  GROUP BY node) r ON r.node = n.node;

    SELECT count(*) INTO v_nodes FROM tmp_node;
    SELECT count(*) INTO v_people FROM silver.hub_person;
    CALL audit.record_lineage(p_run_id, 'silver.sat_*_pii (current)', 'silver.link_person_identity', 'IDENTITY_RESOLUTION', v_nodes);
    CALL audit.record_lineage(p_run_id, 'silver.sat_*_pii (current)', 'silver.hub_person', 'IDENTITY_RESOLUTION', v_people);
    CALL audit.register_dataset('silver.hub_person', 'silver', 'warehouse', FALSE, FALSE, 'Data Platform Team');
    CALL audit.register_dataset('silver.link_person_identity', 'silver', 'warehouse', FALSE, FALSE, 'Data Platform Team');
    CALL audit.set_step_rows(p_run_id, v_nodes::INT, v_people::INT);
END;
$$;
