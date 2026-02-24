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
    push_entry({ type: 'message', timestamp: Time.now.iso8601, message: payload })
  rescue StandardError
    nil
  end

  def push_entry(entry)
    parent_id = events.length.positive? ? events.last[:id] : nil
    new_entry = { id: SecureRandom.uuid, parent_id:, **entry }
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
    @events.filter_map do |event|
      type = event[:type] || event['type']
      next unless type.to_s == 'message'

      event[:message] || event['message']
    end
  end

  def emit_transcript
    @events.each do |message|
      Events.instance.notify('llm.replay_message', message)
    end
  end
end
