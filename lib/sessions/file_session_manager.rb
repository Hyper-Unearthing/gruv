require 'json'
require 'securerandom'
require 'time'

class FileSessionManager
  attr_reader :session_id, :session_start, :events
  attr_accessor :model

  def initialize(session_id: SecureRandom.uuid, session_start: Time.now.strftime('%Y%m%d_%H%M%S'))
    @session_id = session_id
    @session_start = session_start
    @events = []
  end

  def session_file
    dir = File.expand_path('../../sessions', __dir__)
    Dir.mkdir(dir) unless Dir.exist?(dir)
    File.join(dir, "#{session_start}_#{session_id}.jsonl")
  end

  def on_notify(event)
    return unless event.is_a?(Hash)
    return unless %i[user_message assistant_message].include?(event[:name])

    payload = event[:payload]
    push_entry({ type: 'message', message: payload })
  rescue StandardError
    nil
  end

  def push_entry(entry)
    parent_id = events.length.positive? ? events.last[:id] : nil
    new_entry = { id: SecureRandom.uuid, parent_id:, timestamp: Time.now.iso8601, **entry }
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
                   else
                     File.join(File.expand_path('../../sessions', __dir__), base_name)
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
    message_entries.map { |event| event[:message] }
  end

  def compaction(adapter, messages_to_keep: 2)
    entries = message_entries
    return nil if entries.length <= messages_to_keep

    split_index = entries.length - messages_to_keep
    entries_to_summarise = entries[0...split_index]
    first_kept_entry = entries[split_index]

    result = CompactionPrompt.new(adapter, entries_to_summarise).post
    text_parts = result[:choices]&.dig(0, :content).select { |part| part[:type] == 'text' }
    sumamry = text_parts[0][:text]
    raise 'Compaction Error' if sumamry.empty?

    compaction_entry = {
      type: 'compaction',
      summary: sumamry,
      first_kept_entry_id: first_kept_entry[:id]
    }

    push_entry(compaction_entry)
    compaction_entry
  end

  def assemble_transcript
    compaction_entry = @events.reverse.find { |event| event[:type].to_s == 'compaction' }
    return current_transcript unless compaction_entry

    first_kept_entry_id = compaction_entry[:first_kept_entry_id]
    return current_transcript if first_kept_entry_id.to_s.empty?

    first_kept_index = @events.index { |event| event[:id].to_s == first_kept_entry_id.to_s }
    return current_transcript unless first_kept_index

    kept_messages = @events[first_kept_index..].to_a.filter_map do |event|
      next unless event[:type].to_s == 'message'

      event[:message]
    end

    summary_message = {
      role: 'assistant',
      content: [
        {
          type: 'text',
          text: compaction_entry[:summary].to_s
        }
      ]
    }

    [summary_message, *kept_messages]
  end

  def emit_transcript
    @events.each do |message|
      Events.instance.notify('llm.replay_message', message)
    end
  end

  private

  def message_entries
    @events.select { |event| event[:type].to_s == 'message' }
  end

  def fallback_summary(entries)
    "Compacted #{entries.length} earlier messages."
  end
end
