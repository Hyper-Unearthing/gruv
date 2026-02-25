require 'open3'
require 'securerandom'
require 'tmpdir'
require 'timeout'
require_relative 'tool_utils'

class BashTool < LlmGateway::Tool
  name 'bash'
  description "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to last #{ToolUtils::DEFAULT_MAX_LINES} lines or #{ToolUtils::DEFAULT_MAX_BYTES / 1024}KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds."
  input_schema({
    type: 'object',
    properties: {
      command: { type: 'string', description: 'Bash command to execute' },
      timeout: { type: 'integer', description: 'Timeout in seconds (optional, no default timeout)' }
    },
    required: ['command']
  })

  def execute(input)
    command = input[:command]
    timeout = input[:timeout]

    output = ''
    exit_status = nil

    runner = proc do
      Open3.popen2e(command, chdir: Dir.pwd) do |_stdin, stdout_err, wait_thr|
        output = stdout_err.read.to_s
        exit_status = wait_thr.value.exitstatus
      end
    end

    if timeout && timeout.to_i.positive?
      Timeout.timeout(timeout.to_i, &runner)
    else
      runner.call
    end

    truncation = ToolUtils.truncate_tail(output)
    out = truncation[:content].to_s
    out = '(no output)' if out.empty?

    if truncation[:truncated]
      temp_path = File.join(Dir.tmpdir, "pi-bash-#{SecureRandom.hex(8)}.log")
      File.write(temp_path, output)

      start_line = truncation[:total_lines] - truncation[:output_lines] + 1
      end_line = truncation[:total_lines]

      notice = if truncation[:last_line_partial]
        last_line = output.split("\n", -1).last.to_s
        "[Showing last #{ToolUtils.format_size(truncation[:output_bytes])} of line #{end_line} (line is #{ToolUtils.format_size(last_line.bytesize)}). Full output: #{temp_path}]"
      elsif truncation[:truncated_by] == 'lines'
        "[Showing lines #{start_line}-#{end_line} of #{truncation[:total_lines]}. Full output: #{temp_path}]"
      else
        "[Showing lines #{start_line}-#{end_line} of #{truncation[:total_lines]} (#{ToolUtils.format_size(ToolUtils::DEFAULT_MAX_BYTES)} limit). Full output: #{temp_path}]"
      end

      out = "#{out}\n\n#{notice}"
    end

    out = "#{out}\n\nCommand exited with code #{exit_status}" if exit_status && exit_status != 0
    out
  rescue Timeout::Error
    "Command timed out after #{timeout} seconds"
  rescue StandardError => e
    "Error executing command: #{e.message}"
  end
end
