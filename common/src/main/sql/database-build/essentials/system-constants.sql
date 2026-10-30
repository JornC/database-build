/*
 * constants
 * ---------
 * System table for constants used by the web application.
 */
CREATE TABLE system.constants (
	key text NOT NULL,
	value text NOT NULL,
	description text,
	type text,

	CONSTRAINT constants_pkey PRIMARY KEY (key)
);


/*
 * constant
 * --------
 * Function returning the value of a database or web application constant.
 * When the constant does not exist in the table system.constants, an exception is raised.
 */
CREATE OR REPLACE FUNCTION system.constant(constant_key text)
	RETURNS text AS
$BODY$
DECLARE
	constant_value text;
BEGIN
	SELECT value INTO constant_value FROM system.constants WHERE key = constant_key;
	IF constant_value IS NULL THEN
		RAISE EXCEPTION 'Could not find a system constant value for ''%''!', constant_key;
	END IF;
	RETURN constant_value;
END;
$BODY$
LANGUAGE plpgsql STABLE;


/*
 * set_constant
 * ------------
 * Function to change the value of a web application constant.
 * When the constant does not yet exist in the system.constants table, an exception is raised.
 */
CREATE OR REPLACE FUNCTION system.set_constant(constant_key text, constant_value text)
	RETURNS void AS
$BODY$
BEGIN
	IF NOT EXISTS(SELECT value FROM system.constants WHERE key = constant_key) THEN
		RAISE EXCEPTION 'Could not find a system constant value for ''%''!', constant_key;
	END IF;

	UPDATE system.constants SET value = constant_value WHERE key = constant_key;
END;
$BODY$
LANGUAGE plpgsql VOLATILE;


/*
 * get_git_revision
 * ----------------
 * Function returning the revision value, which is stored as a web application constant.
 */
CREATE OR REPLACE FUNCTION system.get_git_revision()
	RETURNS text AS
$BODY$
	SELECT CASE
	WHEN EXISTS (SELECT 1 FROM system.constants WHERE key = 'CURRENT_GIT_REVISION') THEN
		system.constant('CURRENT_GIT_REVISION')
	WHEN EXISTS (SELECT 1 FROM system.constants WHERE key = 'CURRENT_DATABASE_VERSION') THEN
		reverse(split_part(reverse(system.constant('CURRENT_DATABASE_VERSION')), '_', 1))
	ELSE
		reverse(split_part(reverse(system.constant('CURRENT_DATABASE_NAME')), '_', 1))
	END;
$BODY$
LANGUAGE SQL STABLE;


/**
 * Insert the constant for loggin the load_table actions, default = don't skip.
 */
INSERT INTO system.constants (key, value) VALUES ('SKIP_REGISTER_LOAD_TABLE', 'FALSE');


/*
 * should_skip_register_load_table
 * -------------------------------
 * Function that determines if registering of the table logs should be skipped (TRUE = skip), based on the constant 'SKIP_REGISTER_LOAD_TABLE'.
 * If the constant is not present in the database, the table logs are still registered (skip default = FALSE).
 * Used in the load_table function for registering table log data.
 */
CREATE OR REPLACE FUNCTION system.should_skip_register_load_table()
	RETURNS boolean AS
$BODY$
	SELECT COALESCE((SELECT value FROM system.constants WHERE key = 'SKIP_REGISTER_LOAD_TABLE'), 'FALSE')::boolean
$BODY$
LANGUAGE SQL STABLE;


/*
 * current_build_common_module_repos_view
 * --------------------------------------
 * View that flattens the CURRENT_BUILD_COMMON_MODULE_REPO_HASHES JSON constant
 * into one row per path (expands sql_paths and data_paths arrays).
 */
CREATE OR REPLACE VIEW system.current_build_common_module_repos_view AS
	WITH common_module_repos AS (
		SELECT
			jsonb_array_elements((value::jsonb)->'common_module_repos') AS element

			FROM system.constants

			WHERE
				key = 'CURRENT_BUILD_COMMON_MODULE_REPO_HASHES'
				AND value IS NOT NULL
				AND value != ''
	)
	SELECT
		(element->>'repo_url')::text AS repo_url,
		(element->>'commit_hash')::text AS commit_hash,
		'sql' AS path_type,
		path_elem::text AS path,
		(element->>'had_uncommitted_changes')::boolean AS repo_had_uncommitted_changes

		FROM common_module_repos,
			jsonb_array_elements_text(COALESCE(element->'sql_paths', '[]'::jsonb)) AS path_elem

	UNION ALL

	SELECT
		(element->>'repo_url')::text AS repo_url,
		(element->>'commit_hash')::text AS commit_hash,
		'data' AS path_type,
		path_elem::text AS path,
		(element->>'had_uncommitted_changes')::boolean AS repo_had_uncommitted_changes

		FROM common_module_repos,
			jsonb_array_elements_text(COALESCE(element->'data_paths', '[]'::jsonb)) AS path_elem

	ORDER BY repo_url, commit_hash, path_type DESC, path
;
