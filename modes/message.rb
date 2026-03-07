require_relative '../lib/logging'
require_relative '../lib/log_file_writer'
require_relative '../lib/instance_file_scope'
require_relative '../lib/format_stream'
require_relative '../lib/agent'
require_relative '../lib/agent_session'
require_relative '../lib/prompt'
require_relative '../lib/sessions/file_session_manager'

class MessageMode
  def initialize(client, session_file, message)
    @agent_session = build_session(client, session_file)
    @formatter = Formatter.new
    @message = message
  end

  def run
    log_file_writer = LogFileWriter.new(file_path: InstanceFileScope.path('message_logs.jsonl'))
    Logging.instance.attach(log_file_writer)
    @agent_session.agent.subscribe(@formatter)

    @agent_session.run(@message)
  end

  private

  def build_session(client, session_file)
    agent = Agent.new(Prompt, client)
    AgentSession.new(agent, FileSessionManager.new(session_file))
  end
end
