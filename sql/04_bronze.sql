-- 04 Bronze: a raw copy of each source table, plus when and by which run it was loaded.

CREATE TABLE IF NOT EXISTS bronze.hrms_employee (
    LIKE src_hrms.employee,
    run_id         INT,
    loaded_at      TIMESTAMPTZ,
    record_source  TEXT
);

CREATE TABLE IF NOT EXISTS bronze.sis_student (
    LIKE src_sis.student,
    run_id         INT,
    loaded_at      TIMESTAMPTZ,
    record_source  TEXT
);

CREATE TABLE IF NOT EXISTS bronze.crm_constituent (
    LIKE src_crm.constituent,
    run_id         INT,
    loaded_at      TIMESTAMPTZ,
    record_source  TEXT
);

-- Reload one bronze table from its source and check that no rows were lost.
CREATE OR REPLACE PROCEDURE bronze.load_source(p_run_id INT, p_source TEXT, p_target TEXT, p_label TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_columns TEXT;
    v_read    INT;
    v_loaded  INT;
BEGIN
    -- Copy column by column name. If the source has a column bronze does not know, this fails.
    SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position) INTO v_columns
      FROM information_schema.columns
     WHERE table_schema || '.' || table_name = p_source;

    EXECUTE format('TRUNCATE bronze.%I', p_target);
    EXECUTE format('INSERT INTO bronze.%I (%s, run_id, loaded_at, record_source)
                    SELECT %s, %s, now(), %L FROM %s',
                   p_target, v_columns, v_columns, p_run_id, p_label, p_source);
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    EXECUTE format('SELECT count(*) FROM %s', p_source) INTO v_read;
    IF v_read <> v_loaded THEN
        RAISE EXCEPTION 'Row count mismatch: read %, loaded %', v_read, v_loaded;
    END IF;

    UPDATE audit.pipeline_run SET rows_read = v_read, rows_loaded = v_loaded WHERE run_id = p_run_id;
    INSERT INTO audit.lineage (run_id, source, target, operation, row_count)
    VALUES (p_run_id, p_source, 'bronze.' || p_target, 'INGEST', v_loaded);
END;
$$;
