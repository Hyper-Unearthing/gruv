require 'json'
require 'securerandom'

class FileSessionManager
  attr_reader :session_id, :session_start, :transcript
  attr_accessor :model

  def initialize(session_id: SecureRandom.uuid, session_start: Time.now.strftime('%Y%m%d_%H%M%S'))
    @session_id = session_id
    @session_start = session_start
    @transcript = []
  end

  def transcript_file
    dir = File.expand_path('../../sessions', __dir__)
    Dir.mkdir(dir) unless Dir.exist?(dir)
    File.join(dir, "#{session_start}_#{session_id}.json")
  end

  def push(message)
    @transcript << message
    write_session
  end

  def truncate(length)
    safe_length = [[length.to_i, 0].max, @transcript.length].min
    @transcript = @transcript.take(safe_length)
    write_session
  end

  def write_session
    transcript_data = {
      model: model,
      messages: @transcript
    }
    File.write(transcript_file, JSON.pretty_generate(transcript_data))
  end

  def self.load_session(file_name)
    base_name = File.basename(file_name)
    match = base_name.match(/\A(\d{8}_\d{6})_(.+)\.json\z/)
    raise ArgumentError, "Invalid session filename: #{file_name}" unless match

    manager = new(session_start: match[1], session_id: match[2])
    manager.load_transcript(file_name)
    manager
  end

  def load_transcript(file_name)
    base_name = File.basename(file_name)
    session_path = if File.absolute_path(file_name) == file_name
                     file_name
                   else
                     File.join(File.expand_path('../../sessions', __dir__), base_name)
                   end

    data = LlmGateway::Utils.deep_symbolize_keys(JSON.parse(File.read(session_path)))

    @transcript = case data
                  when Array
                    data
                  when Hash
                    data['messages'] || data[:messages] || []
                  else
                    raise ArgumentError, "Invalid session file format: expected Array or Hash"
                  end
    self
  end

  def emit_transcript
    @transcript.each do |message|
      Events.instance.notify('llm.replay_message', message)
    end
  end
end
