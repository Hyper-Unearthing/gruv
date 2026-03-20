# frozen_string_literal: true

require_relative 'app_config'

module WriterRegistry
  module_function

  def register(role, mode_class)
    entries[role] = mode_class
  end

  def register_if_configured(role, mode_class, config_key:)
    config = AppConfig.load
    return unless config.key?(config_key)

    register(role, mode_class)
  end

  def resolve(role)
    entries[role]
  end

  def for_platform(platform_key)
    klass = entries[platform_key]
    return nil unless klass

    klass.sender
  end

  def roles
    entries.keys
  end

  def entries
    @entries ||= {}
  end
end
