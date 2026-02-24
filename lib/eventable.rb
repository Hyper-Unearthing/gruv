module Publishable
  def subscribe(listener)
    listeners << listener
  end

  def publish(name, payload)
    event = {
      name: name,
      payload: payload
    }

    listeners.each { |listener| listener.on_notify(event) }
  end

  private

  def listeners
    @listeners ||= []
  end
end
