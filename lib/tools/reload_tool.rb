# frozen_string_literal: true

class ReloadTool < LlmGateway::Tool
  name 'reload'
  description 'Reload the daemon worker code by sending SIGHUP to the supervisor process. Does not restart the current process directly.'
  input_schema({
    type: 'object',
    properties: {},
    required: []
  })

  def execute(_input)
    supervisor_pid = ENV['GRUV_SUPERVISOR_PID']
    return 'Reload is only available in daemon worker mode.' unless supervisor_pid

    Process.kill('HUP', supervisor_pid.to_i)
    'Reloading my code now. I sent SIGHUP to the supervisor to start a fresh worker.'
  rescue Errno::ESRCH
    'I tried to reload, but the supervisor process was not found.'
  rescue => e
    "I tried to reload, but got an error: #{e.message}"
  end
end
