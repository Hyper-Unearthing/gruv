require 'json'
require 'securerandom'
require 'time'
require 'fileutils'
require_relative 'base_session_manager'
require_relative 'concerns/basic_compaction'
require_relative '../instance_file_scope'

class FileSessionManager < BaseSessionManager
  include BasicCompaction
  def initialize(session_id: SecureRandom.uuid, session_start: Time.now.strftime('%Y%m%d_%H%M%S'))
    super(session_id: session_id, session_start: session_start, events: [])
  end

  def session_file
    FileUtils.mkdir_p(session_dir)
    File.join(session_dir, "#{session_start}_#{session_id}.jsonl")
  end

  def self.load_session(file_name)
    base_name = File.basename(file_name)
    match = base_name.match(/\A(\d{8}_\d{6})_(.+)\.jsonl\z/)
    raise ArgumentError, "Invalid session filename: #{file_name}" unless match

    manager = new(session_start: match[1], session_id: match[2])
    manager.load_session(file_name)
    manager
  end

  def load_session(file_name)
    base_name = File.basename(file_name)
    session_path = if File.absolute_path(file_name) == file_name
                     file_name
                   elsif File.exist?(file_name)
                     File.expand_path(file_name)
                   else
                     File.join(session_dir, base_name)
                   end

    @events = []
    File.foreach(session_path).with_index(1) do |line, line_number|
      next if line.strip.empty?

      @events << JSON.parse(line, symbolize_names: true)
    rescue JSON::ParserError => e
      raise ArgumentError, "Invalid JSONL in #{session_path} at line #{line_number}: #{e.message}"
    end

    self
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

    File.open(session_file, 'a') do |f|
      f.puts(JSON.generate(entry))
    end
  end

  def session_dir
    File.join(InstanceFileScope.instance_dir, 'sessions')
  end
end
