require 'json'
require 'securerandom'
require 'time'
require 'fileutils'
require_relative 'base_session_manager'
require_relative 'concerns/basic_compaction'
require_relative '../instance_file_scope'

class FileSessionManager < BaseSessionManager
  attr_reader :session_path

  include BasicCompaction

  def initialize(file_name)
    if file_name
      @session_path = normalize_path(file_name)
      if File.exist?(@session_path)
        super(load_session(@session_path))
      else
        super(nil)
        FileUtils.mkdir_p(File.dirname(@session_path))
        File.open(@session_path, 'a') do |f|
          f.puts(JSON.generate(@events.first))
        end
      end
    else
      super(nil)
      FileUtils.mkdir_p(session_dir)
      @session_path = File.join(session_dir, "#{session_start}_#{session_id}.jsonl")
      File.open(@session_path, 'a') do |f|
        f.puts(JSON.generate(@events.first))
      end
    end
  end

  def normalize_path(file_name)
    if File.dirname(file_name) == '.'
      File.join(session_dir, file_name)
    else
      File.expand_path(file_name)
    end
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

  private

  def fetch_latest_transcript
    compaction_entry = @events.reverse.find { |event| event[:type] == 'compaction' }
    return { messages: current_transcript, compaction_data: nil } unless compaction_entry

    compaction_data = compaction_entry[:data]
    first_kept_entry_id = compaction_data[:first_kept_entry_id]
    return { messages: current_transcript, compaction_data: nil } unless first_kept_entry_id

    first_kept_index = @events.index { |event| event[:id] == first_kept_entry_id }
    return { messages: current_transcript, compaction_data: nil } unless first_kept_index

    kept_messages = @events[first_kept_index..].to_a.filter_map do |event|
      next unless event[:type] == 'message'

      event[:data]
    end

    { messages: kept_messages, compaction_data: compaction_data }
  end

  def message_entries
    @events.select { |event| event[:type] == 'message' }
  end

  def parent_id_for_new_entry
    events.length.positive? ? events.last[:id] : nil
  end

  def persist_entry(entry)
    @events << entry

    File.open(session_path, 'a') do |f|
      f.puts(JSON.generate(entry))
    end
  end

  def session_dir
    File.join(InstanceFileScope.instance_dir, 'sessions')
  end
end
