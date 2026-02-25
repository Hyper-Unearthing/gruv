require_relative 'tool_utils'

class EditTool < LlmGateway::Tool
  name 'edit'
  description 'Edit a file by replacing exact text. The oldText must match exactly (including whitespace). Use this for precise, surgical edits.'
  input_schema({
    type: 'object',
    properties: {
      path: { type: 'string', description: 'Path to the file to edit (relative or absolute)' },
      oldText: { type: 'string', description: 'Exact text to find and replace (must match exactly)' },
      newText: { type: 'string', description: 'New text to replace the old text with' }
    },
    required: ['path', 'oldText', 'newText']
  })

  def execute(input)
    path = input[:path] || input['path']
    old_text = input[:oldText] || input['oldText']
    new_text = input[:newText] || input['newText']

    absolute_path = ToolUtils.resolve_to_cwd(path)

    return "File not found: #{path}" unless File.exist?(absolute_path)
    return "Cannot edit directory: #{path}" if File.directory?(absolute_path)
    return "File is not writable: #{path}" unless File.writable?(absolute_path)

    raw_content = File.binread(absolute_path)

    bom = raw_content.start_with?("\xEF\xBB\xBF".b) ? "\xEF\xBB\xBF".b : ''.b
    content_without_bom = bom.empty? ? raw_content : raw_content.byteslice(3..)
    content_utf8 = content_without_bom.force_encoding('UTF-8')

    original_ending = content_utf8.include?("\r\n") ? "\r\n" : "\n"
    normalized_content = content_utf8.gsub("\r\n", "\n")
    normalized_old = old_text.to_s.gsub("\r\n", "\n")
    normalized_new = new_text.to_s.gsub("\r\n", "\n")

    return "Could not find the exact text in #{path}. The old text must match exactly including all whitespace and newlines." unless normalized_content.include?(normalized_old)

    occurrences = normalized_content.scan(Regexp.new(Regexp.escape(normalized_old))).length
    if occurrences > 1
      return "Found #{occurrences} occurrences of the text in #{path}. The text must be unique. Please provide more context to make it unique."
    end

    new_content = normalized_content.sub(normalized_old, normalized_new)
    return "No changes made to #{path}. The replacement produced identical content." if new_content == normalized_content

    restored = original_ending == "\r\n" ? new_content.gsub("\n", "\r\n") : new_content
    final_bytes = bom + restored.encode('UTF-8')

    File.binwrite(absolute_path, final_bytes)
    "Successfully replaced text in #{path}."
  rescue StandardError => e
    "Error editing file: #{e.message}"
  end
end
