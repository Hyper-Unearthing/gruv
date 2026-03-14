# frozen_string_literal: true

class ConsoleLogWriter
  def on_notify(event)
    return unless event.is_a?(Hash)

    name = event[:name].to_s
    return if name == 'daemon.poll'
    payload = event[:payload]

    details = payload.is_a?(Hash) ? payload.dup : nil
    message = if details && !details[:message].to_s.empty?
                details.delete(:message).to_s
              elsif details
                ''
              elsif payload.nil?
                ''
              else
                payload.inspect
              end

    suffix = if details.is_a?(Hash) && !details.empty?
               " #{details.inspect}"
             else
               ''
             end

    io = name.include?('.error') ? $stderr : $stdout
    if message.empty?
      io.puts("[#{name}]#{suffix}")
    else
      io.puts("[#{name}] #{message}#{suffix}")
    end
  rescue StandardError
    nil
  end
end
