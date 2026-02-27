# frozen_string_literal: true

require 'net/http'
require 'stringio'
require 'uri'
require 'json'
require_relative '../../app_config'
require_relative '../../media_storage'
require_relative '../../errors'

module CommunicationPlatform
  module Telegram
    class Client
      class APIError < ::APIError
        attr_reader :error_code, :description

        def initialize(error_code:, description:)
          @error_code = error_code
          @description = description
          super("Telegram API error #{error_code}: #{description}")
        end
      end

      API_BASE = 'https://api.telegram.org'.freeze

      def initialize(bot_token: nil)
        @bot_token = bot_token || resolve_token
        raise ArgumentError, 'Missing Telegram bot token in config' if @bot_token.to_s.strip.empty?
      end

      def send_message(chat_id:, text:, parse_mode: nil, reply_to_message_id: nil)
        payload = {
          chat_id: chat_id,
          text: text
        }
        payload[:parse_mode] = parse_mode if parse_mode
        payload[:reply_to_message_id] = reply_to_message_id if reply_to_message_id

        call_json('sendMessage', payload)
      end

      def send_photo(chat_id:, photo:, filename:, caption: nil, parse_mode: nil, reply_to_message_id: nil)
        fields = {
          'chat_id' => chat_id.to_s,
          'photo' => [photo, filename]
        }
        fields['caption'] = caption.to_s if caption
        fields['parse_mode'] = parse_mode.to_s if parse_mode
        fields['reply_to_message_id'] = reply_to_message_id if reply_to_message_id

        call_multipart('sendPhoto', fields)
      end

      def send_voice(chat_id:, voice:, filename:, caption: nil, reply_to_message_id: nil)
        fields = {
          'chat_id' => chat_id.to_s,
          'voice' => [voice, filename]
        }
        fields['caption'] = caption.to_s if caption
        fields['reply_to_message_id'] = reply_to_message_id if reply_to_message_id

        call_multipart('sendVoice', fields)
      end

      def send_document(chat_id:, document:, filename:, caption: nil, parse_mode: nil, reply_to_message_id: nil)
        fields = {
          'chat_id' => chat_id.to_s,
          'document' => [document, filename]
        }
        fields['caption'] = caption.to_s if caption
        fields['parse_mode'] = parse_mode.to_s if parse_mode
        fields['reply_to_message_id'] = reply_to_message_id if reply_to_message_id

        call_multipart('sendDocument', fields)
      end

      def get_me
        call_json('getMe', {})
      end

      def download_file(file_id)
        file_resp = call_json('getFile', { file_id: file_id })
        file_path = file_resp.fetch('file_path')

        url = URI("#{API_BASE}/file/bot#{@bot_token}/#{file_path}")
        response = Net::HTTP.start(url.host, url.port, use_ssl: true) do |http|
          req = Net::HTTP::Get.new(url)
          http.request(req)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise APIError.new(error_code: response.code.to_i, description: "file download failed: #{response.body}")
        end

        {
          'file_id' => file_id,
          'file_path' => file_path,
          'content_type' => response['Content-Type'],
          'bytes' => response.body
        }
      end

      private

      def resolve_token
        config = AppConfig.load
        config['telegram_bot_token'] || config.dig('telegram', 'bot_token')
      end

      def call_json(method, payload)
        uri = URI("#{API_BASE}/bot#{@bot_token}/#{method}")
        req = Net::HTTP::Post.new(uri)
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(payload)

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
        parse_api_response(response)
      end

      def call_multipart(method, fields)
        uri = URI("#{API_BASE}/bot#{@bot_token}/#{method}")
        req = Net::HTTP::Post.new(uri)
        form_data = fields.map do |k, v|
          if v.is_a?(Array) && v.first.is_a?(StringIO)
            [k, v[0], { filename: v[1], content_type: MediaStorage.content_type_for(v[1]) }]
          else
            [k, v]
          end
        end
        req.set_form(form_data, 'multipart/form-data')

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
        parse_api_response(response)
      end

      def parse_api_response(response)
        body = JSON.parse(response.body)
        unless response.is_a?(Net::HTTPSuccess) && body['ok']
          raise APIError.new(
            error_code: body['error_code'] || response.code.to_i,
            description: body['description'] || response.body
          )
        end

        body['result']
      rescue JSON::ParserError
        raise APIError.new(error_code: response.code.to_i, description: response.body)
      end
    end
  end
end
