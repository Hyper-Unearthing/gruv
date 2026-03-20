# frozen_string_literal: true

require 'json'

module AppConfig
  module_function

  def load
    path = config_path
    return {} unless path

    JSON.parse(File.read(path))
  rescue JSON::ParserError
    {}
  end

  def config_path
    candidates.find { |path| File.exist?(path) }
  end

  def candidates
    [
      File.expand_path('../config.json', __dir__),
      File.expand_path('../instance/config.json', __dir__)
    ]
  end
end
