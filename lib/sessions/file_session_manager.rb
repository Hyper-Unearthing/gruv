require 'json'
require 'securerandom'
require 'time'
require 'fileutils'
require_relative '../instance_file_scope'

class FileSessionManager
  attr_reader :session_id, :session_start, :events
  attr_accessor :model

  def initialize(session_id: SecureRandom.uuid, session_start: Time.now.strftime('%Y%m%d_%H%M%S'))
    @session_id = session_id
    @session_start = session_start
    @events = []
  end

  def session_file
    FileUtils.mkdir_p(session_dir)
    File.join(session_dir, "#{session_start}_#{session_id}.jsonl")
  end

  def on_notify(event)
    payload = event[:payload]
    name = event[:name]

    case name
    when :user_input, :message
      push_entry(
        type: 'message',
        usage: message_usage(payload),
        data: {
          role: payload[:role],
          content: payload[:content]
        }
      )
    end
  end

  def push_entry(entry)
    id = SecureRandom.uuid
    parent_id = events.length.positive? ? events.last[:id] : nil
    new_entry = { id: id, parent_id: parent_id, timestamp: Time.now.iso8601, **entry }
    @events << new_entry
    append_message(new_entry)
  end

  def append_message(message)
    File.open(session_file, 'a') do |f|
      f.puts(JSON.generate(message))
    end
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

  def current_transcript
    message_entries.map { |event| event[:data] }
  end

  def compaction(adapter, messages_to_keep: 2)
    entries = message_entries
    return nil if entries.length <= messages_to_keep

    split_index = entries.length - messages_to_keep
    entries_to_summarise = entries[0...split_index]
    first_kept_entry = entries[split_index]

    result = CompactionPrompt.new(adapter, entries_to_summarise).post
    text_parts = result[:choices]&.dig(0, :content).select { |part| part[:type] == 'text' }
    summary = text_parts[0][:text]
    raise 'Compaction Error' if summary.empty?

    compaction_entry = {
      type: 'compaction',
      usage: result[:usage],
      data: {
        summary: summary,
        first_kept_entry_id: first_kept_entry[:id]
      }
    }

    push_entry(compaction_entry)
    compaction_entry
  end

  def assemble_transcript
    compaction_entry = @events.reverse.find { |event| event[:type] == 'compaction' }
    return current_transcript unless compaction_entry

    first_kept_entry_id = compaction_entry[:data][:first_kept_entry_id]
    return current_transcript unless first_kept_entry_id

    first_kept_index = @events.index { |event| event[:id] == first_kept_entry_id }
    return current_transcript unless first_kept_index

    kept_messages = @events[first_kept_index..].to_a.filter_map do |event|
      next unless event[:type] == 'message'

      event[:data]
    end

    summary_message = {
      role: 'assistant',
      content: [
        {
          type: 'text',
          text: compaction_entry[:data][:summary]
        }
      ]
    }

    [summary_message, *kept_messages]
  end

  private

  def message_entries
    @events.select { |event| event[:type] == 'message' }
  end

  def message_usage(message)
    message[:usage]
  end

  def session_dir
    File.join(InstanceFileScope.instance_dir, 'sessions')
  end

end
