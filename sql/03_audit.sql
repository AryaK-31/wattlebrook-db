-- 03 Audit tables: run log, catalogue, lineage and retention policies.

-- One row per pipeline step. run_pipeline.py writes it.
CREATE TABLE IF NOT EXISTS audit.pipeline_run (
    run_id        SERIAL PRIMARY KEY,
    batch_id      UUID NOT NULL,            -- all steps of one pipeline run share this
    step_name     TEXT NOT NULL,
    rows_read     INT,
    rows_loaded   INT,
    status        TEXT NOT NULL CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    error_message TEXT,
    started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at   TIMESTAMPTZ
);

-- Catalogue: every dataset we know about, who owns it and whether it holds real personal data.
-- The discovery scan (07) adds any table that is not listed here as FOUND_BY_SCAN.
CREATE TABLE IF NOT EXISTS audit.dataset (
    dataset       TEXT PRIMARY KEY,          -- schema.table
    layer         TEXT NOT NULL,
    owner         TEXT NOT NULL,
    real_pii      BOOLEAN NOT NULL,
    status        TEXT NOT NULL CHECK (status IN ('REGISTERED', 'FOUND_BY_SCAN', 'QUARANTINED', 'PURGED')),
    added_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO audit.dataset (dataset, layer, owner, real_pii, status) VALUES
('src_hrms.employee',            'source',      'People & Culture',       TRUE,  'REGISTERED'),
('src_sis.student',              'source',      'Student Administration', TRUE,  'REGISTERED'),
('src_crm.constituent',          'source',      'Advancement Office',     TRUE,  'REGISTERED'),
('bronze.hrms_employee',          'bronze',      'Data Platform Team',     TRUE,  'REGISTERED'),
('bronze.sis_student',           'bronze',      'Data Platform Team',     TRUE,  'REGISTERED'),
('bronze.crm_constituent',       'bronze',      'Data Platform Team',     TRUE,  'REGISTERED'),
('silver.hub_employee',          'silver',      'Data Platform Team',     FALSE, 'REGISTERED'),
('silver.hub_student',           'silver',      'Data Platform Team',     FALSE, 'REGISTERED'),
('silver.hub_constituent',       'silver',      'Data Platform Team',     FALSE, 'REGISTERED'),
('silver.sat_employee',          'silver',      'People & Culture',       TRUE,  'REGISTERED'),
('silver.sat_student',           'silver',      'Student Administration', TRUE,  'REGISTERED'),
('silver.sat_constituent',       'silver',      'Advancement Office',     TRUE,  'REGISTERED'),
('silver.hub_person',            'silver',      'Data Platform Team',     FALSE, 'REGISTERED'),
('silver.link_person',           'silver',      'Data Platform Team',     FALSE, 'REGISTERED'),
('test_masked.employee',         'test_masked', 'Data Platform Team',     FALSE, 'REGISTERED'),
('test_masked.student',          'test_masked', 'Data Platform Team',     FALSE, 'REGISTERED'),
('test_masked.constituent',      'test_masked', 'Data Platform Team',     FALSE, 'REGISTERED'),
('gold.dim_person',              'gold',        'Data Platform Team',     FALSE, 'REGISTERED'),
('gold.dim_program',             'gold',        'Data Platform Team',     FALSE, 'REGISTERED'),
('gold.fact_enrolment',          'gold',        'Data Platform Team',     FALSE, 'REGISTERED'),
('gold.fact_giving',             'gold',        'Data Platform Team',     FALSE, 'REGISTERED'),
('qa.identity_answer_key',       'qa',          'Data Platform Team',     FALSE, 'REGISTERED')
ON CONFLICT (dataset) DO NOTHING;

-- Columns the discovery scan classified as personal data.
CREATE TABLE IF NOT EXISTS audit.pii_column (
    dataset       TEXT NOT NULL,
    column_name   TEXT NOT NULL,
    category      TEXT NOT NULL CHECK (category IN ('DIRECT', 'QUASI', 'SENSITIVE', 'FINANCIAL')),
    PRIMARY KEY (dataset, column_name)
);

-- Lineage: one row every time a step moves data, written by that step.
CREATE TABLE IF NOT EXISTS audit.lineage (
    lineage_id    SERIAL PRIMARY KEY,
    run_id        INT REFERENCES audit.pipeline_run (run_id),
    source        TEXT NOT NULL,
    target        TEXT NOT NULL,
    operation     TEXT NOT NULL,             -- INGEST, VAULT_LOAD, MATCH, MASK, PURGE, BUILD
    row_count     INT,
    masked        BOOLEAN NOT NULL DEFAULT FALSE,
    recorded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Retention policies. 2555 days = 7 years after the person stopped being active.
CREATE TABLE IF NOT EXISTS audit.retention_policy (
    policy_id     TEXT PRIMARY KEY,
    description   TEXT NOT NULL,
    applies_to    TEXT NOT NULL,
    keep_days     INT,                       -- NULL: the record carries its own expiry date
    action        TEXT NOT NULL CHECK (action IN ('ANONYMISE', 'DELETE'))
);

INSERT INTO audit.retention_policy VALUES
('RP-01', 'Students who completed or withdrew',    'silver.sat_student',          2555, 'ANONYMISE'),
('RP-02', 'Former staff',                          'silver.sat_employee',         2555, 'ANONYMISE'),
('RP-03', 'CRM contacts who are not donors',       'silver.sat_constituent',      2555, 'ANONYMISE'),
('RP-04', 'Test copies past their approved date',  'dev_sandbox.shadow_extracts', NULL, 'DELETE')
ON CONFLICT (policy_id) DO NOTHING;

-- What each retention run did.
CREATE TABLE IF NOT EXISTS audit.purge_log (
    purge_id      SERIAL PRIMARY KEY,
    run_id        INT REFERENCES audit.pipeline_run (run_id),
    policy_id     TEXT REFERENCES audit.retention_policy (policy_id),
    target        TEXT NOT NULL,
    action        TEXT NOT NULL,
    rows_before   INT,                       -- rows still holding personal data before the run
    rows_affected INT NOT NULL,
    rows_after    INT,
    executed_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
