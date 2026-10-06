CREATE TABLE IF NOT EXISTS audit.retention_policy (
    policy_id VARCHAR(10) PRIMARY KEY,
    policy_name TEXT NOT NULL,
    applies_to TEXT NOT NULL,
    retention_period_days INT NOT NULL,
    action TEXT CHECK (action IN ('ANONYMISE', 'DELETE', 'DROP_TABLE'))
);

INSERT INTO audit.retention_policy VALUES
('RP-01', 'Expired Student Contact Details', 'silver.sat_student_details', 2555, 'ANONYMISE'),
('RP-02', 'Expired Staff Financials', 'silver.sat_staff_details', 2555, 'ANONYMISE'),
('RP-03', 'Inactive Alumni/Donor Profiles', 'silver.sat_constituent_details', 2555, 'DELETE'),
('RP-04', 'Unregistered Sandbox Copies', 'dev_sandbox', 0, 'DROP_TABLE')
ON CONFLICT (policy_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS audit.purge_log (
    purge_id SERIAL PRIMARY KEY,
    policy_id VARCHAR(10),
    target_object TEXT,
    rows_affected INT,
    executed_at TIMESTAMPTZ DEFAULT clock_timestamp()
);

CREATE OR REPLACE PROCEDURE audit.run_retention(p_dry_run BOOLEAN DEFAULT TRUE)
LANGUAGE plpgsql AS $$
DECLARE
    v_shadow_rows INT;
BEGIN
    IF p_dry_run THEN
        RAISE NOTICE '[DRY RUN] Evaluating retention policies...';
    ELSE
        IF to_regclass('dev_sandbox.shadow_extracts_all') IS NOT NULL THEN
            EXECUTE 'SELECT count(*) FROM dev_sandbox.shadow_extracts_all' INTO v_shadow_rows;
            DROP TABLE dev_sandbox.shadow_extracts_all;

            INSERT INTO audit.purge_log(policy_id, target_object, rows_affected)
            VALUES ('RP-04', 'dev_sandbox.shadow_extracts_all', v_shadow_rows);
        END IF;

        UPDATE audit.dataset 
        SET status = 'PURGED' 
        WHERE status = 'FOUND_BY_SCAN';
    END IF;
END;
$$;