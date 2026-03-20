# frozen_string_literal: true

require 'yaml'
require_relative '../lib/inbox'
require_relative '../lib/logging'
require_relative '../lib/console_log_writer'
require_relative '../lib/log_file_writer'
require_relative '../lib/instance_file_scope'
require_relative '../lib/format_stream'
require_relative '../lib/agent'
require_relative '../lib/gruv_agent'
require_relative '../lib/agent_session'
require_relative '../lib/sessions/sql_session_manager'
require_relative '../lib/writer_registry'

# Daemon mode for processing inbox messages
class DaemonMode
  def initialize(client, inbox_path, poll_interval: 1)
    @client = client
    @sessions = {}
    @formatter = Formatter.new
    @inbox = Inbox.new(inbox_path)
    @poll_interval = poll_interval
    @running = false
  end

  def start
    console_log_writer = ConsoleLogWriter.new
    log_file_writer = LogFileWriter.new(file_path: InstanceFileScope.path('daemon_logs.jsonl'), process_name: 'gruv')
    Logging.instance.attach(console_log_writer)
    Logging.instance.attach(log_file_writer)

    @running = true
    Logging.instance.notify('daemon.start', {
      poll_interval: @poll_interval,
    })

    cleaned = @inbox.cleanup_processing_on_startup
    Logging.instance.notify('daemon.startup.cleanup_processing', {
      rows_failed: cleaned,
    })

    trap('INT') do
      Logging.instance.notify('daemon.stop.requested', {
        signal: 'INT',
      })
      @running = false
    end

    trap('TERM') do
      Logging.instance.notify('daemon.stop.requested', {
        signal: 'TERM',
      })
      @running = false
    end

    while @running
      begin
        process_next_message
      rescue => e
        Logging.instance.notify('daemon.error', {
          error: e.message,
          backtrace: e.backtrace,
        })
      end

      sleep @poll_interval if @running
    end

    Logging.instance.notify('daemon.stop', {})
  end

  private

  def process_next_message
    pending_count = @inbox.pending_count
    msg = @inbox.next_pending

    Logging.instance.notify('daemon.poll', {
      pending_count: pending_count,
      found: !msg.nil?,
      next_message_id: msg&.dig(:id)
    })

    return unless msg

    Logging.instance.notify('daemon.message.received', {
      id: msg[:id],
      platform: msg[:platform],
      channel_id: msg[:channel_id],
      timestamp: msg[:timestamp],
      contact: msg[:contact],
      message_text: msg[:message],
    })

    Logging.instance.notify('daemon.message.start', {
      id: msg[:id],
      platform: msg[:platform],
      channel_id: msg[:channel_id]
    })

    begin
      agent_input = build_agent_input(msg)
      session = session_for(msg[:channel_id])

      session.run(agent_input)
      @inbox.mark_processed(msg[:id])

      Logging.instance.notify('daemon.message.complete', {
        id: msg[:id],
      })
    rescue LlmGateway::Errors::BadRequestError => e
      Logging.instance.notify('daemon.message.error', {
        id: msg[:id],
        error: e.message,
        backtrace: e.backtrace,
      })
      notify_processing_error_to_user(msg)
      @inbox.mark_failed(msg[:id], error: e.message)
    rescue LlmGateway::Errors::RateLimitError => e
      Logging.instance.notify('daemon.message.rate_limited', {
        id: msg[:id],
        platform: msg[:platform],
        channel_id: msg[:channel_id],
        error: e.message,
      })
      notify_rate_limit_to_user(msg)

      Logging.instance.notify('daemon.message.error', {
        id: msg[:id],
        error: e.message,
        backtrace: e.backtrace,
      })
      @inbox.mark_failed(msg[:id], error: e.message)
    rescue => e
      Logging.instance.notify('daemon.message.error', {
        id: msg[:id],
        error: e.message,
        backtrace: e.backtrace,
      })
      notify_processing_error_to_user(msg)
      @inbox.mark_failed(msg[:id], error: e.message)
    end
  end

  def session_for(channel_id)
    @client.prompt_cache_key = channel_id if @client.respond_to?(:prompt_cache_key=)
    @sessions[channel_id] ||= begin
      agent = GruvAgent.new(@client)
      agent.subscribe(@formatter)
      AgentSession.new(agent, SqlSessionManager.new(channel_id: channel_id))
    end
  end

  def notify_rate_limit_to_user(msg)
    notify_user_about_failure(
      msg,
      event_prefix: 'daemon.message.rate_limited.notify',
      message: 'I hit a temporary rate limit and could not reply just now. Please try again in a bit.'
    )
  end

  def notify_processing_error_to_user(msg)
    notify_user_about_failure(
      msg,
      event_prefix: 'daemon.message.processing_error.notify',
      message: 'Something went wrong while processing your message, so I could not complete it.'
    )
  end

  def notify_user_about_failure(msg, event_prefix:, message:)
    sender = WriterRegistry.for_platform(msg[:platform])
    unless sender
      Logging.instance.notify("#{event_prefix}.skipped", {
        id: msg[:id],
        platform: msg[:platform],
        reason: 'sender_not_configured'
      })
      return
    end

    sender.send_message(
      channel_id: msg[:channel_id],
      message: message,
      reply_to_message_id: msg[:provider_message_id]
    )

    Logging.instance.notify("#{event_prefix}.sent", {
      id: msg[:id],
      platform: msg[:platform],
      channel_id: msg[:channel_id]
    })
  rescue => e
    Logging.instance.notify("#{event_prefix}.error", {
      id: msg[:id],
      platform: msg[:platform],
      channel_id: msg[:channel_id],
      error: e.message,
    })
  end

  def build_agent_input(msg)
    <<~INPUT.strip
      inbox_row_yaml:
      #{YAML.dump(msg).lines.map { |line| "  #{line}" }.join}

      Instructions:
      - Respond to the user's message.
      - You already have the full inbox row above; do NOT run SQL to look it up.
      - If metadata indicates a photo/voice/etc, you may read it (via stored file path) but do not send media back to the user unless explicitly requested.
      - Reply using the correct tool for the message source/platform.
      - You are running as a local Ruby agent with full tool access (bash, read, write, etc.) regardless of which platform the message came from. Use these tools freely to research, fetch URLs, run code, or gather any information needed to answer the user.
    INPUT
  end
end
