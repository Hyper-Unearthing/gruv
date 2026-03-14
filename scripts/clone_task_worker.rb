#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'fileutils'
require 'llm_gateway'
require_relative '../lib/database_config'
require_relative '../lib/clone_task'
require_relative '../lib/inbox'
require_relative '../lib/agent'
require_relative '../lib/prompt'
require_relative '../lib/logging'
require_relative '../lib/log_file_writer'
require_relative '../lib/openai_oauth'
require_relative '../lib/anthropic_oauth'
require_relative '../lib/instance_file_scope'
require_relative '../lib/sessions/file_session_manager'
require_relative '../lib/agent_session'
require_relative '../lib/runtime_config'

class CloneTaskWorker
  PROVIDERS_FILE = InstanceFileScope.path('providers.json')

  def initialize
    @options = {
      task_id: nil,
      provider: nil,
      model: nil
    }
  end

  def run
    parse_args
    DatabaseConfig.establish_connection!

    task = CloneTask.find(@options[:task_id])
    task.update!({ pid: Process.pid, state: 'processing', started_at: Time.now.utc.iso8601 })

    attach_task_log_writer(task)
    Logging.instance.notify('clone_task.start', { task_id: task.id, pid: Process.pid })

    agent_session = build_agent_session(task)
    agent_session.run(task.message)

    result_message = extract_last_assistant_text(agent_session.agent.transcript)

    task.update!({
      state: 'completed',
      result_message: result_message,
      error_message: nil,
      completed_at: Time.now.utc.iso8601
    })

    notify_inbox(task: task, success: true, payload: result_message)
    Logging.instance.notify('clone_task.complete', { task_id: task.id })
  rescue => e
    handle_failure(e)
    raise
  end

  private

  def parse_args
    OptionParser.new do |opts|
      opts.banner = 'Usage: clone_task_worker.rb --task-id ID [--provider KEY] [--model NAME]'

      opts.on('--task-id ID', Integer, 'Clone task id') { |value| @options[:task_id] = value }
      opts.on('--provider PROVIDER', 'Provider key override') { |value| @options[:provider] = value }
      opts.on('--model MODEL', 'Model override') { |value| @options[:model] = value }
    end.parse!

    @options[:provider] = nil if @options[:provider]&.strip == ''
    @options[:model] = nil if @options[:model]&.strip == ''

    return if @options[:task_id]

    raise ArgumentError, 'Missing required --task-id'
  end

  def attach_task_log_writer(task)
    FileUtils.mkdir_p(File.dirname(task.log_path))
    Logging.instance.attach(LogFileWriter.new(file_path: task.log_path))
  end

  def build_agent_session(task)
    providers = JSON.parse(File.read(PROVIDERS_FILE))
    provider_name = @options[:provider] || providers.keys.first
    provider_config = providers[provider_name]
    raise "Provider '#{provider_name}' not found in providers.json" unless provider_config

    model = @options[:model] || provider_config['model_key']

    RuntimeConfig.set(provider_name: provider_name)

    configured_entries = providers.map do |name, config|
      resolved_config = config.merge('provider' => name)
      resolved_config['model_key'] = @options[:model] if @options[:model] && name == provider_name
      { name: name, config: resolved_config }
    end

    LlmGateway.reset_configuration!
    LlmGateway.configure(configured_entries)

    client = LlmGateway.configured_clients[provider_name.to_sym]
    raise "Configured client '#{provider_name}' not found" unless client

    session_manager = FileSessionManager.new(session_id: task.session_id, session_start: task.session_start)
    agent = Agent.new(Prompt, client)
    AgentSession.new(agent, session_manager)
  end

  def extract_last_assistant_text(transcript)
    assistant_message = transcript.reverse.find { |entry| entry[:role] == 'assistant' }
    return '' unless assistant_message

    text_blocks = assistant_message[:content].select { |block| block[:type] == 'text' }
    text_blocks.map { |block| block[:text] }.join("\n").strip
  end

  def notify_inbox(task:, success:, payload:)
    inbox = Inbox.new(DatabaseConfig.db_path)
    state = success ? 'completed' : 'failed'
    text = success ?
      "Clone task #{task.id} completed. #{payload}" :
      "Clone task #{task.id} failed. #{payload}"

    inbox.insert_message(
      platform: 'clone',
      channel_id: "origin:#{task.origin_inbox_message_id}",
      scope: 'clone_task',
      message: text,
      metadata: {
        task_id: task.id,
        origin_inbox_message_id: task.origin_inbox_message_id,
        pid: task.pid,
        state: state,
        session_path: task.session_path,
        log_path: task.log_path
      }
    )
  end

  def handle_failure(error)
    return unless @options[:task_id]

    task = CloneTask.find_by(id: @options[:task_id])
    return unless task

    task.update!({
      state: 'failed',
      error_message: error.message,
      completed_at: Time.now.utc.iso8601
    })

    notify_inbox(task: task, success: false, payload: error.message)
    Logging.instance.notify('clone_task.failed', {
      task_id: task.id,
      error: error.message,
      backtrace: error.backtrace
    })
  rescue => _e
    nil
  end
end

CloneTaskWorker.new.run
