# frozen_string_literal: true

require_relative 'websocket'

module CommunicationPlatform
  module Discord
    module Gateway
      class Client
        attr_reader :logger, :websocket

        def initialize(logger)
          @logger = logger
        end

        def connect
          @websocket = Websocket.new(logger)
          websocket.connect do |type, payload|
            method_name = type.downcase
            if respond_to?(method_name, true)
              send(method_name, payload)
            else
              logger.debug("discord_gateway.dispatch.ignored type=#{type}")
            end
          end
        end

        def stop
          websocket&.stop
        end
      end
    end
  end
end
