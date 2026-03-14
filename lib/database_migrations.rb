# frozen_string_literal: true

require 'active_record'
require 'fileutils'
require_relative 'database_config'

module DatabaseMigrations
  module_function

  MIGRATIONS_PATH = File.expand_path('../db/migrate', __dir__)

  def ensure_paths!
    FileUtils.mkdir_p(File.dirname(DatabaseConfig.db_path))
    FileUtils.mkdir_p(MIGRATIONS_PATH)
  end

  def migration_context
    ensure_paths!
    DatabaseConfig.establish_connection!

    pool = ActiveRecord::Base.connection_pool

    schema_migration = if pool.respond_to?(:schema_migration)
      pool.schema_migration
    else
      ActiveRecord::SchemaMigration
    end

    internal_metadata = if pool.respond_to?(:internal_metadata)
      pool.internal_metadata
    end

    args = [MIGRATIONS_PATH, schema_migration]
    args << internal_metadata if internal_metadata

    ActiveRecord::MigrationContext.new(*args)
  end

  def migrate!(target = nil)
    ctx = migration_context
    ctx.migrate(target)
    ctx.current_version
  ensure
    ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
  end
end
