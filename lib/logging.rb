require 'singleton'
require_relative 'eventable'

class Logging
  include Singleton
  include Eventable

  def notify(name, payload)
    publish({name:, payload:, source_location: source_location_from_caller, timestamp: Time.now.iso8601})
  end

  def publish(event)
    listeners.each { |listener| listener.on_notify(event) }
  end

  def attach(listener)
    subscribe(listener)
  end

  private

  def source_location_from_caller
    root = File.expand_path('..', __dir__)

    location = caller_locations(1, 20)&.find do |loc|
      path = loc.absolute_path || loc.path
      next false if path.nil?

      !path.end_with?('/lib/logging.rb') && !path.end_with?('/lib/eventable.rb')
    end

    return nil unless location

    path = location.absolute_path || location.path
    relative_path = path.start_with?("#{root}/") ? path.delete_prefix("#{root}/") : path

    {
      filepath: relative_path,
      lineno: location.lineno,
      label: location.base_label || location.label
    }
  end
end
