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
  attr_reader :in_delta

  def initialize
    @in_delta = false
    @last_role = nil
  end

  def on_notify(event)
    payload = fetch(event, :payload)
    event = payload unless payload.nil?

    role = fetch(event, :role)

    if role
      puts if @in_delta
      @in_delta = false

      contents = Array(fetch(event, :content))

      if role.to_s == 'user'
        puts if @last_role
        display_user_message(contents)
      else
        contents.each do |content|
          display_llm_activity(content)
        end
      end

      @last_role = role.to_s
    else
      display_llm_activity(event)
    end
  rescue StandardError => e
    puts if @in_delta
    @in_delta = false
    puts "#{COLORS[:red]}[formatter error] #{e.message}#{COLORS[:reset]}"
  end

  def display_user_message(contents)
    first = contents.first

    if fetch(first, :type).to_s == 'text'
      puts "> #{fetch(first, :text)}"
      contents.drop(1).each { |content| display_llm_activity(content) }
    else
      print '> '
      puts
      contents.each { |content| display_llm_activity(content) }
    end
  end

  def display_llm_activity(hash)
    type_s = fetch(hash, :type).to_s

    case type_s
    when 'text'
      puts fetch(hash, :text)
    when 'text_delta'
      @in_delta = true
      print fetch(hash, :text)
    when 'thinking_delta'
      @in_delta = true
      print "#{COLORS[:dim]}#{fetch(hash, :thinking)}#{COLORS[:reset]}"
    when 'tool_use'
      puts if @in_delta
      @in_delta = false
      puts
      puts "  #{COLORS[:cyan]}#{COLORS[:bold]}#{fetch(hash, :name)}#{COLORS[:reset]}"
      Array(fetch(hash, :input)).each do |key, value|
        puts "  #{COLORS[:dim]}#{key}: #{value}#{COLORS[:reset]}"
      end
      puts "  #{COLORS[:dim]}id: #{fetch(hash, :id)}#{COLORS[:reset]}"
    when 'tool_result'
      puts if @in_delta
      @in_delta = false
      id = fetch(hash, :tool_use_id)
      id_part = id ? " (#{id})" : ''
      content = fetch(hash, :content).to_s
      puts
      puts "  #{COLORS[:green]}#{COLORS[:bold]}Result#{id_part}#{COLORS[:reset]}"
      content.each_line { |line| puts "  #{line.chomp}" }
    when 'done'
      puts if @in_delta
      @in_delta = false
      puts
    when 'error'
      puts if @in_delta
      @in_delta = false
      puts "#{COLORS[:red]}[error] #{fetch(hash, :message)}#{COLORS[:reset]}"
    else
      puts if @in_delta
      @in_delta = false
      puts "#{COLORS[:dim]}#{hash.inspect}#{COLORS[:reset]}"
    end
  end

  private

  def fetch(hash, key)
    return nil unless hash.is_a?(Hash)

    hash[key] || hash[key.to_s]
  end
end
