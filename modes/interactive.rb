require_relative '../lib/logging'
require_relative '../lib/log_file_writer'
require_relative '../lib/instance_file_scope'
require_relative '../lib/format_stream'
require_relative '../lib/agent'
require_relative '../lib/agent_session'
require_relative '../lib/coding_agent'
require_relative '../lib/sessions/file_session_manager'

class InteractiveRunner
  def initialize(client, session_file)
    @agent_session = build_session(client, session_file)
    @formatter = Formatter.new
  end

  def run
    log_file_writer = LogFileWriter.new(file_path: InstanceFileScope.path('interactive_logs.jsonl'), process_name: 'interactive')
    Logging.instance.attach(log_file_writer)
    @agent_session.agent.subscribe(@formatter)

    rl = begin
      require 'readline'
      true
    rescue LoadError
      false
    end

    tty_in = nil
    tty_out = nil

    # Point Readline at /dev/tty so bracketed paste works even when stdout is piped
    if rl
      tty_in = File.open('/dev/tty', 'r')
      tty_out = File.open('/dev/tty', 'w')
      Readline.input = tty_in
      Readline.output = tty_out
    end

    puts "Interactive mode (type 'exit' or 'quit' to end, Ctrl+D to send EOF)"
    puts "Type 'compaction' to compact old conversation context."
    puts '---'

    replay_transcript

    loop do
      $stdout.flush

      input = if rl
        Readline.readline('> ', true)
      else
        print '> '
        t = File.open('/dev/tty', 'r')
        line = t.gets
        t.close
        line&.chomp
      end

      # Handle EOF (Ctrl+D) or exit commands
      break if input.nil? || input.strip.match?(/^(exit|quit)$/i)

      message = input.strip
      next if message.empty?

      if message.casecmp('compaction').zero?
        @agent_session.compact
        next
      end

      @agent_session.run(message)
    end

    puts 'Goodbye!'
  ensure
    tty_in&.close
    tty_out&.close
  end

  private

  def build_session(client, session_file)
    agent = CodingAgent.new(client)
    AgentSession.new(agent, FileSessionManager.new(session_file))
  end

  def replay_transcript
    messages = @agent_session.model_input_messages
    return if messages.empty?

    messages.each do |message|
      @formatter.replay_message(message)
    end

    last = messages.last
    last_role = if last.is_a?(Hash)
                  last[:role] || last['role']
                end
    puts if last_role.to_s == 'assistant'
  end
end
