module Eventable
  def subscribe(listener)
    listeners << listener
  end

  def publish(name, payload, metadata = {})
    event = {
      name: name,
      payload: payload
    }.merge(metadata)

    listeners.each { |listener| listener.on_notify(event) }
  end

  private

  def listeners
    @listeners ||= []
  end
end

# Backward compatibility with previous name.
Publishable = Eventable
