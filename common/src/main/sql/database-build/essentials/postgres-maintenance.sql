/*
 * synchronize_all_serials
 * -----------------------
 * Function to synchronize serials/sequences.
 * All functions with naming convention tablename_columnname_seq are set to the max value of that column in that table.
 *
 * Serials/sequences can get out of sync with the actual content of the database after bulk loads, COPY FROMs and INSERTs without defaults.
 * This function makes sure sequences match the content once again.
 * This is for instance used after a database build.
 */
CREATE OR REPLACE FUNCTION system.synchronize_all_serials()
	RETURNS void AS
$BODY$
DECLARE
	sequences record;
	sql text;
BEGIN
	FOR sequences IN
		SELECT
			seqs.sequence_schema || '.' || seqs.sequence_name AS sequence_name,
			cols.table_schema || '.' || cols.table_name::text AS table_name,
			cols.column_name::text

			FROM information_schema.columns AS cols
				INNER JOIN information_schema.sequences AS seqs
					ON ( (cols.table_schema || '.' || cols.table_name || '_' || cols.column_name || '_seq') = (seqs.sequence_schema || '.' || seqs.sequence_name) )
	LOOP
		sql := 'SELECT SETVAL(''' || sequences.sequence_name || ''', (SELECT COALESCE(MAX(' || sequences.column_name || '), 0) FROM ' || sequences.table_name || ') + 1, false)';
		RAISE NOTICE '%', sql;
		EXECUTE sql;
	END LOOP;
END;
$BODY$
LANGUAGE plpgsql VOLATILE;


/*
 * cluster_all_tables
 * ------------------
 * Function to cluster all tables in the database based on their primary key.
 * Once the constraint (in this case the primary key) has been set, in the future clustering can be done by using: CLUSTER databasename.
 */
CREATE OR REPLACE FUNCTION system.cluster_all_tables()
	RETURNS void AS
$BODY$
DECLARE
	pkey_constraints record;
	sql text;
BEGIN
	FOR pkey_constraints IN
		SELECT
			(nspname || '.' || relname)::regclass::text AS tablename,
			conname::text AS pkey_name

			FROM pg_constraint
				INNER JOIN pg_class ON (pg_class.oid = pg_constraint.conrelid)
				INNER JOIN pg_namespace ON (pg_namespace.oid = pg_class.relnamespace)

			WHERE pg_class.relkind = 'r' AND pg_constraint.contype = 'p' AND pg_class.relisshared IS FALSE AND relname NOT LIKE 'pg_%'

			ORDER BY tablename
	LOOP
		sql := 'CLUSTER ' || pkey_constraints.tablename || ' USING ' || pkey_constraints.pkey_name;
		RAISE NOTICE '%', sql;
		EXECUTE sql;
	END LOOP;
END;
$BODY$
LANGUAGE plpgsql VOLATILE;


/*
 * drop_foreign_keys_before_load
 * -----------------------------
 * Function to drop the foreign keys before the data is loaded, so system.add_foreign_keys_after_load can add them back after the load.
 * While a table is loaded, a foreign key is checked row by row. Adding the key back to the filled table checks all rows in one pass.
 * The dropped keys are stored in system.dropped_foreign_keys. This is a normal table and not a temporary one, because the build script runs each call in a new session.
 * Saving the definitions and dropping the keys are atomic. The table survives a failed load, so the keys can be restored after fixing the data.
 * A failed build is incomplete: the dropped keys remain absent until restoration succeeds or the database is rebuilt.
 * Some foreign keys are left in place:
 * - Keys with CASCADE, SET NULL or SET DEFAULT actions, as the load could rely on those changes to referencing rows.
 * - NOT VALID keys, as adding one back would not check the loaded rows.
 * Copies of a key on each partition are dropped and restored through the parent key.
 *
 * Called during build by ruby build script, when load_data is given :foreign_keys_after_load.
 */
CREATE OR REPLACE FUNCTION system.drop_foreign_keys_before_load()
	RETURNS void AS
$BODY$
DECLARE
	foreign_keys record;
	sql text;
BEGIN
	CREATE TABLE system.dropped_foreign_keys (
		tablename text NOT NULL,
		constraintname text NOT NULL,
		definition text NOT NULL
	);

	INSERT INTO system.dropped_foreign_keys (tablename, constraintname, definition)
		SELECT
			conrelid::regclass::text,
			conname,
			pg_get_constraintdef(oid)

			FROM pg_constraint

			WHERE
				contype = 'f' -- Only foreign keys.
				AND conparentid = 0 -- Partition copies follow their parent constraint.
				AND convalidated -- NOT VALID keys must keep checking new rows during the load.
				AND confupdtype IN ('a', 'r') -- ON UPDATE: NO ACTION or RESTRICT.
				AND confdeltype IN ('a', 'r') -- ON DELETE: NO ACTION or RESTRICT.
	;

	FOR foreign_keys IN
		SELECT
			tablename,
			constraintname

			FROM system.dropped_foreign_keys

			ORDER BY tablename, constraintname
	LOOP
		sql := 'ALTER TABLE ' || foreign_keys.tablename || ' DROP CONSTRAINT ' || quote_ident(foreign_keys.constraintname);
		RAISE NOTICE '%', sql;
		EXECUTE sql;
	END LOOP;
END;
$BODY$
LANGUAGE plpgsql VOLATILE
-- Save schema-qualified table names and REFERENCES targets, regardless of the caller's search_path.
SET search_path = pg_catalog;


/*
 * add_foreign_keys_after_load
 * ---------------------------
 * Function to add back the foreign keys that system.drop_foreign_keys_before_load dropped, and to drop system.dropped_foreign_keys.
 * Adding a key checks all rows, so bad data still fails the build, with the usual error that names the table, the key and the value.
 * Restoration and removal of the saved definitions are atomic. If any key fails validation, all definitions remain available for a retry.
 *
 * Called during build by ruby build script, when load_data is given :foreign_keys_after_load.
 */
CREATE OR REPLACE FUNCTION system.add_foreign_keys_after_load()
	RETURNS void AS
$BODY$
DECLARE
	foreign_keys record;
	sql text;
BEGIN
	FOR foreign_keys IN
		SELECT
			tablename,
			constraintname,
			definition

			FROM system.dropped_foreign_keys

			-- Restore partition parents first, so they cannot adopt an independent key on a partition.
			ORDER BY (SELECT COUNT(*) FROM pg_partition_ancestors(tablename::regclass)), tablename, constraintname
	LOOP
		sql := 'ALTER TABLE ' || foreign_keys.tablename || ' ADD CONSTRAINT ' || quote_ident(foreign_keys.constraintname) || ' ' || foreign_keys.definition;
		RAISE NOTICE '%', sql;
		EXECUTE sql;
	END LOOP;

	DROP TABLE system.dropped_foreign_keys;
END;
$BODY$
LANGUAGE plpgsql VOLATILE;
