-- =============================================================================
-- 11 Indexes
-- Design element: query performance. Business keys are already indexed by
-- their UNIQUE / PRIMARY KEY constraints. These indexes support the two
-- lookups the platform runs most: "find every record for this email or
-- phone" (subject access requests, R1/R2 matching) and "all records of this
-- person" (identity link -> person hub).
-- python/performance_demo.py shows EXPLAIN ANALYZE with and without them.
-- =============================================================================

CREATE INDEX IF NOT EXISTS ix_sat_student_pii_email     ON silver.sat_student_pii (email);
CREATE INDEX IF NOT EXISTS ix_sat_employee_pii_email    ON silver.sat_employee_pii (email);
CREATE INDEX IF NOT EXISTS ix_sat_constituent_pii_email ON silver.sat_constituent_pii (email);
CREATE INDEX IF NOT EXISTS ix_sat_student_pii_phone     ON silver.sat_student_pii (phone);
CREATE INDEX IF NOT EXISTS ix_link_person               ON silver.link_person_identity (person_hk);
CREATE INDEX IF NOT EXISTS ix_erasure_policy            ON audit.erasure_register (policy_id);
