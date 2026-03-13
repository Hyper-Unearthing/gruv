require_relative 'compaction_prompt'
require_relative 'logging'

class AgentSession
  attr_reader :agent, :session_manager

  def initialize(agent, session_manager)
    @agent = agent
    @session_manager = session_manager

    @agent.subscribe(@session_manager)
    @agent.transcript = model_input_messages
  end

  def run(message)
    Logging.instance.notify('agent_session.message', { input: message })
    @agent.run(message)
    compact if @session_manager.total_tokens > 20_000
  end

  def continue
    Logging.instance.notify('agent_session.continue', {})
    @agent.continue
    compact if @session_manager.total_tokens > 20000
  end

  def raw_events
    @session_manager.events
  end

  def compact
    session_manager.compaction(@agent.client)
    @agent.transcript = model_input_messages
  end

  def model_input_messages
    @session_manager.build_model_input_messages
  end
end
