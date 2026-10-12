-- =============================================================================
-- 02 Audit framework
-- Design elements: pipeline run log (governed integration), metadata catalogue
-- and lineage register (fixes "nobody knows where copies went"), retention
-- policy register (fixes "nothing is ever thrown out"), data-quality log.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Pipeline run log. One row per pipeline step. The orchestrator writes the
-- RUNNING row and the final status in their own transactions, so a FAILED row
-- survives the rollback of the step it describes.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.pipeline_run (
    run_id         SERIAL PRIMARY KEY,
    batch_id       UUID NOT NULL,                 -- groups the steps of one pipeline execution
    step_name      TEXT NOT NULL,
    source_name    TEXT,
    target_table   TEXT,
    rows_read      INT,
    rows_loaded    INT,
    run_status     TEXT NOT NULL CHECK (run_status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    error_message  TEXT,
    started_at     TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    completed_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS ix_pipeline_run_batch ON audit.pipeline_run (batch_id);

CREATE OR REPLACE FUNCTION audit.start_step(p_batch UUID, p_step TEXT, p_source TEXT, p_target TEXT)
RETURNS INT LANGUAGE sql AS $$
    INSERT INTO audit.pipeline_run (batch_id, step_name, source_name, target_table, run_status)
    VALUES (p_batch, p_step, p_source, p_target, 'RUNNING')
    RETURNING run_id;
$$;

CREATE OR REPLACE PROCEDURE audit.finish_step(p_run_id INT)
LANGUAGE sql AS $$
    UPDATE audit.pipeline_run
       SET run_status = 'SUCCESS', completed_at = clock_timestamp()
     WHERE run_id = p_run_id;
$$;

CREATE OR REPLACE PROCEDURE audit.fail_step(p_run_id INT, p_error TEXT)
LANGUAGE sql AS $$
    UPDATE audit.pipeline_run
       SET run_status = 'FAILED', rows_loaded = 0, error_message = p_error,
           completed_at = clock_timestamp()
     WHERE run_id = p_run_id;
$$;

-- Steps call this inside their own transaction to report row counts.
CREATE OR REPLACE PROCEDURE audit.set_step_rows(p_run_id INT, p_read INT, p_loaded INT)
LANGUAGE sql AS $$
    UPDATE audit.pipeline_run SET rows_read = p_read, rows_loaded = p_loaded WHERE run_id = p_run_id;
$$;

-- ---------------------------------------------------------------------------
-- Metadata catalogue. Every governed dataset registers itself here when it is
-- loaded. The discovery scan (07) adds anything it finds that nobody
-- registered, which is how the shadow copies come to light.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.dataset (
    dataset_id         SERIAL PRIMARY KEY,
    dataset            TEXT UNIQUE NOT NULL,          -- schema.table
    layer              TEXT NOT NULL CHECK (layer IN ('source', 'bronze', 'silver', 'gold', 'test_masked', 'dev_sandbox', 'reports')),
    environment        TEXT NOT NULL,
    contains_real_pii  BOOLEAN NOT NULL,
    masked             BOOLEAN NOT NULL DEFAULT FALSE,
    owner              TEXT NOT NULL,
    status             TEXT NOT NULL CHECK (status IN ('REGISTERED', 'FOUND_BY_SCAN', 'QUARANTINED', 'PURGED')),
    row_count          BIGINT,
    real_pii_rows      BIGINT,                        -- rows that still hold real personal data
    registered_at      TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    last_scanned_at    TIMESTAMPTZ,
    notes              TEXT
);

CREATE OR REPLACE PROCEDURE audit.register_dataset(
    p_dataset TEXT, p_layer TEXT, p_environment TEXT, p_real_pii BOOLEAN, p_masked BOOLEAN, p_owner TEXT)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit.dataset (dataset, layer, environment, contains_real_pii, masked, owner, status)
    VALUES (p_dataset, p_layer, p_environment, p_real_pii, p_masked, p_owner, 'REGISTERED')
    ON CONFLICT (dataset) DO UPDATE
       SET layer = EXCLUDED.layer, environment = EXCLUDED.environment,
           contains_real_pii = EXCLUDED.contains_real_pii, masked = EXCLUDED.masked,
           owner = EXCLUDED.owner, status = 'REGISTERED';
END;
$$;

-- PII columns found by the discovery scan, classified by sensitivity.
CREATE TABLE IF NOT EXISTS audit.pii_column (
    column_id          SERIAL PRIMARY KEY,
    dataset            TEXT NOT NULL,
    column_name        TEXT NOT NULL,
    sensitivity_level  TEXT NOT NULL CHECK (sensitivity_level IN ('DIRECT', 'QUASI', 'SENSITIVE', 'FINANCIAL')),
    detected_by        TEXT NOT NULL,
    detected_at        TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (dataset, column_name)
);

-- ---------------------------------------------------------------------------
-- Lineage register: one row every time data moves, written by the step that
-- moved it (from where, to where, when, by which run, and whether masked).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.lineage (
    lineage_id   SERIAL PRIMARY KEY,
    run_id       INT REFERENCES audit.pipeline_run (run_id),
    parent       TEXT NOT NULL,
    child        TEXT NOT NULL,
    operation    TEXT NOT NULL,       -- e.g. EXTRACT, INGEST, VAULT_LOAD, MASK, AGGREGATE, PURGE
    rows_moved   BIGINT,
    masked       BOOLEAN NOT NULL DEFAULT FALSE,
    recorded_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS ix_lineage_child ON audit.lineage (child);

CREATE OR REPLACE PROCEDURE audit.record_lineage(
    p_run_id INT, p_parent TEXT, p_child TEXT, p_operation TEXT, p_rows BIGINT, p_masked BOOLEAN DEFAULT FALSE)
LANGUAGE sql AS $$
    INSERT INTO audit.lineage (run_id, parent, child, operation, rows_moved, masked)
    VALUES (p_run_id, p_parent, p_child, p_operation, p_rows, p_masked);
$$;

-- ---------------------------------------------------------------------------
-- Retention policies. Periods follow the scenario's 7-year rule for
-- inactive personal records and the approved retention period recorded with
-- each test extract (NSW PPIP Act s12: keep personal information no longer
-- than necessary).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.retention_policy (
    policy_id              VARCHAR(10) PRIMARY KEY,
    policy_name            TEXT NOT NULL,
    applies_to             TEXT NOT NULL,
    trigger_rule           TEXT NOT NULL,
    retention_period_days  INT,               -- NULL when the period comes from the record itself
    action                 TEXT NOT NULL CHECK (action IN ('ANONYMISE', 'DELETE', 'DROP_TABLE'))
);

INSERT INTO audit.retention_policy VALUES
('RP-01', 'Inactive student personal details', 'silver.sat_student_pii',
 'enrolment_status in (Completed, Withdrawn) and last_activity_date + period < as_of', 2555, 'ANONYMISE'),
('RP-02', 'Former staff personal and financial details', 'silver.sat_employee_pii',
 'employment_status = Former and employment_end_date + period < as_of', 2555, 'ANONYMISE'),
('RP-03', 'Inactive non-donor CRM contacts', 'silver.sat_constituent_pii, silver.sat_constituent_details',
 'donor_flag = N and last_contact_date + period < as_of', 2555, 'DELETE'),
('RP-04', 'Shadow test copies past approved retention', 'dev_sandbox.*',
 'retention_expiry_date < as_of (row level); table dropped once empty', NULL, 'DELETE'),
('RP-05', 'Bronze landing batches', 'bronze.*_raw',
 'keep only the latest batch per table; erase PII of records already actioned by RP-01..03', NULL, 'DELETE')
ON CONFLICT (policy_id) DO UPDATE
   SET policy_name = EXCLUDED.policy_name, applies_to = EXCLUDED.applies_to,
       trigger_rule = EXCLUDED.trigger_rule, retention_period_days = EXCLUDED.retention_period_days,
       action = EXCLUDED.action;

-- Records whose personal data has been anonymised or deleted. Later loads
-- consult this register so expired PII is not loaded back in from the source.
CREATE TABLE IF NOT EXISTS audit.erasure_register (
    system_name     TEXT NOT NULL,
    business_key    TEXT NOT NULL,
    policy_id       VARCHAR(10) NOT NULL REFERENCES audit.retention_policy (policy_id),
    action          TEXT NOT NULL,
    run_id          INT REFERENCES audit.pipeline_run (run_id),
    applied_at      TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (system_name, business_key)
);

-- Snapshot of what each retention review found (dry run or live).
CREATE TABLE IF NOT EXISTS audit.retention_review (
    review_id      SERIAL PRIMARY KEY,
    run_id         INT REFERENCES audit.pipeline_run (run_id),
    as_of_date     DATE NOT NULL,
    dry_run        BOOLEAN NOT NULL,
    reviewed_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS audit.retention_due_record (
    review_id       INT NOT NULL REFERENCES audit.retention_review (review_id) ON DELETE CASCADE,
    policy_id       VARCHAR(10) NOT NULL REFERENCES audit.retention_policy (policy_id),
    target_object   TEXT NOT NULL,
    system_name     TEXT NOT NULL,
    record_key      TEXT NOT NULL,
    expired_on      DATE NOT NULL,
    days_overdue    INT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_retention_due_review ON audit.retention_due_record (review_id, policy_id);

CREATE TABLE IF NOT EXISTS audit.purge_log (
    purge_id       SERIAL PRIMARY KEY,
    run_id         INT REFERENCES audit.pipeline_run (run_id),
    policy_id      VARCHAR(10) REFERENCES audit.retention_policy (policy_id),
    target_object  TEXT NOT NULL,
    action         TEXT NOT NULL,
    rows_before    BIGINT,
    rows_affected  BIGINT NOT NULL,
    rows_after     BIGINT,
    executed_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------------
-- Data-quality findings raised while loading silver.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.dq_issue (
    issue_id       SERIAL PRIMARY KEY,
    run_id         INT REFERENCES audit.pipeline_run (run_id),
    system_name    TEXT NOT NULL,
    record_key     TEXT NOT NULL,
    rule_name      TEXT NOT NULL,
    detail         TEXT,
    detected_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- PII holdings per dataset, captured before and after retention runs.
CREATE TABLE IF NOT EXISTS audit.pii_holding_snapshot (
    snapshot_id        SERIAL PRIMARY KEY,
    run_id             INT REFERENCES audit.pipeline_run (run_id),
    phase              TEXT NOT NULL CHECK (phase IN ('BEFORE_RETENTION', 'AFTER_RETENTION')),
    dataset            TEXT NOT NULL,
    layer              TEXT NOT NULL,
    status             TEXT NOT NULL,
    contains_real_pii  BOOLEAN NOT NULL,
    masked             BOOLEAN NOT NULL,
    row_count          BIGINT NOT NULL,
    real_pii_rows      BIGINT NOT NULL,
    taken_at           TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
