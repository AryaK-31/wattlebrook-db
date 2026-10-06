CREATE TABLE IF NOT EXISTS audit.pipeline_run (
    run_id SERIAL PRIMARY KEY,
    source_name TEXT NOT NULL,
    target_table TEXT NOT NULL,
    rows_read INT,
    rows_loaded INT,
    run_status TEXT CHECK (run_status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    error_message TEXT,
    started_at TIMESTAMPTZ DEFAULT clock_timestamp(),
    completed_at TIMESTAMPTZ
);

CREATE OR REPLACE PROCEDURE bronze.load_source(
    p_source TEXT,
    p_target TEXT,
    p_label TEXT
) LANGUAGE plpgsql AS $$
DECLARE 
    v_run INT; 
    v_read INT; 
    v_loaded INT;
BEGIN
    INSERT INTO audit.pipeline_run(source_name, target_table, run_status)
    VALUES (p_source, p_target, 'RUNNING') 
    RETURNING run_id INTO v_run;

    BEGIN
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %s AS
             SELECT s.*, NULL::INT AS pipeline_run_id,
                    NULL::TIMESTAMPTZ AS ingested_at, NULL::TEXT AS record_source
             FROM %s s WHERE FALSE',
            p_target, p_source
        );

        EXECUTE format('SELECT count(*) FROM %s', p_source) INTO v_read;
        EXECUTE format('TRUNCATE TABLE %s', p_target);
        
        EXECUTE format(
            'INSERT INTO %s SELECT s.*, %s, clock_timestamp(), %L FROM %s s',
            p_target, v_run, p_label, p_source
        );
        
        GET DIAGNOSTICS v_loaded = ROW_COUNT;

        IF v_loaded <> v_read THEN 
            RAISE EXCEPTION 'Row count mismatch: Read % rows, Loaded % rows', v_read, v_loaded; 
        END IF;

        UPDATE audit.pipeline_run 
        SET rows_read = v_read, 
            rows_loaded = v_loaded, 
            run_status = 'SUCCESS', 
            completed_at = clock_timestamp() 
        WHERE run_id = v_run;

    EXCEPTION WHEN OTHERS THEN
        UPDATE audit.pipeline_run 
        SET rows_read = COALESCE(v_read, 0), 
            rows_loaded = 0, 
            run_status = 'FAILED', 
            error_message = SQLERRM, 
            completed_at = clock_timestamp() 
        WHERE run_id = v_run;
        RAISE;
    END;
END;
$$;