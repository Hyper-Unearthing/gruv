# frozen_string_literal: true

require 'net/http'
require 'json'
require 'stringio'
require_relative '../../app_config'
require_relative '../../media_storage'
require_relative '../../errors'

module CommunicationPlatform
  module Discord
    class Client
      class APIError < ::APIError
        attr_reader :status, :body

        def initialize(status:, body:)
          @status = status
          @body = body
          super("Discord API error #{status}: #{body}")
        end
      end

      API_BASE = 'https://discord.com/api/v10'

      def initialize(bot_token: nil)
        @bot_token = bot_token || resolve_token
        raise ArgumentError, 'Missing Discord bot token in config' if @bot_token.strip.empty?
      end

      def open_gateway
        request_json(Net::HTTP::Get, '/gateway/bot')
      end

      def get_me
        request_json(Net::HTTP::Get, '/users/@me')
      end

      def post_message(channel_id:, content:, message_reference: nil)
        payload = { content: content }
        payload[:message_reference] = message_reference if message_reference

        request_json(Net::HTTP::Post, "/channels/#{channel_id}/messages", payload)
      end

      def post_attachment(channel_id:, file:, filename:, content: nil, message_reference: nil)
        payload = {}
        payload[:content] = content if content
        payload[:message_reference] = message_reference if message_reference

        request_multipart(Net::HTTP::Post, "/channels/#{channel_id}/messages", [
          ['payload_json', JSON.generate(payload)],
          ['files[0]', file, { filename: filename, content_type: MediaStorage.content_type_for(filename) }]
        ])
      end

      private

      def request_json(klass, path, payload = nil)
        uri = URI("#{API_BASE}#{path}")
        request = klass.new(uri)
        request['Authorization'] = "Bot #{@bot_token}"
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(payload) if payload

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          http.request(request)
        end

        raise APIError.new(status: response.code.to_i, body: response.body) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue JSON::ParserError
        raise APIError.new(status: response.code.to_i, body: response.body)
      end

      def request_multipart(klass, path, multipart_fields)
        uri = URI("#{API_BASE}#{path}")
        request = klass.new(uri)
        request['Authorization'] = "Bot #{@bot_token}"
        request.set_form(multipart_fields, 'multipart/form-data')

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
          http.request(request)
        end

        raise APIError.new(status: response.code.to_i, body: response.body) unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue JSON::ParserError
        raise APIError.new(status: response.code.to_i, body: response.body)
      end

      def resolve_token
        config = AppConfig.load
        config['discord_bot_token'] || config.dig('discord', 'bot_token') || ENV['DISCORD_BOT_TOKEN'] || ''
      end
    end
  end
end
