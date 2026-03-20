# frozen_string_literal: true

module CommunicationPlatform
  module Concerns
    module Sender
      def send_message(channel_id:, message:, **_opts)
        raise NotImplementedError, "#{self.class} must implement #send_message"
      end

      def send_photo(channel_id:, photo_input:, **_opts)
        raise NotImplementedError, "#{self.class} must implement #send_photo"
      end

      def send_voice(channel_id:, voice_input:, **_opts)
        raise NotImplementedError, "#{self.class} must implement #send_voice"
      end

      def get_me
        raise NotImplementedError, "#{self.class} must implement #get_me"
      end
    end
  end
end
