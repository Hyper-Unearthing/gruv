# frozen_string_literal: true

require 'active_record'
require_relative 'instance_file_scope'

module DatabaseConfig
  module_function

  def db_path
    InstanceFileScope.path('gruv.sqlite3')
  end

  def establish_connection!
    ActiveRecord::Base.establish_connection(
      adapter: 'sqlite3',
      database: db_path,
      timeout: 5000
    )
  end
end
