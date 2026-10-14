-- 01 Schemas: one per source system, one per platform layer.

CREATE SCHEMA IF NOT EXISTS src_hrms;     -- HR system
CREATE SCHEMA IF NOT EXISTS src_sis;      -- student system
CREATE SCHEMA IF NOT EXISTS src_crm;      -- alumni and donor CRM
CREATE SCHEMA IF NOT EXISTS dev_sandbox;  -- where the old shadow copies were found

CREATE SCHEMA IF NOT EXISTS bronze;       -- raw copy of each source, reloaded every run
CREATE SCHEMA IF NOT EXISTS silver;       -- Data Vault: hubs, satellites, person link
CREATE SCHEMA IF NOT EXISTS gold;         -- star schema for reporting, no personal data
CREATE SCHEMA IF NOT EXISTS test_masked;  -- masked data for developers
CREATE SCHEMA IF NOT EXISTS audit;        -- run log, catalogue, lineage, retention
CREATE SCHEMA IF NOT EXISTS qa;           -- identity answer key, only used to score matching
CREATE SCHEMA IF NOT EXISTS reports;      -- report views

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- hmac() for masking
