require 'json'
require_relative 'eventable'

class Agent
  include Eventable
  attr_reader :model, :client
  attr_accessor :transcript

  def initialize(prompt_class, model, client)
    @prompt_class = prompt_class
    @model = model
    @client = client
    @transcript = []
  end

  def run(user_input)
    publish_user_input([{ type: 'text', text: user_input }])
    response = send_and_process
    publish(:done, response)
  end

  def continue
    response = send_and_process
    publish(:done, response)
  end

  private

  def send_and_process
    prompt = @prompt_class.new(@model, transcript, @client)
    result = prompt.post do |event|
      case event[:type]
      when :text_delta, :thinking_delta
        publish(:message_delta, event)
      end
    end

    response = result[:choices][0][:content]
    usage = result[:usage]
    publish_assistant_message(response, usage)
    # Collect all tool uses
    tool_uses = response.select { |message| message[:type] == 'tool_use' }

    if tool_uses.any?
      tool_results = tool_uses.map do |message|
        result = handle_tool_use(message)

        tool_result = {
          type: 'tool_result',
          tool_use_id: message[:id],
          content: result
        }

        tool_result
      end
      publish_user_message(tool_results)
      send_and_process
    end

    response
  end

  def publish_assistant_message(content, usage = nil)
    assistant_message = { role: 'assistant', content: content }
    assistant_message[:usage] = usage if usage
    publish(:message, assistant_message)
    transcript.push(assistant_message)
    assistant_message
  end

  def publish_user_input(content)
    user_message = { role: 'user', content: content }
    publish(:user_input, user_message)
    transcript.push(user_message)
    user_message
  end

  def publish_user_message(content)
    user_message = { role: 'user', content: content }
    publish(:message, user_message)
    transcript.push(user_message)
    user_message
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
