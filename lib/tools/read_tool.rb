require 'base64'
require_relative 'tool_utils'

class ReadTool < LlmGateway::Tool
  name 'read'
  description "Read the contents of a file. Supports text files and images (jpg, png, gif, webp). Images are sent as attachments. For text files, output is truncated to #{ToolUtils::DEFAULT_MAX_LINES} lines or #{ToolUtils::DEFAULT_MAX_BYTES / 1024}KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete."
  input_schema({
    type: 'object',
    properties: {
      path: { type: 'string', description: 'Path to the file to read (relative or absolute)' },
      offset: { type: 'integer', description: 'Line number to start reading from (1-indexed)' },
      limit: { type: 'integer', description: 'Maximum number of lines to read' }
    },
    required: ['path']
  })

  IMAGE_MIME_BY_EXT = {
    '.jpg' => 'image/jpeg',
    '.jpeg' => 'image/jpeg',
    '.png' => 'image/png',
    '.gif' => 'image/gif',
    '.webp' => 'image/webp'
  }.freeze

  def execute(input)
    path = input[:path] || input['path']
    offset = input[:offset] || input['offset']
    limit = input[:limit] || input['limit']

    absolute_path = ToolUtils.resolve_read_path(path)

    return "File not found: #{path}" unless File.exist?(absolute_path)
    return "Cannot read directory: #{path}" if File.directory?(absolute_path)
    return "File is not readable: #{path}" unless File.readable?(absolute_path)

    mime_type = IMAGE_MIME_BY_EXT[File.extname(absolute_path).downcase]
    if mime_type
      data = Base64.strict_encode64(File.binread(absolute_path))
      return [
        { type: 'text', text: "Read image file [#{mime_type}]" },
        { type: 'image', data: data, mimeType: mime_type }
      ]
    end

    content = File.read(absolute_path, mode: 'r:bom|utf-8')
    all_lines = content.split("\n", -1)
    total_file_lines = all_lines.length

    start_line = [0, (offset || 1).to_i - 1].max
    return "Offset #{offset} is beyond end of file (#{all_lines.length} lines total)" if start_line >= all_lines.length

    selected_content = if limit
      end_line = [start_line + limit.to_i, all_lines.length].min
      all_lines[start_line...end_line].join("\n")
    else
      all_lines[start_line..].join("\n")
    end

    truncation = ToolUtils.truncate_head(selected_content)
    start_display = start_line + 1

    if truncation[:first_line_exceeds_limit]
      first_line_size = ToolUtils.format_size(all_lines[start_line].to_s.bytesize)
      return "[Line #{start_display} is #{first_line_size}, exceeds #{ToolUtils.format_size(ToolUtils::DEFAULT_MAX_BYTES)} limit. Use bash: sed -n '#{start_display}p' #{path} | head -c #{ToolUtils::DEFAULT_MAX_BYTES}]"
    end

    output = truncation[:content]

    if truncation[:truncated]
      end_display = start_display + truncation[:output_lines] - 1
      next_offset = end_display + 1
      suffix = if truncation[:truncated_by] == 'lines'
        "[Showing lines #{start_display}-#{end_display} of #{total_file_lines}. Use offset=#{next_offset} to continue.]"
      else
        "[Showing lines #{start_display}-#{end_display} of #{total_file_lines} (#{ToolUtils.format_size(ToolUtils::DEFAULT_MAX_BYTES)} limit). Use offset=#{next_offset} to continue.]"
      end
      output = "#{output}\n\n#{suffix}"
    elsif limit && (start_line + limit.to_i) < all_lines.length
      next_offset = start_line + limit.to_i + 1
      remaining = all_lines.length - (start_line + limit.to_i)
      output = "#{output}\n\n[#{remaining} more lines in file. Use offset=#{next_offset} to continue.]"
    end

    output
  rescue StandardError => e
    "Error reading file: #{e.message}"
  end
end
