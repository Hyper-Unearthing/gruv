#!/usr/bin/env ruby
# frozen_string_literal: true

require 'active_record'
require 'active_support/core_ext/string/inflections'
require 'fileutils'
require 'logger'
require_relative 'lib/database_config'
require_relative 'lib/database_migrations'

MIGRATIONS_PATH = DatabaseMigrations::MIGRATIONS_PATH

DatabaseMigrations.ensure_paths!

ActiveRecord::Base.logger = Logger.new($stdout) if ENV['DB_LOG']

DatabaseConfig.establish_connection!

def migration_context
  DatabaseMigrations.migration_context
end

def usage!
  warn <<~USAGE
    Usage:
      ruby db_tool.rb migrate [VERSION]    # migrate to latest or specific version
      ruby db_tool.rb rollback [STEPS]     # rollback N steps (default: 1)
      ruby db_tool.rb up VERSION           # run one migration up
      ruby db_tool.rb down VERSION         # run one migration down
      ruby db_tool.rb status               # show migration status
      ruby db_tool.rb version              # show current schema version
      ruby db_tool.rb new NAME             # generate new migration file
      ruby db_tool.rb reload               # delete db and re-run all migrations

    Examples:
      ruby db_tool.rb new create_users
      ruby db_tool.rb migrate
      ruby db_tool.rb rollback 1
      DB_LOG=1 ruby db_tool.rb migrate
  USAGE
  exit 1
end

def generate_migration!(name)
  usage! if name.nil? || name.strip.empty?

  timestamp = Time.now.utc.strftime('%Y%m%d%H%M%S')
  file_name = "#{timestamp}_#{name.downcase.gsub(/[^a-z0-9_]/, '_')}.rb"
  class_name = name.split('_').map(&:capitalize).join

  path = File.join(MIGRATIONS_PATH, file_name)
  migration_version = ActiveRecord::Migration.current_version

  File.write(path, <<~RUBY)
    class #{class_name} < ActiveRecord::Migration[#{migration_version}]
      def change
      end
    end
  RUBY

  puts "Created #{path}"
end

ctx = migration_context
command = ARGV[0]
arg = ARGV[1]

case command
when 'migrate'
  target = arg&.to_i
  ctx.migrate(target)
  puts "Migrated. Current version: #{ctx.current_version}"
when 'rollback'
  steps = (arg || 1).to_i
  ctx.rollback(steps)
  puts "Rolled back #{steps} step(s). Current version: #{ctx.current_version}"
when 'up'
  version = Integer(arg)
  ctx.run(:up, version)
  puts "Ran up #{version}. Current version: #{ctx.current_version}"
when 'down'
  version = Integer(arg)
  ctx.run(:down, version)
  puts "Ran down #{version}. Current version: #{ctx.current_version}"
when 'status'
  puts "database: #{DatabaseConfig.db_path}"
  puts "current_version: #{ctx.current_version}"
  puts
  puts ' Status   Version      Name'
  puts '-' * 50
  ctx.migrations_status.each do |status, version, name|
    puts format(' %-7s  %-10s  %s', status, version, name)
  end
when 'version'
  puts ctx.current_version
when 'new'
  generate_migration!(arg)
when 'reload'
  db = DatabaseConfig.db_path
  ActiveRecord::Base.connection_pool.disconnect!
  FileUtils.rm_f(db)
  puts "Deleted #{db}"
  DatabaseConfig.establish_connection!
  migration_context.migrate
  puts "Migrated. Current version: #{migration_context.current_version}"
else
  usage!
end
