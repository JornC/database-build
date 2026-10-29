/*
 * load_table
 * ----------
 * Function to copy the data of the supplied file to the supplied table.
 * The file should contain tab-separated text with a header as default, as exported by the functions system.store_query and system.store_table. 
 * Depending on the boolean of the constant 'SKIP_REGISTER_LOAD_TABLE' (absent = false), source import-file and the checksum of the imported data is stored in the load_table_logs- table.
 * Optional, also tab-separated text without a header can be imported if the optional parameter is set to false.
 *
 * When the table is empty, its foreign keys are dropped before the copy and added back after it, with their comments.
 * A foreign key is otherwise checked row by row; adding it back checks all rows in one pass, so bad data still fails the load.
 * Some foreign keys are left in place:
 * - Keys with CASCADE, SET NULL or SET DEFAULT actions, as those do more than check.
 * - NOT VALID keys, as adding one back would not check the copied rows.
 * - Keys a partition has from its partitioned table, as only the partitioned table can drop those.
 *
 * @param tablename The table to copy to.
 * @param filespec The file to copy from.
 * @param use_pretty_csv_format Optional parameter to specify if file contains a header (true) or not (false). Default true.
 */
CREATE OR REPLACE FUNCTION system.load_table(tablename regclass, filespec text, use_pretty_csv_format boolean = TRUE)
	RETURNS void AS
$BODY$
DECLARE
	current_encoding text;
	filename text;
	extra_options text = '';
	delimiter_to_use text = E'\t';
	sql text;
	v_checksum_before bigint;
	v_skip_register_load_table boolean;
	v_table_is_empty boolean;
	v_foreign_key record;
	v_restore_statements text[] = '{}';
	v_restore_statement text;
BEGIN
	-- set encoding
	EXECUTE 'SHOW client_encoding' INTO current_encoding;
	EXECUTE 'SET client_encoding TO UTF8';

	filename := replace(filespec, '{tablename}', tablename::text);
	filename := replace(filename, '{datesuffix}', to_char(current_timestamp, 'YYYYMMDD'));

	v_skip_register_load_table := system.should_skip_register_load_table();

	IF v_skip_register_load_table IS FALSE THEN
		v_checksum_before := system.determine_checksum_table(tablename::text);
	END IF;

	IF filename LIKE '%{revision}%' THEN
		filename := replace(filename, '{revision}', system.get_git_revision());
	END IF;

	IF use_pretty_csv_format THEN
		extra_options := 'HEADER';
	END IF;

	EXECUTE 'SELECT NOT EXISTS (SELECT 1 FROM ' || tablename || ')' INTO v_table_is_empty;

	IF v_table_is_empty THEN
		FOR v_foreign_key IN
			SELECT
				conname,
				pg_get_constraintdef(oid) AS definition,
				obj_description(oid, 'pg_constraint') AS description

				FROM pg_constraint

				WHERE
					conrelid = tablename
					AND contype = 'f'
					AND convalidated
					AND confupdtype IN ('a', 'r') -- ON UPDATE: NO ACTION or RESTRICT.
					AND confdeltype IN ('a', 'r') -- ON DELETE: NO ACTION or RESTRICT.
					AND conparentid = 0

				ORDER BY conname
		LOOP
			sql := format('ALTER TABLE %s DROP CONSTRAINT %I', tablename, v_foreign_key.conname);
			RAISE NOTICE '% (added back after the COPY) @ %', sql, timeofday();
			EXECUTE sql;

			v_restore_statements := v_restore_statements || format('ALTER TABLE %s ADD CONSTRAINT %I %s', tablename, v_foreign_key.conname, v_foreign_key.definition);
			IF v_foreign_key.description IS NOT NULL THEN
				v_restore_statements := v_restore_statements || format('COMMENT ON CONSTRAINT %I ON %s IS %L', v_foreign_key.conname, tablename, v_foreign_key.description);
			END IF;
		END LOOP;
	END IF;

	sql := 'COPY ' || tablename || ' FROM ''' || filename || E''' DELIMITER ''' || delimiter_to_use || ''' CSV ' || extra_options;

	RAISE NOTICE '% Starting @ %', sql, timeofday();
	EXECUTE sql;
	RAISE NOTICE '% Done @ %', sql, timeofday();

	FOREACH v_restore_statement IN ARRAY v_restore_statements LOOP
		EXECUTE v_restore_statement;
	END LOOP;

	IF v_skip_register_load_table IS FALSE THEN
		PERFORM system.register_load_table(tablename::text, filename, v_checksum_before);
	END IF;

	-- reset encoding
	EXECUTE 'SET client_encoding TO ' || current_encoding;
END;
$BODY$
LANGUAGE plpgsql VOLATILE;


/*
 * store_query
 * -----------
 * Function to store the results of the supplied query string to the supplied file.
 * In the filename the parts {tablename} or {queryname} can be used, these will be replaced by the supplied queryname.
 * Additionally, the part {datesuffix} can be used, which will be replaced with the current date in YYYYMMDD format.
 *
 * The export is a tab-separated CSV and must have a header (as default) for import files elsewhere in the SQL code.
 * However, if desired, the optional parameter use_pretty_csv_format can be used to generate a file without a header for other purposes.  
 * For this, false must be given as parameter. The default value is true; so if a parameter is not given, the file will have a header.
 *
 * @param queryname The name of the query.
 * @param sql_in The actual query string to export the results for.
 * @param filespec The file to export to.
 * @param use_pretty_csv_format Optional parameter to specify if file is generated with a header (true) or not (false). Default true.
 */
CREATE OR REPLACE FUNCTION system.store_query(queryname text, sql_in text, filespec text, use_pretty_csv_format boolean = TRUE)
	RETURNS void AS
$BODY$
DECLARE
	current_encoding text;
	filename text;
	extra_options text = '';
	delimiter_to_use text = E'\t';
	sql text;
BEGIN
	-- set encoding
	EXECUTE 'SHOW client_encoding' INTO current_encoding;
	EXECUTE 'SET client_encoding TO UTF8';

	filename := replace(filespec, '{queryname}', queryname);
	filename := replace(filename, '{tablename}', queryname);
	filename := replace(filename, '{datesuffix}', to_char(current_timestamp, 'YYYYMMDD'));

	IF filename LIKE '%{revision}%' THEN
		filename := replace(filename, '{revision}', system.get_git_revision());
	END IF;

	filename := '''' || filename || '''';

	IF use_pretty_csv_format THEN
		extra_options := 'HEADER';
	END IF;

	sql := 'COPY (' || sql_in || ') TO ' || filename || E' DELIMITER ''' || delimiter_to_use || ''' CSV ' || extra_options;

	RAISE NOTICE '%', sql;

	EXECUTE sql;

	-- reset encoding
	EXECUTE 'SET client_encoding TO ' || current_encoding;
END;
$BODY$
LANGUAGE plpgsql VOLATILE;


/*
 * store_table
 * -----------
 * Copies the data of the supplied table to the supplied file.
 * In the filename the parts {tablename} or {queryname} can be used, these will be replaced by the supplied table name.
 * Additionally, the part {datesuffix} can be used, which will be replaced with the current date in YYYYMMDD format.
 *
 * The export is a tab-separated CSV and must have a header (as default) for import files elsewhere in the SQL code.
 * However, if desired, the optional parameter use_pretty_csv_format can be used to generate a file without a header for other purposes.  
 * For this, false must be given as parameter. The default value is true; so if a parameter is not given, the file will have a header.
 *
 * @param tablename The name of the table to export.
 * @param filespec The file to export to.
 * @param ordered Optional parameter to indicate if export should be sorted by all columns, starting with the first column (true) or not (false). Default true.
 * @param use_pretty_csv_format Optional parameter to specify if file is generated with a header (true) or not (false). Default true.
 */
CREATE OR REPLACE FUNCTION system.store_table(tablename regclass, filespec text, ordered bool = TRUE, use_pretty_csv_format boolean = TRUE)
	RETURNS void AS
$BODY$
DECLARE
	ordered_columns_string text;
	tableselect text;
BEGIN
	tableselect := 'SELECT * FROM ' || tablename;

	IF ordered THEN
		SELECT
			array_to_string(array_agg(column_name::text), ', ')
			INTO ordered_columns_string
			FROM
				(SELECT column_name
					FROM information_schema.columns
					WHERE (CASE WHEN table_schema = ANY (string_to_array(current_setting('search_path'), ', ')) 
						THEN table_name 
						ELSE table_schema || '.' || table_name END)::text = tablename::text
					ORDER BY ordinal_position
				) ordered_columns;

		tableselect := tableselect || ' ORDER BY ' || ordered_columns_string || '';
	END IF;

	PERFORM system.store_query(tablename::text, tableselect, filespec, use_pretty_csv_format);
END;
$BODY$
LANGUAGE plpgsql VOLATILE;
