# frozen_string_literal: true

require 'rbconfig'
require_relative '../lib/logging'
require_relative '../lib/console_log_writer'
require_relative '../lib/log_file_writer'
require_relative '../lib/instance_file_scope'
require_relative '../lib/writer_registry'
require_relative '../lib/database_migrations'

class DaemonSupervisorMode
  def initialize(poll_interval:, provider: nil, model: nil)
    @poll_interval = poll_interval
    @provider = provider
    @model = model
    @children = {}
    @running = false
  end

  def start
    console_log_writer = ConsoleLogWriter.new
    log_file_writer = LogFileWriter.new(file_path: InstanceFileScope.path('daemon_logs.jsonl'), process_name: 'daemon_supervisor')
    Logging.instance.attach(console_log_writer)
    Logging.instance.attach(log_file_writer)

    Logging.instance.notify('daemon.supervisor.migrations.start', {})
    version = DatabaseMigrations.migrate!
    Logging.instance.notify('daemon.supervisor.migrations.complete', {
      version: version,
    })

    @running = true
    spawn_children

    Logging.instance.notify('daemon.supervisor.start', {
      children: @children,
      poll_interval: @poll_interval,
    })

    trap('INT') { request_stop('INT') }
    trap('TERM') { request_stop('TERM') }

    shutdown_sent = false

    loop do
      break if @children.empty?

      if !@running && !shutdown_sent
        force_shutdown_children
        shutdown_sent = true
      end

      waited = Process.wait2(-1, Process::WNOHANG)
      if waited
        pid, status = waited
        reap_child(pid, status)
        request_stop('child_exit') if @running
      else
        sleep 0.1
      end
    end

    Logging.instance.notify('daemon.supervisor.stop', {})
  end

  private

  def spawn_children
    @children[:daemon_worker] = spawn_daemon_worker

    WriterRegistry.roles.each do |role|
      @children[role.to_sym] = spawn_writer(role)
    end
  end

  def spawn_daemon_worker
    command = [ruby_executable, run_agent_path, *provider_args, '--daemon', '--poll-interval', @poll_interval.to_s]
    Process.spawn({ 'GRUV_ROLE' => 'daemon_worker' }, *command)
  end

  def spawn_writer(role)
    command = [ruby_executable, gruv_path]
    Process.spawn({ 'GRUV_ROLE' => role }, *command)
  end

  def provider_args
    args = []
    args += ['--provider', @provider] if @provider
    args += ['--model', @model] if @model
    args
  end

  def request_stop(signal)
    if @running
      @running = false
      Logging.instance.notify('daemon.supervisor.stop.requested', { signal: signal })
      return
    end

    return unless %w[INT TERM].include?(signal)

    Logging.instance.notify('daemon.supervisor.stop.force_requested', { signal: signal })
    force_shutdown_children
  end

  def shutdown_children(signal)
    @children.each_value do |pid|
      begin
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end

  def force_shutdown_children
    shutdown_children('KILL')
  end

  def reap_child(pid, status)
    role = @children.key(pid)
    return unless role

    Logging.instance.notify('daemon.supervisor.child.exit', {
      role: role,
      pid: pid,
      exitstatus: status.exitstatus,
      signaled: status.signaled?,
      termsig: status.termsig,
    })

    @children.delete(role)
  end

  def ruby_executable
    RbConfig.ruby
  end

  def run_agent_path
    File.expand_path('../run_agent.rb', __dir__)
  end

  def gruv_path
    File.expand_path('../gruv', __dir__)
  end
end
