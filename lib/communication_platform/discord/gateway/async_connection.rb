# frozen_string_literal: true

require 'json'
require_relative '../client'
require_relative 'opcodes'
require_relative 'errors'
require_relative 'heartbeat'

module CommunicationPlatform
  module Discord
    module Gateway
      class AsyncConnection
        attr_reader :logger, :session
        attr_accessor :connection, :heartbeat

        def initialize(logger, session)
          @logger = logger
          @session = session
          @heartbeat = Heartbeat.new(self, logger)
          @connection = nil
        end

        def connect(&block)
          self.heartbeat = Heartbeat.new(self, logger)
          gateway_info = CommunicationPlatform::Discord::Client.new.open_gateway
          url = gateway_info[:url]

          open_connection(url) do
            hello_packet = read_packet
            raise Errors::OpcodeOrderError, 'Expected HELLO packet' unless hello_packet[:op] == Opcodes::Received::HELLO

            heartbeat.start(hello_packet[:d][:heartbeat_interval])

            first_ack = read_packet
            raise Errors::OpcodeOrderError, 'Expected HEARTBEAT_ACK packet' unless first_ack[:op] == Opcodes::Received::HEARTBEAT_ACK

            identify_payload = {
              op: Opcodes::Sent::IDENTIFY,
              d: {
                token: resolve_token,
                intents: (1 << 9) | (1 << 12) | (1 << 15),
                properties: {
                  '$os': RUBY_PLATFORM,
                  '$browser': 'gruv',
                  '$device': 'gruv',
                },
              },
            }.to_json
            send(identify_payload)

            ready = read_packet
            ready_event = ready[:d]
            if ready[:op] != Opcodes::Received::DISPATCH || ready[:t] != 'READY'
              raise Errors::OpcodeOrderError, 'Expected READY dispatch'
            end

            session.resume_url = ready_event[:resume_gateway_url]
            session.session_id = ready_event[:session_id]
            session.sequence_number = ready[:s]
            session.bot_user_id = ready_event.dig(:user, :id)

            yield('READY', ready_event) if block_given?
            listen(&block)
          end
        ensure
          heartbeat.stop
          self.connection = nil
        end

        def resume(&block)
          disconnect

          open_connection(session.resume_url) do
            hello_packet = read_packet
            raise Errors::OpcodeOrderError, 'Expected HELLO packet on resume' unless hello_packet[:op] == Opcodes::Received::HELLO

            heartbeat.start(hello_packet[:d][:heartbeat_interval])

            payload = {
              op: Opcodes::Sent::RESUME,
              d: {
                token: resolve_token,
                session_id: session.session_id,
                seq: session.sequence_number,
              },
            }.to_json

            send(payload)
            listen(&block)
          end
        ensure
          heartbeat.stop
          self.connection = nil
        end

        def listen(&block)
          while (message = read_packet)
            case message[:op]
            when Opcodes::Received::DISPATCH
              on_dispatch(message, &block)
            when Opcodes::Received::RECONNECT
              raise Errors::ConnectionClosed, 'Gateway requested reconnect'
            when Opcodes::Received::INVALIDATE_SESSION
              raise Errors::InvalidSession, 'Gateway invalidated session'
            when Opcodes::Received::HEARTBEAT_ACK
              logger.debug('discord_gateway.heartbeat.ack')
            else
              logger.debug("discord_gateway.unhandled_opcode op=#{message[:op]}")
            end
          end
        end

        def disconnect
          heartbeat&.stop
          connection&.close
          self.connection = nil
        end

        def read_packet
          return unless connection

          message = connection.read
          return unless message

          JSON.parse(message, symbolize_names: true)
        rescue JSON::ParserError
          raise Errors::PacketInvalidFormatError, message
        end

        def send(payload)
          raise Errors::ConnectionClosed, 'Tried to write with no websocket' unless connection

          connection.write(payload)
          connection.flush
        end

        private

        def on_dispatch(data)
          session.sequence_number = data[:s] if data[:s]
          yield(data[:t], data[:d]) if block_given?
        end

        def open_connection(url)
          require 'async'
          require 'async/websocket/client'
          require 'async/http/endpoint'

          endpoint = Async::HTTP::Endpoint.parse(
            "#{url}?v=10&encoding=json",
            alpn_protocols: Async::HTTP::Protocol::HTTP11.names,
          )

          Async::WebSocket::Client.connect(endpoint) do |socket|
            self.connection = socket
            yield
          end
        end

        def resolve_token
          config = AppConfig.load
          config['discord_bot_token'] || config.dig('discord', 'bot_token') || ENV['DISCORD_BOT_TOKEN']
        end
      end
    end
  end
end
