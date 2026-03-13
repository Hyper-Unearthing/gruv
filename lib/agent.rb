require 'json'
require_relative 'eventable'

class Agent < LlmGateway::Prompt
  include Eventable

  attr_reader :client
  attr_accessor :transcript

  def initialize(client, transcript: [])
    super(client.client.model_key)
    @client = client
    @transcript = transcript
  end

  def prompt
    cloned_history = Marshal.load(Marshal.dump(transcript))
    if (last_content = cloned_history.last&.dig(:content)) && last_content.is_a?(Array) && last_content.last
      last_content.last[:cache_control] = { type: 'ephemeral' }
    end

    cloned_history.map { |message| deep_symbolize_keys(message) }
  end

  def self.tools
    self::TOOLS
  end

  def self.find_tool(name)
    tools.find { |tool| tool.tool_name == name }
  end

  def tools
    self.class.tools.map(&:definition)
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

  def post(&block)
    @client.chat(
      prompt,
      tools: tools,
      system: system_prompt,
      &block
    )
  end

  private

  def send_and_process
    result = post do |event|
      case event[:type]
      when :text_delta, :thinking_delta
        publish(:message_delta, event)
      end
    end

    response = result[:choices][0][:content]
    usage = result[:usage]
    publish_assistant_message(response, usage)
    tool_uses = response.select { |message| message[:type] == 'tool_use' }

    if tool_uses.any?
      tool_results = tool_uses.map do |message|
        result = handle_tool_use(message)

        {
          type: 'tool_result',
          tool_use_id: message[:id],
          content: result
        }
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
    tool_class = self.class.find_tool(message[:name])
    if tool_class
      tool = tool_class.new
      tool.execute(message[:input])
    else
      "Unknown tool: #{message[:name]}"
    end
  rescue StandardError => e
    "Error executing tool: #{e.message}"
  end

  def deep_symbolize_keys(obj)
    case obj
    when Hash
      obj.each_with_object({}) { |(key, value), result| result[key.to_sym] = deep_symbolize_keys(value) }
    when Array
      obj.map { |entry| deep_symbolize_keys(entry) }
    else
      obj
    end
  end
end
