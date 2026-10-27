require 'PostgresTools.rb'
require 'CommentCollector.rb'
require 'CommentMerger.rb'
require 'DataSourceCollector.rb'
require 'GitUtility.rb'
require 'CommonModulesUtility.rb'

##
# Here are the implementations of all the methods that can be called from the user script.
# (Only the public methods can actually be called.)
#
class ScriptCommands

  def has_build_flag(*flag)
    return !flag.empty? && flag.all? { |f| $build_flags.include?(f.to_s.downcase.to_sym) }
  end

  def has_any_build_flag(*flag)
    return !flag.empty? && flag.any? { |f| $build_flags.include?(f.to_s.downcase.to_sym) }
  end

  def set_database_name(database_name)
    database_name = database_name.to_s
    database_name = database_name.gsub('#', Utility.get_svn_head_revision) if database_name.include?('#') && $vcs == :svn
    database_name = database_name.gsub('#', GitUtility.get_git_short_hash_for_path($product_sql_path)) if database_name.include?('#') && $vcs == :git
    $database_name = database_name
    $logger.writeln "Database name = #{$database_name}"
  end

  def ensure_database_name
    raise "Use --database-name to supply a database name, or --version" if $database_name.nil?
  end

  def get_database_name
    ensure_database_name
    return $database_name
  end

  def default_database_name(database_name)
    set_database_name(database_name) if $database_name.nil?
  end

  def set_version(version)
    version = version.to_s
    version = version.gsub('#', Utility.get_svn_head_revision) if version.include?('#') && $vcs == :svn
    version = version.gsub('#', GitUtility.get_git_short_hash_for_path($product_sql_path)) if version.include?('#') && $vcs == :git
    $version = version
    $logger.writeln "Version = #{$version}"
    set_database_name($database_name_prefix + '-' + $product.to_s + '-' + $version) if $database_name.nil?
  end

  def ensure_version
    if $version.nil? && !$database_name.nil? then
      prefix = $database_name_prefix + '-' + $product.to_s + '-'
      if $database_name.starts_with?(prefix) && $database_name.length > prefix.length then
        set_version($database_name[(prefix.length)..($database_name.length-1)])
      end
    end
    raise "Use --version to supply a version" if $version.nil?
  end

  def get_version
    ensure_version
    return $version
  end

  def get_database_build_version()
    version_file = File.join(File.dirname($0), "/../VERSION").fix_filename;
    
    if !File.exist?(version_file) then
      raise "Could not find database-build VERSION."
    end
    
    return File.read(version_file).strip
  end

  def set_dbdata_path(dbdata_path)
    $dbdata_path = File.expand_path(dbdata_path.to_s).fix_pathname
    raise "Cannot find table data file path: #{$dbdata_path}" unless File.exist?($dbdata_path) && File.directory?($dbdata_path)
    $logger.writeln "Table data file path = #{$dbdata_path}"
  end

  def drop_database_if_exists(*params)
    params.each{ |param|
      if param == :aggressive then
        terminate_connections # We may be dropping the database from an 'ensure' block caused by only one of multiple running threads. So make sure the other threads stop.
      else
        $logger.error "Unknown parameter given to drop_database_if_exists()"
      end
    }

    ensure_database_name
    $logger.writeln "Dropping database #{$database_name} if it exists..."
    PostgresTools.execute_external_sql_command("DROP DATABASE IF EXISTS \"#{$database_name}\"")
  end

  def create_database(*params)
    update_database_comment = true
    params.each{ |param|
      if param == :overwrite_existing then
        drop_database_if_exists
      elsif param == :dont_update_comment then
        update_database_comment = false
      else
        $logger.error "Unknown parameter given to create_database()"
      end
    }

    ensure_database_name
    $logger.writeln "Creating database #{$database_name}..."
    with = "TEMPLATE \"#{$database_template}\""
    with += " TABLESPACE \"#{$database_tablespace}\"" unless $database_tablespace.empty?
    with += " LC_COLLATE '#{$database_collation}' LC_CTYPE '#{$database_collation}'" unless $database_collation.empty?
    PostgresTools.execute_external_sql_command("CREATE DATABASE \"#{$database_name}\" WITH #{with}")

    if update_database_comment then
      $database_comment = ''
      $database_comment += get_version() + "\n" unless $version.nil?
      $database_comment += "Database created on: #{Time.now.strftime('%A %d %B %Y %H:%M')}"
      comment = $database_comment.gsub('\'', '\'\'')
      PostgresTools.execute_sql_command("COMMENT ON DATABASE \"#{$database_name}\" IS '#{comment}'")
    end
  end

  def clear_log
    $logger.clear
  end

  def import_database_structure(*params)
    ensure_database_name

    $logger.writeln_with_timing("Importing all SQL from '#{$product_sql_path}'...") {

      as_is = false
      if params == [:sql_as_is] then
        as_is = true
      elsif !params.empty? then
        $logger.error "Unknown parameter given to import_database_structure()"
      end

      bullet = Utility.is_ruby_version_below('1.9.0') ? 250.chr : "\u00B7".force_encoding('UTF-8')
      print ' ['
      Dir[$product_sql_path + '**/*.sql'].sort.each { |sql_filename|
        if as_is then
          PostgresTools.execute_sql_file(sql_filename)
        else
          contents = PostgresTools.process_sql_file(sql_filename, $common_sql_paths)
          PostgresTools.execute_sql_command(contents, sql_filename) unless contents.empty?
        end
        print bullet
      }
      print ']'
    }
  end

  def run_sql(sqlfilename, *params)
    ensure_database_name

    filename = nil
    ([$product_data_path] + $common_data_paths).each { |data_path|
      filename = File.expand_path(data_path + sqlfilename).fix_filename
      filename += '.sql' if !File.exist?(filename) && File.exist?(filename + '.sql')
      break if File.exist?(filename)
      filename = nil
    }
    raise "File '#{sqlfilename}' not found in product and common path(s)." if filename.nil?

    $logger.writeln_with_timing("Running SQL file '#{filename}'...") {
      if params == [:sql_as_is] then
        PostgresTools.execute_sql_file(filename)
      elsif !params.empty? then
        $logger.error "Unknown parameter given to run_sql()"
      else
        contents = PostgresTools.process_sql_file(filename, $common_data_paths, $dbdata_path)
        PostgresTools.execute_sql_command_multithread_support(contents, filename) unless contents.empty?
      end
    }
  end

  def run_sql_folder(sqlfoldername)
    ensure_database_name
    foldername = File.expand_path($product_data_path + sqlfoldername).fix_pathname
    raise "Folder '#{foldername}' not found." unless File.exist?(foldername) && File.directory?(foldername)
    raise "Folder '#{foldername}' is not located in the product folder." if foldername[0, $product_data_path.length] != $product_data_path
    $logger.writeln "Running SQL folder '#{foldername}'..."
    Dir[foldername + '**/*.sql'].sort.each { |sql_filename|
      sql_filename = sql_filename[$product_data_path.length..sql_filename.length]
      run_sql(sql_filename)
    }
  end

  def check_datasources
    ensure_datasourcesinfo_collected
    $logger.writeln "Verifying presence of data sources..."
    $datasources.keys.each{ |datasource|
      raise "Data source not found: #{datasource}" unless File.exist?(datasource)
    }
  end

  def load_data(*params)
    foreign_keys_after_load = false
    if params == [:foreign_keys_after_load] then
      foreign_keys_after_load = true
    elsif !params.empty? then
      $logger.error "Unknown parameter given to load_data()"
    end

    foreign_keys = drop_foreign_keys if foreign_keys_after_load
    run_load_script
    add_foreign_keys(foreign_keys) if foreign_keys_after_load
  end

  def run_load_script
    filename = File.expand_path($product_data_path + 'load.rb').fix_filename
    $logger.error "File not found: #{filename}" unless File.exist?(filename)
    stacktrace_filename = Pathname.new(filename).relative_path_from(Pathname.new(File.expand_path(File.dirname(__FILE__))))
    eval(IO.readlines(filename).join, nil, stacktrace_filename.to_s)
  end

  def drop_foreign_keys
    ensure_database_name
    foreign_keys = PostgresTools.fetch_sql_command("SELECT * FROM #{$db_essentials_function_prefix}foreign_key_drop_and_add_statements()")
    $logger.writeln "Dropping #{foreign_keys.size} foreign keys..."
    execute_sql "BEGIN; " + foreign_keys.map { |foreign_key| foreign_key['drop_statement'] + "; " }.join + "COMMIT;"
    return foreign_keys
  end

  def add_foreign_keys(foreign_keys)
    $logger.writeln "Adding #{foreign_keys.size} foreign keys back..."
    execute_sql "BEGIN; " + foreign_keys.map { |foreign_key| foreign_key['add_statement'] + "; " }.join + "COMMIT;"
  end

  def execute_sql(statement)
    $logger.writeln_with_timing("Running SQL command '#{statement}'...", 100) {
      ensure_database_name
      PostgresTools.execute_sql_command(statement)
    }
  end

  def execute_ext_sql(statement)
    $logger.writeln_with_timing("Running external SQL command '#{statement}'...", 100) {
      ensure_database_name
      PostgresTools.execute_external_sql_command(statement)
    }
  end

  def execute_sql_file(sqlfilename)
    run_sql sqlfilename, :sql_as_is
  end

  def reindex_database
    ensure_database_name
    $logger.writeln_with_timing("Re-indexing database #{$database_name}...") {
      PostgresTools.execute_sql_command("REINDEX DATABASE \"#{$database_name}\"")
    }
  end

  def analyze_vacuum_database(*actions)
    ensure_database_name
    if (actions == [:analyze] || actions == [:analyse]) then
      cmd = 'ANALYZE VERBOSE'
    elsif actions.include?(:vacuum) then
      cmd = 'VACUUM'
      cmd += ' FULL' if actions.include?(:full)
      cmd += ' VERBOSE'
      cmd += ' ANALYZE' if (actions.include?(:analyze) || actions.include?(:analyse))
    else
      raise "You need to specify at least :vacuum or :analyze as parameters to analyze_vacuum_database()"
    end
    $logger.writeln_with_timing("Vacuuming/analyzing database #{$database_name}...") {
      PostgresTools.execute_sql_command(cmd)
    }
  end

  def synchronize_serials
    ensure_database_name
    $logger.writeln "Synchronizing all serials..."
    PostgresTools.execute_sql_command("SELECT #{$db_essentials_function_prefix}synchronize_all_serials()");
  end
  alias_method :synchronise_serials, :synchronize_serials

  def ensure_comments_collected
    if !$comments_collected then
      $logger.writeln "Scanning for comments in '#{$product_sql_path}'..."
      root_path = File.expand_path(File.dirname($project_settings_file) + '/../../').fix_pathname
      $comments = CommentCollector.collect($logger, $product_sql_path, $common_sql_paths, root_path)
      $comments_collected = true
    end
  end

  def update_comments
    ensure_database_name
    ensure_comments_collected
    $logger.writeln "Updating comments in #{$database_name}..."
    comments_sql = ''
    $comments.each{ |object, comment_items|
      comment_items.each{ |_, comment_item|
        valid_identifier = comment_item.identifier + comment_item.arguments_nodefault
        comment = comment_item.full_comment.gsub('\'', '\'\'')
        comments_sql += "COMMENT ON #{object} #{valid_identifier} IS '#{comment}';\n"
      }
    }
    PostgresTools.execute_sql_command(comments_sql) unless comments_sql.empty?
  end

  def ensure_datasourcesinfo_collected
    if $datasources.nil? then
      $logger.writeln "Scanning for data sources in '#{$product_data_path}'..."
      $datasources = DataSourceCollector.collect($logger, $product_data_path, $common_data_paths, $dbdata_path)
    end
  end

  def generate_rtf_documentation(filename = '')
    require 'RTFWriter.rb'
    ensure_database_name
    ensure_comments_collected
    ensure_datasourcesinfo_collected
    $logger.minor_hint 'generation of RTF documentation is no longer maintained in favor of the superior HTML documentation'
    filename = "#{$database_name} SQL Comments.rtf" if filename.empty?
    filename = File.expand_path($product_output_path + filename).fix_filename
    $logger.writeln "Generating RTF documentation in '#{$product_output_path}'..."
    RTFWriter.create_rtf(filename, $comments, $datasources)
  end

  def generate_html_documentation(filename = '', *params)
    require 'HTMLWriter.rb'
    ensure_database_name
    ensure_comments_collected
    ensure_datasourcesinfo_collected

    comments = $comments
    unless params.include?(:no_merge_with_structure) then
      $logger.writeln "Merging actual database structure of #{$database_name} into parsed comments..."
      comments = CommentMerger.merge_with_database_structure($logger, comments, !params.include?(:no_dependencies))
    end

    filename = "#{$database_name}_sqldocgen.html" if filename.empty?
    filename = File.expand_path($product_output_path + filename).fix_filename
    $logger.writeln "Generating HTML documentation in '#{$product_output_path}'..."
    HTMLWriter.create_html(filename, $database_name, comments, $datasources, !params.include?(:no_dependencies))
  end

  def generate_datasources_json(filename = '')
    require 'json'
    ensure_database_name
    ensure_datasourcesinfo_collected
    filename = "#{$database_name}_datasources.json" if filename.empty?
    filename = File.expand_path($product_output_path + filename).fix_filename
    $logger.writeln "Generating datasources-JSON in '#{$product_output_path}'..."
    datasources = $datasources.reduce({}) { |accum, (filename, tablename)| (accum[tablename] ||= []) << File.basename(filename); accum }
    File.write(filename, JSON.pretty_generate(datasources))
  end

  def run_unit_tests(*params)
    ensure_database_name
    $logger.write "Running unit tests... "
    unittest_count = 0
    unittest_failed = 0
    functions = PostgresTools.fetch_sql_command("SELECT * FROM #{$db_essentials_function_prefix}list_unittest_functions('#{$db_unittest_prefix}')");
    $logger.write 'none found.' if functions.empty?
    $logger.writeln ''
    functions.each{ |function|
      function_name = function['name']
      function_args = function['args']
      if function_args.nil? then
        unittest_count += 1
        function_returns = function['returns']
        $logger.major_hint "#{function_name}() returns \"#{function_returns}\"; should have no return value" if function_returns != 'void'
        rv = PostgresTools.fetch_sql_command("BEGIN; SELECT * FROM #{$db_essentials_function_prefix}execute_unittest('#{function_name}'); ROLLBACK;");
        if rv.empty? then
          $logger.warn "Could not read result from #{function_name}()"
        elsif rv[0].has_key?('errcode') then
          errmessage = rv[0]['message']
          errcontext = rv[0]['context']
          errlinenr = rv[0]['linenr']
          $logger.writeln "FAIL: #{function_name}()"
          $logger.writeln "\t#{errmessage}"
          $logger.writeln "\tat line #{errlinenr}, #{errcontext}" if !errcontext.nil? || !errlinenr.nil?
          unittest_failed += 1
        end
      else
        $logger.warn "#{function_name}() skipped because it takes arguments \"#{function_args}\"; should be no-args"
      end
    }
    if unittest_count > 0 then
      unittest_success_rate = ((unittest_count - unittest_failed) * 100.0 / unittest_count).round
      $logger.writeln "Unit test success rate: #{unittest_count - unittest_failed}/#{unittest_count} (#{unittest_success_rate}%)"
      raise "Build aborted because 'run_unit_tests' was called with parameter ':abort_on_failures'" if unittest_failed > 0 && params.include?(:abort_on_failures)
    end
  end

  def validate_contents(*params)
    ensure_database_name
    $logger.writeln_with_timing("Validating database contents...") {
      PostgresTools.execute_sql_command("\\set VERBOSITY terse \n SELECT #{$db_essentials_function_prefix}validate_all()");
      if params.include?(:abort_on_errors) then
        rs = PostgresTools.fetch_sql_command("SELECT number_of_tests FROM #{$db_essentials_function_prefix}last_validation_run_view WHERE result = 'error'");
        num_errors = rs[0]['number_of_tests'].to_i
        $logger.error "Validation yielded #{num_errors} error(s), please consult the logs and #{$db_essentials_function_prefix}last_validation_logs_view" if num_errors > 0
      end
    }
  end

  def create_summary
    ensure_database_name
    filename = File.expand_path($product_output_path + '{title}_{datesuffix}.csv').fix_filename
    $logger.writeln_with_timing("Creating database summary in '#{$product_output_path}'...") {
      PostgresTools.execute_sql_command("SELECT #{$db_essentials_function_prefix}output_summary_table('#{filename}')");
    }
  end

  def dump_database(*params)
    ensure_database_name
    filepath = nil
    overwrite_existing = false
    update_database_comment = true

    params.each{ |param|
      if param.kind_of?(String) then
        $logger.error "Unknown extra String parameter given to dump_database()" unless filepath.nil?
        filepath = param
      elsif param == :overwrite_existing then
        overwrite_existing = true
      elsif param == :dont_update_comment then
        update_database_comment = false
      else
        $logger.error "Unknown parameter given to dump_database()"
      end
    }

    filepath = $product_output_path if filepath.nil?
    filepath = filepath.fix_pathname
    if $dump_filetitle.nil? then
      $dump_filename = File.expand_path(filepath + $database_name + '.backup').fix_filename
    else
      $dump_filename = File.expand_path(filepath + $dump_filetitle).fix_filename
    end

    $logger.writeln_with_timing("Dumping database to '#{$dump_filename}'...") {
      if File.exist?($dump_filename) then
        if overwrite_existing then
          FileUtils.rm($dump_filename)
          $logger.error "Could not delete: #{$dump_filename}" if File.exist?($dump_filename)
        else
          $logger.error "Database dump already exists: #{$dump_filename}"
        end
      end

      if update_database_comment && !$database_comment.nil? then
        $database_comment += "\nDumpfile: #{File.basename($dump_filename)}"
        comment = $database_comment.gsub('\'', '\'\'')
        PostgresTools.execute_sql_command("COMMENT ON DATABASE \"#{$database_name}\" IS '#{comment}'")
      end

      PostgresTools.dump_database($dump_filename)
    }
  end

  def add_constant(key, value, schema = 'system')
    ensure_database_name
    escaped_value = value.to_s.gsub("'", "''")
    $logger.writeln "Adding constant #{key.to_s} = #{value.to_s}"
    PostgresTools.execute_sql_command("INSERT INTO \"#{schema}\".constants(key, value) VALUES ('#{key.to_s}', '#{escaped_value}')")
  end

  def add_build_constants(schema = 'system')
    require 'etc'
    add_constant 'CURRENT_DATABASE_NAME', get_database_name(), schema
    add_constant 'CURRENT_DATABASE_VERSION', get_version(), schema unless $version.nil?
    add_constant 'CURRENT_DATABASE_PRODUCT', $product.to_s, schema unless $product.nil?
    add_constant 'CURRENT_GIT_REVISION', GitUtility.get_git_short_hash_for_path($product_sql_path), schema if !$vcs.nil? && $vcs == :git
    add_constant 'CURRENT_SVN_REVISION', Utility.get_svn_head_revision, schema if !$vcs.nil? && $vcs == :svn
    add_constant 'CURRENT_DATABASE_BUILD_DATE', Time.now.strftime('%d-%m-%Y %H:%M:%S'), schema
    add_constant 'CURRENT_DATABASE_BUILD_USER', Etc.getlogin, schema rescue nil
    add_constant 'CURRENT_DATABASE_BUILD_NODE', Etc.uname[:nodename], schema rescue nil
    add_constant 'CURRENT_DATABASE_BUILD_VERSION', get_database_build_version(), schema
    add_constant 'CURRENT_BUILD_COMMON_MODULE_REPO_HASHES', CommonModulesUtility.build_repo_hashes($common_sql_paths, $common_data_paths), schema
    add_constant 'CURRENT_BUILD_SCRIPT_HAD_UNCOMMITTED_CHANGES', (CommonModulesUtility.any_had_uncommitted_changes?($product_sql_path, $product_data_path, $common_sql_paths, $common_data_paths) ? 'true' : 'false'), schema
  end

  def cluster_tables
    ensure_database_name
    $logger.writeln "Clustering all tables..."
    PostgresTools.execute_sql_command("SELECT #{$db_essentials_function_prefix}cluster_all_tables()");
  end

  def terminate_connections
    ensure_database_name
    $logger.writeln "Terminating all connections to #{$database_name}..."
    cmd = "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '#{$database_name}' AND pid <> pg_backend_pid()"
    PostgresTools.execute_sql_command(cmd)
  end

  def start_sql_recorder(filename = '')
    ensure_database_name
    filename = "#{$database_name}.sql" if filename.empty?
    $logger.writeln "Starting SQL recording into file '#{filename}'..."
    filename = File.expand_path($product_output_path + filename).fix_filename
    PostgresTools.start_recording(filename)
  end

  def stop_sql_recorder
    PostgresTools.stop_recording
    $logger.writeln "Stopped SQL recording."
  end

  private :ensure_database_name, :ensure_version, :ensure_comments_collected, :ensure_datasourcesinfo_collected, :run_load_script, :drop_foreign_keys, :add_foreign_keys

end
