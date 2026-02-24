require 'singleton'

class Events
  include Singleton

  attr_reader :listeners

  def initialize
    @listeners = []
  end

  def notify(name, payload)
    event = {
      name: name,
      payload: payload
    }

    listeners.each { |listener| listener.on_notify(event) }
  end

  def attach(listener)
    listeners << listener
  end
end
