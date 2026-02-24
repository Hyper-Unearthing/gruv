require_relative '../lib/logging'
require_relative '../lib/log_file_writer'
require_relative '../lib/instance_file_scope'
require_relative '../lib/format_stream'

class MessageMode
  def initialize(agent_session, message)
    @agent_session = agent_session
    @formatter = Formatter.new
    @message = message
  end

  def run
    log_file_writer = LogFileWriter.new(file_path: InstanceFileScope.path('message_logs.jsonl'))
    Logging.instance.attach(log_file_writer)
    @agent_session.agent.subscribe(@formatter)

    @agent_session.run(@message)
  end
end
