require 'json'
require 'active_record'
require_relative 'tool_utils'
require_relative '../database_config'

class SqlTool < LlmGateway::Tool
  name 'sql'
  description 'Execute SQL using the app ActiveRecord database configuration with full read/write access. Supports single and multi-statement queries.'
  input_schema({
    type: 'object',
    properties: {
      query: { type: 'string', description: 'SQL query to execute (single statement or multiple statements separated by semicolons)' },
      params: {
        type: 'array',
        description: 'Optional positional bind parameters (single-statement queries only)',
        items: {}
      }
    },
    required: ['query']
  })

  def execute(input)
    query = input[:query] || input['query']
    params = input[:params] || input['params'] || []

    return 'Missing required input: query' if query.to_s.strip.empty?
    return 'params must be an array' unless params.is_a?(Array)

    DatabaseConfig.establish_connection!

    connection = ActiveRecord::Base.connection
    raw_db = connection.raw_connection

    statements = split_sql_statements(raw_db, query)
    return 'No executable SQL statements found' if statements.empty?

    if statements.length > 1 && params.any?
      return 'params are only supported for single-statement queries'
    end

    if statements.length == 1
      payload = run_statement(raw_db, statements.first, params)
      payload[:database] = DatabaseConfig.db_path
      return format_with_truncation(payload)
    end

    results = statements.each_with_index.map do |sql, idx|
      run_statement(raw_db, sql, []).merge(index: idx + 1)
    end

    payload = {
      database: DatabaseConfig.db_path,
      statement_count: statements.length,
      results: results
    }

    format_with_truncation(payload)
  rescue ActiveRecord::ConnectionNotEstablished => e
    "SQL error: no ActiveRecord connection configured (#{e.message})"
  rescue ActiveRecord::StatementInvalid => e
    "SQL error: #{e.message}"
  rescue StandardError => e
    "Error executing SQL: #{e.message}"
  end

  private

  def run_statement(raw_db, sql, params)
    statement = nil
    result_set = nil

    statement = raw_db.prepare(sql)
    result_set = statement.execute(*params)
    columns = statement.columns

    if columns.any?
      rows = result_set.to_a
      {
        statement: sql,
        columns: columns,
        row_count: rows.length,
        rows: rows
      }
    else
      {
        statement: sql,
        success: true,
        changes: raw_db.respond_to?(:changes) ? raw_db.changes : nil,
        last_insert_row_id: raw_db.respond_to?(:last_insert_row_id) ? raw_db.last_insert_row_id : nil
      }
    end
  ensure
    begin
      result_set&.close if result_set.respond_to?(:close)
    rescue StandardError
      nil
    end

    begin
      statement&.close
    rescue StandardError
      nil
    end
  end

  def split_sql_statements(raw_db, sql)
    return split_sql_statements_fallback(sql) unless raw_db.respond_to?(:complete?)

    statements = []
    buffer = +''

    sql.each_char do |char|
      buffer << char
      next unless char == ';'
      next unless raw_db.complete?(buffer)

      statement = buffer.strip
      statements << statement unless statement.empty?
      buffer = +''
    end

    remaining = buffer.strip
    statements << remaining unless remaining.empty?

    statements
  end

  def split_sql_statements_fallback(sql)
    statements = []
    buffer = +''
    in_single = false
    in_double = false
    prev = nil

    sql.each_char do |ch|
      if ch == "'" && !in_double && prev != '\\'
        in_single = !in_single
      elsif ch == '"' && !in_single && prev != '\\'
        in_double = !in_double
      end

      if ch == ';' && !in_single && !in_double
        statement = buffer.strip
        statements << statement unless statement.empty?
        buffer = +''
      else
        buffer << ch
      end

      prev = ch
    end

    tail = buffer.strip
    statements << tail unless tail.empty?
    statements
  end

  def format_with_truncation(payload)
    json = JSON.pretty_generate(payload)
    truncation = ToolUtils.truncate_head(json)

    return truncation[:content] unless truncation[:truncated]

    shown_lines = truncation[:output_lines]
    total_lines = truncation[:total_lines]
    suffix = if truncation[:truncated_by] == 'lines'
      "[Showing #{shown_lines} of #{total_lines} lines. Narrow your query (e.g., add LIMIT).]"
    else
      "[Showing #{shown_lines} of #{total_lines} lines (#{ToolUtils.format_size(ToolUtils::DEFAULT_MAX_BYTES)} limit). Narrow your query (e.g., add LIMIT).]"
    end

    "#{truncation[:content]}\n\n#{suffix}"
  end
end
