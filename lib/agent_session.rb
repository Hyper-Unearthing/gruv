require_relative 'compaction_prompt'
require_relative 'logging'

class AgentSession
  attr_reader :agent, :session_manager

  def initialize(agent, session_manager)
    @agent = agent
    @session_manager = session_manager

    @agent.subscribe(@session_manager)
    @agent.transcript = compacted_transcript
  end

  def run(message)
    Logging.instance.notify('agent_session.message', { input: message })
    @agent.run(message)
    compact if @session_manager.total_tokens > 20000
  end

  def raw_transcript
    @session_manager.current_transcript || []
  end

  def compact
    session_manager.compaction(@agent.client)
    @agent.transcript = compacted_transcript
  end

  def compacted_transcript
    @session_manager.assemble_transcript
  end
end
