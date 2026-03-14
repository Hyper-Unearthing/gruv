# frozen_string_literal: true

require_relative 'client'
require_relative '../../media_storage'
require_relative '../concerns/sender'

module CommunicationPlatform
  module Discord
    class Sender
      include Concerns::Sender
      def initialize
        @client = Client.new
      end

      def send_message(channel_id:, message:, reply_to_message_id: nil, **_ignored)
        reference = reply_to_message_id ? { message_id: reply_to_message_id } : nil
        result = @client.post_message(
          channel_id: channel_id,
          content: message,
          message_reference: reference
        )
        { message_id: result[:id], channel_id: result[:channel_id], guild_id: result[:guild_id] }
      end

      def send_photo(channel_id:, photo_input:, caption: nil, reply_to_message_id: nil, **_ignored)
        io, filename = MediaStorage.resolve_media_input(photo_input)
        reference = reply_to_message_id ? { message_id: reply_to_message_id } : nil
        result = @client.post_attachment(
          channel_id: channel_id,
          file: io,
          filename: filename || 'upload.jpg',
          content: caption,
          message_reference: reference
        )
        { message_id: result[:id], channel_id: result[:channel_id], guild_id: result[:guild_id] }
      end

      def send_voice(channel_id:, voice_input:, caption: nil, reply_to_message_id: nil, **_ignored)
        io, filename = MediaStorage.resolve_media_input(voice_input)
        reference = reply_to_message_id ? { message_id: reply_to_message_id } : nil
        result = @client.post_attachment(
          channel_id: channel_id,
          file: io,
          filename: filename || 'voice.ogg',
          content: caption,
          message_reference: reference
        )
        { message_id: result[:id], channel_id: result[:channel_id], guild_id: result[:guild_id] }
      end

      def send_document(channel_id:, document_input:, caption: nil, filename: nil, reply_to_message_id: nil, **_ignored)
        io, detected_filename = MediaStorage.resolve_media_input(document_input)
        reference = reply_to_message_id ? { message_id: reply_to_message_id } : nil
        result = @client.post_attachment(
          channel_id: channel_id,
          file: io,
          filename: filename || detected_filename || 'document',
          content: caption,
          message_reference: reference
        )
        { message_id: result[:id], channel_id: result[:channel_id], guild_id: result[:guild_id] }
      end

      def get_me
        @client.get_me
      end
    end
  end
end
