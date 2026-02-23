class InteractiveRunner

  def initialize(agent)
    @agent = agent
  end

  def run
    rl = (require 'readline' rescue false)

    # Point Readline at /dev/tty so bracketed paste works even when stdout is piped
    if rl
      tty_in  = File.open('/dev/tty', 'r')
      tty_out = File.open('/dev/tty', 'w')
      Readline.input  = tty_in
      Readline.output = tty_out
    end

    puts "Interactive mode (type 'exit' or 'quit' to end, Ctrl+D to send EOF)"
    puts '---'
    @agent.session_manager.emit_transcript
    puts if @agent.session_manager.transcript.any?
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

      @agent.run(message) do |output|
        Events.instance.notify('llm.message', output)
      end
    end

    puts 'Goodbye!'
  ensure
    if rl
      tty_in&.close
      tty_out&.close
    end
  end
end
