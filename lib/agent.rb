require 'json'
require_relative 'eventable'

class Agent
  include Publishable
  attr_reader :session_manager, :model

  def initialize(prompt_class, model, client, session_manager)
    @prompt_class = prompt_class
    @model = model
    @client = client
    @session_manager = session_manager
    session_manager.model = model
  end

  def transcript
    @session_manager.transcript
  end

  def run(user_input)
    start_index = @session_manager.transcript.length
    @session_manager.push({ role: 'user', content: [{ type: 'text', text: user_input }] })

    begin
      response = send_and_process()
      publish(:done, response)
    rescue StandardError => e
      @session_manager.truncate(start_index)
      publish(:error, e)
      raise e
    end
  end

  private

  def send_and_process
    prompt = @prompt_class.new(@model, @session_manager.transcript, @client)
    result = prompt.post do |event|
      case event[:type]
      when :text_delta, :thinking_delta
        publish(:message_delta, event)
      end
    end

    response = result[:choices][0][:content]
    usage = result[:usage]
    @session_manager.push({ role: 'assistant', content: response, usage: usage })

    # Collect all tool uses
    tool_uses = response.select { |message| message[:type] == 'tool_use' }

    if tool_uses.any?
      tool_results = tool_uses.map do |message|
        publish(:tool_use, { type: :tool_use, id: message[:id], name: message[:name], input: message[:input] })
        result = handle_tool_use(message)

        tool_result = {
          type: 'tool_result',
          tool_use_id: message[:id],
          content: result
        }

        publish(:tool_result, tool_result)
        tool_result
      end
      @session_manager.push({ role: 'user', content: tool_results })
      send_and_process
    end

    response
  end

  def handle_tool_use(message)
    tool_class = @prompt_class.find_tool(message[:name])
    if tool_class
      tool = tool_class.new
      tool.execute(message[:input])
    else
      "Unknown tool: #{message[:name]}"
    end
  rescue StandardError => e
    "Error executing tool: #{e.message}"
  end
end
