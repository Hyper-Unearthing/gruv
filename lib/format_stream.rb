COLORS = {
  reset: "\e[0m",
  bold: "\e[1m",
  dim: "\e[2m",
  cyan: "\e[36m",
  green: "\e[32m",
  yellow: "\e[33m",
  red: "\e[31m",
  blue: "\e[34m"
}.freeze

class Formatter

  def replay_message(event)
    contents = event.dig(:content)
    role = event.dig(:role)

    if role.to_s == 'user'
      contents.each do |content|
        if content[:type] == 'text'
          display_user_message(contents)
        else
          display_llm_activity(content)
        end
      end

    else
      contents.each do |content|
        display_llm_activity(content)
      end
    end
  end

  def on_notify(event)
    name = event.dig(:name)
    payload = event.dig(:payload)

    # In interactive mode, user input is already visible on the prompt line.
    return if name == :user_input

    if name == :done
      # Ensure the newline is emitted and flushed immediately at stream end.
      puts("\n\r")
      return
    end

    event = payload unless payload.nil?

    role = event.dig(:role)

    if role
      contents = event.dig(:content)

      if role.to_s == 'user'
        display_user_message(contents)
      else
        contents.each do |content|
          # skip types that were already streamed as deltas
          next if content[:type] == 'text' || content[:type] == 'thinking'
          display_llm_activity(content)
        end
      end

    else
      display_llm_activity(event)
    end
  rescue StandardError => e
    puts "#{COLORS[:red]}[formatter error] #{e.message}#{COLORS[:reset]}"
  end

  def display_user_message(contents)
    contents.each do |entry|
      if entry[:type] == 'text'
        puts "> #{entry.dig(:text)}"
      else
        display_llm_activity(entry)
      end
    end
  end

  def display_llm_activity(hash)
     #text delta is a key
    case hash.dig(:type).to_s
    when 'text'
      puts hash.dig(:text)
    when 'text_delta'
      if @last_type == 'thinking_delta'
        puts
      end
      print hash.dig(:text)
      @last_type = 'text_delta'
    when 'thinking_delta'
      print "#{COLORS[:dim]}#{hash.dig(:thinking)}#{COLORS[:reset]}"
      @last_type = 'thinking_delta'
    when 'thinking'
      thinking = hash.dig(:thinking).to_s
      puts "#{COLORS[:dim]}#{thinking}#{COLORS[:reset]}" unless thinking.empty?
      @last_type = 'thinking'
    when 'tool_use'
      @last_type = 'tool_use'
      puts
      puts "  #{COLORS[:cyan]}#{COLORS[:bold]}#{hash.dig(:name)}#{COLORS[:reset]}"
      hash.dig(:input).each do |key, value|
        puts "  #{COLORS[:dim]}#{key}: #{value}#{COLORS[:reset]}"
      end
      puts "  #{COLORS[:dim]}id: #{hash.dig(:id)}#{COLORS[:reset]}"
    when 'tool_result'
      id = hash.dig(:tool_use_id)
      id_part = id ? " (#{id})" : ''
      content = hash.dig(:content).to_s
      puts
      puts "  #{COLORS[:green]}#{COLORS[:bold]}Result#{id_part}#{COLORS[:reset]}"
      content.each_line { |line| puts "  #{line.chomp}" }
    when 'done'
      puts
    when 'error'
      puts "#{COLORS[:red]}[error] #{hash.dig(:message)}#{COLORS[:reset]}"
    else
      puts "#{COLORS[:dim]}#{hash.inspect}#{COLORS[:reset]}"
    end
  end
end
