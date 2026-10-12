-- =============================================================================
-- 01 Schemas
-- Design element: overall architecture (source systems -> bronze -> silver ->
-- gold, with test_masked branching off silver and audit running alongside).
-- =============================================================================

-- Simulated operational source systems (one schema per system, no shared keys)
CREATE SCHEMA IF NOT EXISTS src_hrms;      -- Human Resources Management System
CREATE SCHEMA IF NOT EXISTS src_sis;       -- Student Information System
CREATE SCHEMA IF NOT EXISTS src_crm;       -- Advancement CRM (alumni and donors)

-- The uncontrolled state found by the 2026 audit: shadow copies in dev areas
CREATE SCHEMA IF NOT EXISTS dev_sandbox;

-- Governed platform layers
CREATE SCHEMA IF NOT EXISTS bronze;        -- raw landing, append-only batches
CREATE SCHEMA IF NOT EXISTS silver;        -- Data Vault 2.0 (hubs, links, satellites)
CREATE SCHEMA IF NOT EXISTS gold;          -- star schema for reporting (no direct PII)
CREATE SCHEMA IF NOT EXISTS test_masked;   -- masked test data for developers
CREATE SCHEMA IF NOT EXISTS audit;         -- run log, catalogue, lineage, retention
CREATE SCHEMA IF NOT EXISTS reports;       -- report views over the layers above
CREATE SCHEMA IF NOT EXISTS qa;            -- answer key used only to score the matcher

-- Keyed hashing (HMAC) for pseudonymisation
CREATE EXTENSION IF NOT EXISTS pgcrypto;
