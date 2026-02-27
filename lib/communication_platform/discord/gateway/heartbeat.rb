# frozen_string_literal: true

require 'async'
require_relative 'opcodes'

module CommunicationPlatform
  module Discord
    module Gateway
      class Heartbeat
        attr_reader :connection, :logger
        attr_accessor :interval_ms, :task

        def initialize(connection, logger)
          @connection = connection
          @logger = logger
        end

        def start(interval_ms)
          self.interval_ms = interval_ms
          stop
          logger.info("discord_gateway.heartbeat.start interval_ms=#{interval_ms}")
          schedule
        end

        def resume
          stop
          logger.info('discord_gateway.heartbeat.resume')
          schedule
        end

        def stop
          task&.stop
          self.task = nil
        end

        private

        def schedule
          send_heartbeat

          self.task = Async do |current_task|
            loop do
              current_task.sleep(interval_ms / 1000.0)
              send_heartbeat
            end
          end
        end

        def send_heartbeat
          payload = {
            op: Opcodes::Sent::HEARTBEAT,
            d: connection.session.sequence_number,
          }.to_json

          connection.send(payload)
        rescue => e
          logger.warn("discord_gateway.heartbeat.send_failed error=#{e.message}")
        end
      end
    end
  end
end
