require 'json'
require 'securerandom'
require 'time'
require 'fileutils'
require_relative 'base_session_manager'
require_relative 'concerns/basic_compaction'
require_relative '../instance_file_scope'

class FileSessionManager < BaseSessionManager
  attr_reader :session_path, :file_name

  include BasicCompaction

  def initialize(file_name)
    super()
    @file_name = file_name
  end

  def events
    @events ||= begin
      @session_path = normalize_path(file_name) if file_name
      return load_session(@session_path) if @session_path && File.exist?(@session_path)

      create_new_session
    end
  end

  def normalize_path(file_name)
    if File.dirname(file_name) == '.'
      File.join(session_dir, file_name)
    else
      File.expand_path(file_name)
    end
  end


  private

  def create_new_session
    @session_id = SecureRandom.uuid
    @session_start = Time.now.strftime('%Y%m%d_%H%M%S')

    @session_path ||= File.join(session_dir, "#{session_start}_#{session_id}.jsonl")
    FileUtils.mkdir_p(File.dirname(@session_path))
    File.open(@session_path, 'a') do |f|
      f.puts(JSON.generate([{ type: 'session', id: session_id, timestamp: session_start }]))
    end

    [new_session_event]
  end

  def load_session(session_path)
    events = []
    File.foreach(session_path).with_index(1) do |line, line_number|
      next if line.strip.empty?

      events << JSON.parse(line, symbolize_names: true)
    rescue JSON::ParserError => e
      raise ArgumentError, "Invalid JSONL in #{session_path} at line #{line_number}: #{e.message}"
    end

    events
  end

  def persist_entry(entry)
    super(entry)

    File.open(session_path, 'a') do |f|
      f.puts(JSON.generate(entry))
    end
  end

  def session_dir
    File.join(InstanceFileScope.instance_dir, 'sessions')
  end
end
