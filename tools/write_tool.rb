require 'fileutils'
require_relative 'tool_utils'

class WriteTool < LlmGateway::Tool
  name 'write'
  description 'Write content to a file. Creates the file if it doesn\'t exist, overwrites if it does. Automatically creates parent directories.'
  input_schema({
    type: 'object',
    properties: {
      path: { type: 'string', description: 'Path to the file to write (relative or absolute)' },
      content: { type: 'string', description: 'Content to write to the file' }
    },
    required: ['path', 'content']
  })

  def execute(input)
    path = input[:path] || input['path']
    content = input[:content] || input['content']

    absolute_path = ToolUtils.resolve_to_cwd(path)
    FileUtils.mkdir_p(File.dirname(absolute_path))
    File.write(absolute_path, content.to_s)

    "Successfully wrote #{content.to_s.bytesize} bytes to #{path}"
  rescue StandardError => e
    "Error writing file: #{e.message}"
  end
end
