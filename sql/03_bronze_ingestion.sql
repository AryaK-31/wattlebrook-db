-- =============================================================================
-- 03 Bronze ingestion
-- Design element: governed integration. Each load copies a source table as-is
-- into an append-only bronze table, stamped with the run that loaded it, the
-- load time and the record source. Row counts are reconciled and the movement
-- is written to the lineage register.
-- =============================================================================

CREATE OR REPLACE PROCEDURE bronze.load_source(
    p_run_id        INT,
    p_source        REGCLASS,   -- e.g. 'src_sis.student'; REGCLASS rejects anything that is not a real table
    p_target_schema TEXT,
    p_target_table  TEXT,
    p_label         TEXT        -- record_source value, e.g. 'SIS'
) LANGUAGE plpgsql AS $$
DECLARE
    v_target  TEXT := format('%I.%I', p_target_schema, p_target_table);
    v_cols    TEXT;
    v_read    BIGINT;
    v_loaded  BIGINT;
BEGIN
    -- First load: create the bronze table with the source's columns plus load metadata.
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %s AS
         SELECT s.*, NULL::INT AS pipeline_run_id, NULL::TIMESTAMPTZ AS ingested_at, NULL::TEXT AS record_source
         FROM %s s WHERE FALSE', v_target, p_source);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %s (pipeline_run_id)', p_target_table || '_run_ix', v_target);

    -- Insert by column name, so a change in source column order cannot misalign data.
    -- A source column missing from bronze makes the step fail loudly (and be logged).
    SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum)
      INTO v_cols
      FROM pg_attribute a
     WHERE a.attrelid = p_source AND a.attnum > 0 AND NOT a.attisdropped;

    EXECUTE format('SELECT count(*) FROM %s', p_source) INTO v_read;

    EXECUTE format(
        'INSERT INTO %s (%s, pipeline_run_id, ingested_at, record_source)
         SELECT %s, %s, clock_timestamp(), %L FROM %s',
        v_target, v_cols, v_cols, p_run_id, p_label, p_source);
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    IF v_loaded <> v_read THEN
        RAISE EXCEPTION 'Row count mismatch for %: read %, loaded %', v_target, v_read, v_loaded;
    END IF;

    CALL audit.set_step_rows(p_run_id, v_read::INT, v_loaded::INT);
    CALL audit.record_lineage(p_run_id, p_source::TEXT, v_target, 'INGEST', v_loaded, FALSE);
    CALL audit.register_dataset(v_target, 'bronze', 'warehouse', TRUE, FALSE, 'Data Platform Team');
END;
$$;

-- Latest batch loaded into a bronze table (silver reads only this batch).
CREATE OR REPLACE FUNCTION bronze.latest_batch(p_table REGCLASS)
RETURNS INT LANGUAGE plpgsql STABLE AS $$
DECLARE v INT;
BEGIN
    EXECUTE format('SELECT max(pipeline_run_id) FROM %s', p_table) INTO v;
    RETURN v;
END;
$$;
