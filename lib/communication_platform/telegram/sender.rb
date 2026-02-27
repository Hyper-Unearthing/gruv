# frozen_string_literal: true

require_relative 'client'
require_relative '../../media_storage'
require_relative '../concerns/sender'

module CommunicationPlatform
  module Telegram
    class Sender
      include Concerns::Sender
      def initialize
        @client = Client.new
      end

      def send_message(channel_id:, message:, reply_to_message_id: nil, parse_mode: nil)
        result = @client.send_message(
          chat_id: channel_id,
          text: message,
          parse_mode: parse_mode,
          reply_to_message_id: reply_to_message_id
        )
        { message_id: result['message_id'], channel_id: result.dig('chat', 'id').to_s }
      end

      def send_photo(channel_id:, photo_input:, caption: nil, parse_mode: nil, reply_to_message_id: nil)
        io, filename = MediaStorage.resolve_media_input(photo_input)
        result = @client.send_photo(
          chat_id: channel_id,
          photo: io,
          filename: filename || 'upload.jpg',
          caption: caption,
          parse_mode: parse_mode,
          reply_to_message_id: reply_to_message_id
        )
        { message_id: result['message_id'], channel_id: result.dig('chat', 'id').to_s }
      end

      def send_voice(channel_id:, voice_input:, caption: nil, reply_to_message_id: nil)
        io, filename = MediaStorage.resolve_media_input(voice_input)
        result = @client.send_voice(
          chat_id: channel_id,
          voice: io,
          filename: filename || 'voice.ogg',
          caption: caption,
          reply_to_message_id: reply_to_message_id
        )
        { message_id: result['message_id'], channel_id: result.dig('chat', 'id').to_s }
      end

      def send_document(channel_id:, document_input:, caption: nil, filename: nil, parse_mode: nil, reply_to_message_id: nil)
        io, detected_filename = MediaStorage.resolve_media_input(document_input)
        result = @client.send_document(
          chat_id: channel_id,
          document: io,
          filename: filename || detected_filename || 'document',
          caption: caption,
          parse_mode: parse_mode,
          reply_to_message_id: reply_to_message_id
        )
        { message_id: result['message_id'], channel_id: result.dig('chat', 'id').to_s }
      end

      def get_me
        @client.get_me
      end
    end
  end
end
