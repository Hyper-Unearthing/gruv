require 'json'
require 'time'
require 'fileutils'
require_relative 'instance_file_scope'

class LogFileWriter
  def initialize(file_path: nil, process_name: nil)
    @file_path = file_path || default_file_path
    @process_name = process_name
    FileUtils.mkdir_p(File.dirname(@file_path))
  end

  def on_notify(event)
    data = event.is_a?(Hash) ? event.dup : { payload: event }
    data[:process] = @process_name unless @process_name.nil? || @process_name.empty?
    data[:pid] = Process.pid

    File.open(@file_path, 'a') { |f| f.puts(JSON.generate(data)) }
  rescue StandardError
    nil
  end

  private

  def default_file_path
    InstanceFileScope.path('logs.jsonl')
  end
end
