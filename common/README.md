# Common database modules
Below you will find a brief description of the general database modules. More information about the actual implementation can be found in the SQL-files.

## essentials
The bare essential functionality for building the database.

`load_data :foreign_keys_after_load` temporarily drops validated foreign keys with `NO ACTION` or `RESTRICT` update and delete rules, then restores and validates them after loading. Cascading actions and `NOT VALID` keys remain active. Partition copies follow their parent constraint; parents are restored before independent keys on their partitions.

The definitions are kept in `system.dropped_foreign_keys` because each build command uses a separate PostgreSQL session. Saving the definitions and dropping the keys happen in one transaction. Restoring the keys and removing the saved definitions happen in another. If loading or validation fails, the build fails and the table remains available for recovery; the database is incomplete and must not be used as a successful build. After correcting the data, `SELECT system.add_foreign_keys_after_load();` retries restoration, or the database can be rebuilt.

The option requires the essentials module and is intended for a fresh database build. Load scripts must not rely on the dropped keys being present, including `DROP CONSTRAINT`, `COMMENT ON CONSTRAINT`, or foreign-key dependencies used by `TRUNCATE ... CASCADE` and `DROP ... CASCADE`.

Regression tests: run `ruby test/foreign_keys_after_load_test.rb` from the repository root against a disposable PostgreSQL 15 or 17 server. The test user needs permission to create databases. Standard libpq environment variables select the server; `PSQL` can override the client command. Each test creates and removes its own database.

## validations
The extended validation functionality. If you want to implement validations you will need this module as well.

## toolbox
Common toolbox.

## asserts
Set of assertion functions.

## types
Set of custom data types. Unlike the other modules, this module will be added to the public schema.
