# frozen_string_literal: true

module CommunicationPlatform
  module Discord
    module Gateway
      module Errors
        class ConnectionClosed < StandardError; end
        class InvalidSession < StandardError; end
        class OpcodeOrderError < StandardError; end
        class PacketInvalidFormatError < StandardError; end
      end
    end
  end
end
