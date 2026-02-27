# frozen_string_literal: true

module CommunicationPlatform
  module Discord
    module Gateway
      module Opcodes
        module Received
          DISPATCH = 0
          RECONNECT = 7
          INVALIDATE_SESSION = 9
          HELLO = 10
          HEARTBEAT_ACK = 11
        end

        module Sent
          HEARTBEAT = 1
          IDENTIFY = 2
          RESUME = 6
        end
      end
    end
  end
end
