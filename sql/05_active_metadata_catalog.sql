CREATE TABLE IF NOT EXISTS audit.dataset (
    dataset_id SERIAL PRIMARY KEY,
    dataset TEXT UNIQUE NOT NULL,
    environment TEXT NOT NULL,
    real_pii BOOLEAN NOT NULL,
    owner TEXT NOT NULL,
    status TEXT CHECK (status IN ('REGISTERED', 'FOUND_BY_SCAN', 'PURGED'))
);

CREATE TABLE IF NOT EXISTS audit.lineage (
    lineage_id SERIAL PRIMARY KEY,
    parent TEXT NOT NULL,
    child TEXT NOT NULL,
    via TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS audit.pii_column (
    column_id SERIAL PRIMARY KEY,
    table_name TEXT NOT NULL,
    column_name TEXT NOT NULL,
    sensitivity_level TEXT CHECK (sensitivity_level IN ('DIRECT', 'QUASI', 'SENSITIVE', 'FINANCIAL'))
);