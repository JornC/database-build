require 'minitest/autorun'
require 'open3'
require 'shellwords'
require 'securerandom'
require 'json'

# Run against a disposable PostgreSQL server with permission to create databases:
#   ruby test/foreign_keys_after_load_test.rb
# Standard libpq environment variables select the server. PSQL can override the
# client command, for example: PSQL='docker exec -i test-postgres psql -U postgres'.
class ForeignKeysAfterLoadTest < Minitest::Test
  SqlError = Class.new(StandardError)
  MAINTENANCE_SQL = File.read(ENV.fetch('POSTGRES_MAINTENANCE_SQL') {
    File.expand_path('../common/src/main/sql/database-build/essentials/postgres-maintenance.sql', __dir__)
  })

  def setup
    @database = "database_build_fk_test_#{Process.pid}_#{SecureRandom.hex(4)}"
    sql("CREATE DATABASE #{@database}", ENV.fetch('PGDATABASE', 'postgres'))
    @database_created = true
    sql("CREATE SCHEMA system;\n#{MAINTENANCE_SQL}")
  end

  def teardown
    sql("DROP DATABASE #{@database}", ENV.fetch('PGDATABASE', 'postgres')) if @database_created
  end

  def test_round_trip_preserves_definitions_and_keeps_excluded_keys_active
    sql(<<~SQL)
      CREATE TABLE public.parent(id integer PRIMARY KEY);
      INSERT INTO public.parent VALUES (1), (2);
      CREATE TABLE public.child(id integer REFERENCES public.parent(id));
      CREATE TABLE public.self_reference(id integer PRIMARY KEY, parent_id integer REFERENCES public.self_reference(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TABLE public.catalog(id integer PRIMARY KEY) PARTITION BY RANGE(id);
      CREATE TABLE public.catalog_part PARTITION OF public.catalog FOR VALUES FROM (0) TO (100);
      CREATE TABLE public.catalog_child(id integer REFERENCES public.catalog(id));
      CREATE SCHEMA "Quoted Schema";
      CREATE TABLE "Quoted Schema"."child|table"("parent id" integer CONSTRAINT "quoted key" REFERENCES public.parent(id));
      CREATE TABLE public.cascade_child(id integer CONSTRAINT cascade_fk REFERENCES public.parent(id) ON DELETE CASCADE);
      CREATE TABLE public.update_child(id integer CONSTRAINT update_fk REFERENCES public.parent(id) ON UPDATE CASCADE);
      CREATE TABLE public.legacy_child(id integer);
      INSERT INTO public.legacy_child VALUES (900);
      ALTER TABLE public.legacy_child ADD CONSTRAINT legacy_fk FOREIGN KEY(id) REFERENCES public.parent(id) NOT VALID;
    SQL
    before = constraints

    sql('SELECT system.drop_foreign_keys_before_load()')
    assert_equal %w[cascade_fk legacy_fk update_fk], constraints.map { |key| key['constraintname'] }.sort
    assert_raises(SqlError) { sql('INSERT INTO public.legacy_child VALUES (999)') }
    sql(<<~SQL)
      INSERT INTO public.cascade_child VALUES (2);
      DELETE FROM public.parent WHERE id = 2;
      INSERT INTO public.update_child VALUES (1);
      UPDATE public.parent SET id = 3 WHERE id = 1;
      INSERT INTO public.child VALUES (3);
      INSERT INTO public.self_reference VALUES (1, 1);
      INSERT INTO public.catalog VALUES (1);
      INSERT INTO public.catalog_child VALUES (1);
      INSERT INTO "Quoted Schema"."child|table" VALUES (3);
    SQL
    assert_equal '0', sql('SELECT count(*) FROM public.cascade_child')
    assert_equal '3', sql('SELECT id FROM public.update_child')
    sql('SELECT system.add_foreign_keys_after_load()')

    assert_equal before, constraints
    assert_equal 't', sql("SELECT to_regclass('system.dropped_foreign_keys') IS NULL")
    # A second load must capture a fresh set without leaving bookkeeping behind.
    sql('SELECT system.drop_foreign_keys_before_load()')
    sql('SELECT system.add_foreign_keys_after_load()')
    assert_equal before, constraints
  end

  def test_schema_created_during_load_cannot_redirect_restoration
    sql(<<~SQL)
      CREATE TABLE public.parent(id integer PRIMARY KEY);
      CREATE TABLE public.child(id integer REFERENCES public.parent(id));
      INSERT INTO public.parent VALUES (1);
      INSERT INTO public.child VALUES (1);
    SQL
    before = constraints
    result = sql('SET search_path = earlier_schema, public; SELECT system.drop_foreign_keys_before_load(); SHOW search_path;')
    assert_equal 'earlier_schema, public', result
    sql(<<~SQL)
      CREATE SCHEMA earlier_schema;
      CREATE TABLE earlier_schema.parent(id integer PRIMARY KEY);
      CREATE TABLE earlier_schema.child(id integer);
      INSERT INTO public.child VALUES (999);
    SQL

    error = assert_raises(SqlError) do
      sql('SET search_path = earlier_schema, public; SELECT system.add_foreign_keys_after_load()')
    end
    assert_match(/foreign key constraint/, error.message)
    assert_empty constraints
    assert_equal '1', sql('SELECT count(*) FROM system.dropped_foreign_keys')

    sql('DELETE FROM public.child WHERE id = 999')
    sql('SET search_path = earlier_schema, public; SELECT system.add_foreign_keys_after_load()')
    assert_equal before, constraints
    assert_raises(SqlError) { sql('INSERT INTO public.child VALUES (999)') }
  end

  def test_independent_keys_survive_on_nested_partitions
    sql(<<~SQL)
      CREATE TABLE public.target(id integer PRIMARY KEY);
      CREATE TABLE public.z_root(branch integer, id integer, target_id integer,
        CONSTRAINT root_fk FOREIGN KEY(target_id) REFERENCES public.target(id)) PARTITION BY LIST(branch);
      CREATE TABLE public.m_middle PARTITION OF public.z_root FOR VALUES IN (1) PARTITION BY LIST(id);
      CREATE TABLE public.a_leaf PARTITION OF public.m_middle FOR VALUES IN (1);
      ALTER TABLE public.m_middle ADD CONSTRAINT middle_fk FOREIGN KEY(target_id) REFERENCES public.target(id);
      ALTER TABLE public.a_leaf ADD CONSTRAINT leaf_fk FOREIGN KEY(target_id) REFERENCES public.target(id);
      INSERT INTO public.target VALUES (1);
      INSERT INTO public.a_leaf VALUES (1, 1, 1);
    SQL
    before = constraints
    sql('SELECT system.drop_foreign_keys_before_load()')
    sql('SELECT system.add_foreign_keys_after_load()')
    assert_equal before, constraints

    sql('ALTER TABLE public.z_root DROP CONSTRAINT root_fk; ALTER TABLE public.m_middle DROP CONSTRAINT middle_fk;')
    assert_equal ['leaf_fk'], constraints.map { |key| key['constraintname'] }
    assert_raises(SqlError) { sql('INSERT INTO public.a_leaf VALUES (1, 1, 999)') }
  end

  def test_failed_validation_preserves_definitions_and_can_be_retried
    sql(<<~SQL)
      CREATE TABLE public.parent(id integer PRIMARY KEY);
      CREATE TABLE public.a_child(id integer REFERENCES public.parent(id));
      CREATE TABLE public.z_child(id integer REFERENCES public.parent(id));
      INSERT INTO public.parent VALUES (1);
    SQL
    before = constraints
    sql('SELECT system.drop_foreign_keys_before_load()')
    sql('INSERT INTO public.a_child VALUES (1); INSERT INTO public.z_child VALUES (999);')

    assert_raises(SqlError) { sql('SELECT system.add_foreign_keys_after_load()') }
    assert_empty constraints # The successful restoration of a_child was rolled back too.
    assert_equal '2', sql('SELECT count(*) FROM system.dropped_foreign_keys')

    sql('DELETE FROM public.z_child WHERE id = 999')
    sql('SELECT system.add_foreign_keys_after_load()')
    assert_equal before, constraints
    assert_equal 't', sql("SELECT to_regclass('system.dropped_foreign_keys') IS NULL")
  end

  def test_recreated_table_gets_its_constraint_back
    sql('CREATE TABLE public.parent(id integer PRIMARY KEY); CREATE TABLE public.child(id integer REFERENCES public.parent(id));')
    before = constraints
    sql('SELECT system.drop_foreign_keys_before_load()')
    sql('DROP TABLE public.child; CREATE TABLE public.child(id integer);')
    sql('SELECT system.add_foreign_keys_after_load()')
    assert_equal before, constraints
    assert_raises(SqlError) { sql('INSERT INTO public.child VALUES (999)') }
  end

  def test_database_without_foreign_keys
    sql('SELECT system.drop_foreign_keys_before_load()')
    assert_equal '0', sql('SELECT count(*) FROM system.dropped_foreign_keys')
    sql('SELECT system.add_foreign_keys_after_load()')
    assert_equal 't', sql("SELECT to_regclass('system.dropped_foreign_keys') IS NULL")
  end

  private

  def sql(command, database = @database)
    client = Shellwords.split(ENV.fetch('PSQL', 'psql'))
    stdout, stderr, status = Open3.capture3(*client, '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database, stdin_data: command)
    raise SqlError, stderr unless status.success?
    stdout.strip
  end

  def constraints
    JSON.parse(sql(<<~SQL))
      SET search_path = pg_catalog;
      SELECT COALESCE(json_agg(keys ORDER BY tablename, constraintname, referenced_table), '[]') FROM (
        SELECT conrelid::regclass::text AS tablename, conname AS constraintname,
          confrelid::regclass::text AS referenced_table, conparentid <> 0 AS has_parent,
          conislocal, convalidated, pg_get_constraintdef(oid) AS definition
        FROM pg_constraint WHERE contype = 'f'
      ) keys;
    SQL
  end
end
