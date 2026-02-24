require 'json'
require 'time'
require 'fileutils'

class LogFileWriter
  def initialize(file_path: nil)
    @file_path = file_path || default_file_path
    FileUtils.mkdir_p(File.dirname(@file_path))
  end

  def on_notify(event)
    File.open(@file_path, 'a') { |f| f.puts(JSON.generate(event)) }
  rescue StandardError
    nil
  end

  private

  def default_file_path
    File.expand_path('../instance/logs.jsonl', __dir__)
  end
end
