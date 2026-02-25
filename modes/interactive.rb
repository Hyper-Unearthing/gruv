require_relative '../lib/logging'
require_relative '../lib/log_file_writer'
require_relative '../lib/instance_file_scope'
require_relative '../lib/format_stream'

class InteractiveRunner
  def initialize(agent_session)
    @agent_session = agent_session
    @formatter = Formatter.new
  end

  def run
    log_file_writer = LogFileWriter.new(file_path: InstanceFileScope.path('interactive_logs.jsonl'))
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

  def replay_transcript
    transcript = @agent_session.raw_transcript
    return if transcript.empty?

    transcript.each do |message|
      @formatter.replay_message(message)
    end

    last = transcript.last
    last_role = if last.is_a?(Hash)
                  last[:role] || last['role']
                end
    puts if last_role.to_s == 'assistant'
  end
end
