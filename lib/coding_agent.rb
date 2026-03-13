require_relative '../tools'
require_relative 'agent'

class CodingAgent < Agent
  TOOLS = [
    BashTool,
    ReadTool,
    WriteTool,
    EditTool,
  ].freeze

  def system_prompt
    content = File.read(File.join(__dir__, 'prompt', 'system-prompt.md'))
    [{ role: 'system', content: content, cache_control: { 'type': 'ephemeral' } }]
  end
end
