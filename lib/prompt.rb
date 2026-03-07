require_relative '../tools'

class Prompt < LlmGateway::Prompt
  TOOL_CLASSES = ObjectSpace.each_object(Class)
    .select { |klass| klass < LlmGateway::Tool }
    .sort_by(&:name)
    .freeze

  def initialize(transcript, client)
    super(client.client.model_key)
    @transcript = transcript
    @client = client
  end

  def prompt
    cloned_history = Marshal.load(Marshal.dump(@transcript))
    if (last_content = cloned_history.last&.dig(:content)) && last_content.is_a?(Array) && last_content.last
      last_content.last[:cache_control] = { type: 'ephemeral' }
    end
    cloned_history.map { |h| deep_symbolize_keys(h) }
  end

  def system_prompt
    content = File.read(File.join(__dir__, '..', 'system_prompt.md'))
    [{ role: 'system', content: content, cache_control: { 'type': 'ephemeral' } }]
  end

  def self.tools
    TOOL_CLASSES
  end

  def tools
    self.class.tools.map(&:definition)
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

  def deep_symbolize_keys(obj)
    case obj
    when Hash
      obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize_keys(v) }
    when Array
      obj.map { |e| deep_symbolize_keys(e) }
    else
      obj
    end
  end
end
