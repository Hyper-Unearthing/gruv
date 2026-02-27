# frozen_string_literal: true

module CommunicationPlatform
  module Discord
    module Gateway
      class Session
        attr_accessor :session_id, :resume_url, :sequence_number, :bot_user_id

        def initialize
          reset
        end

        def reset
          self.session_id = nil
          self.resume_url = nil
          self.sequence_number = nil
          self.bot_user_id = nil
        end

        def resumable?
          session_id && resume_url && sequence_number
        end
      end
    end
  end
end
