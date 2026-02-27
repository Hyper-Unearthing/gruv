# frozen_string_literal: true

require_relative 'session'
require_relative 'async_connection'
require_relative 'errors'

module CommunicationPlatform
  module Discord
    module Gateway
      class Websocket
        attr_reader :logger, :session, :retry_connection
        attr_accessor :connection, :running

        def initialize(logger, retry_connection: true)
          @logger = logger
          @session = Session.new
          @retry_connection = retry_connection
          @running = false
        end

        def connect(&block)
          raise ArgumentError, 'Block required for gateway dispatch handling' unless block_given?

          if retry_connection
            connect_with_retry(&block)
          else
            self.connection = AsyncConnection.new(logger, session)
            connection.connect(&block)
            disconnect
          end
        end

        def stop
          @running = false
          disconnect
        end

        def disconnect
          connection&.disconnect
        end

        private

        def connect_with_retry(&block)
          @running = true

          while @running
            begin
              if session.resumable?
                logger.info('discord_gateway.resume.attempt')
                self.connection ||= AsyncConnection.new(logger, session)
                connection.resume(&block)
              else
                logger.info('discord_gateway.connect.new_session')
                self.connection = AsyncConnection.new(logger, session)
                connection.connect(&block)
              end
            rescue Errors::ConnectionClosed => e
              logger.warn("discord_gateway.reconnect reason=#{e.message}")
            rescue Errors::InvalidSession => e
              logger.warn("discord_gateway.invalid_session reason=#{e.message}")
              session.reset
              disconnect
              self.connection = nil
            rescue => e
              logger.error("discord_gateway.error error=#{e.message}")
              disconnect
              self.connection = nil
            end

            sleep 1 if @running
          end
        end
      end
    end
  end
end
