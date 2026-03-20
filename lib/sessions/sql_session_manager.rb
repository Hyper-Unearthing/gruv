require 'json'
require 'active_record'
require_relative 'base_session_manager'
require_relative '../database_config'

class SqlSessionManager < BaseSessionManager
  SESSION_START = 'continuous'.freeze

  def initialize(channel_id:)
    super()
    @session_id = channel_id
    @session_start = SESSION_START

    DatabaseConfig.establish_connection!
  end

  def events
    @events ||= load_events
  end

  private

  def load_events
    sql = <<~SQL
      SELECT event_id, parent_id, timestamp, event_type, usage_json, data_json
      FROM session_events
      WHERE session_id = ? AND session_start = ?
      ORDER BY position ASC
    SQL

    rows = execute_sql(sql, @session_id, @session_start) { |result| result.to_a }

    rows.map do |row|
      {
        id: row['event_id'],
        parent_id: row['parent_id'],
        timestamp: row['timestamp'],
        type: row['event_type'],
        usage: parse_json(row['usage_json']),
        data: parse_json(row['data_json'])
      }
    end
  end

  def persist_entry(entry)
    super(entry)

    sql = <<~SQL
      INSERT INTO session_events (
        session_id,
        session_start,
        position,
        event_id,
        parent_id,
        timestamp,
        event_type,
        usage_json,
        data_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL

    execute_sql(
      sql,
      @session_id,
      @session_start,
      events.length,
      entry[:id],
      entry[:parent_id],
      entry[:timestamp],
      entry[:type],
      entry[:usage] ? JSON.generate(entry[:usage]) : nil,
      JSON.generate(entry[:data])
    ) { nil }
  end

  def execute_sql(sql, *params)
    db = ActiveRecord::Base.connection.raw_connection
    statement = db.prepare(sql)
    result = statement.execute(*params)
    yield result
  ensure
    begin
      result&.close if result.respond_to?(:close)
    rescue StandardError
      nil
    end

    begin
      statement&.close
    rescue StandardError
      nil
    end
  end

  def parse_json(value)
    return nil if value.nil?

    JSON.parse(value, symbolize_names: true)
  end
end
