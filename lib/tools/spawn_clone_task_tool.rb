# frozen_string_literal: true

require 'json'
require 'rbconfig'
require 'securerandom'
require 'time'
require 'fileutils'
require_relative '../database_config'
require_relative '../clone_task'
require_relative '../instance_file_scope'
require_relative '../runtime_config'

class SpawnCloneTaskTool < LlmGateway::Tool
  name 'spawn_clone_task'
  description 'Spawn a background clone task that runs Gruv on a provided feature message and reports completion into the inbox.'
  input_schema({
    type: 'object',
    properties: {
      message: { type: 'string', description: 'Feature request/instruction the clone agent should execute.' },
      origin_inbox_message_id: { type: 'integer', description: 'Inbox message id that caused the feature task to be spawned.' },
      provider: { type: 'string', description: 'Optional provider key override.' }
    },
    required: ['message', 'origin_inbox_message_id']
  })

  def execute(input)
    message = input[:message]
    origin_inbox_message_id = input[:origin_inbox_message_id]
    provider = input[:provider]

    provider = nil if provider&.strip == ''

    resolved_provider = provider || RuntimeConfig.provider_name

    return JSON.generate({ ok: false, error: 'Missing message' }) if message.nil? || message.strip.empty?
    return JSON.generate({ ok: false, error: 'Missing origin_inbox_message_id' }) if origin_inbox_message_id.nil?

    DatabaseConfig.establish_connection!

    timestamp = Time.now.utc
    task_token = "#{timestamp.strftime('%Y%m%d_%H%M%S')}_#{SecureRandom.hex(4)}"
    session_id = "clone_task_#{task_token}"
    session_start = timestamp.strftime('%Y%m%d_%H%M%S')
    session_path = File.join(InstanceFileScope.instance_dir, 'sessions', "#{session_start}_#{session_id}.jsonl")
    log_path = File.join(InstanceFileScope.instance_dir, 'clone_logs', "#{task_token}.jsonl")

    FileUtils.mkdir_p(File.dirname(session_path))
    FileUtils.mkdir_p(File.dirname(log_path))

    task = CloneTask.create!({
      state: 'queued',
      message: message,
      origin_inbox_message_id: origin_inbox_message_id,
      session_id: session_id,
      session_start: session_start,
      session_path: session_path,
      log_path: log_path
    })

    command = [
      'bundle',
      'exec',
      RbConfig.ruby,
      File.expand_path('../../scripts/clone_task_worker.rb', __dir__),
      '--task-id',
      "#{task.id}"
    ]

    command += ['--provider', resolved_provider] if resolved_provider

    pid = Process.spawn(*command, chdir: File.expand_path('../..', __dir__))
    Process.detach(pid)

    task.update!({
      pid: pid,
      state: 'processing',
      started_at: Time.now.utc.iso8601
    })

    JSON.generate({
      ok: true,
      task_id: task.id,
      pid: pid,
      state: task.state,
      provider: resolved_provider,
      session_path: task.session_path,
      log_path: task.log_path
    })
  rescue => e
    JSON.generate({ ok: false, error: e.message })
  end
end
