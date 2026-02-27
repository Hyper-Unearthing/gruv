# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require_relative '../../inbox'
require_relative '../../logging'
require_relative '../../log_file_writer'
require_relative '../../instance_file_scope'
require_relative '../../app_config'
require_relative '../../media_storage'
require_relative 'client'
require_relative 'sender'
require_relative '../concerns/poller'

module CommunicationPlatform
  module Telegram
    class Poller
      include Concerns::Poller
      DEFAULT_POLL_TIMEOUT = 30
      DEFAULT_RETRY_DELAY = 2
      STATE_FILE = InstanceFileScope.path('telegram_writer_state.json')

      def initialize(inbox_path)
        @inbox = Inbox.new(inbox_path)
        @running = false
        @bot_token = resolve_token
        @poll_timeout = DEFAULT_POLL_TIMEOUT
        @retry_delay = DEFAULT_RETRY_DELAY
        @offset = load_offset
      end

      def self.sender
        Sender.new
      end

      def start
        log_file_writer = LogFileWriter.new(file_path: InstanceFileScope.path('telegram_writer_logs.jsonl'))
        Logging.instance.attach(log_file_writer)

        @running = true
        Logging.instance.notify('telegram_writer.start', {
          poll_timeout: @poll_timeout,
          retry_delay: @retry_delay,
          offset: @offset,
        })

        missing_token_logged = false

        trap('INT') { stop('INT') }
        trap('TERM') { stop('TERM') }

        while @running
          begin
            @bot_token ||= resolve_token
            unless @bot_token
              unless missing_token_logged
                Logging.instance.notify('telegram_writer.disabled', {
                  reason: 'missing_bot_token',
                  config_path: AppConfig.config_path,
                })
                missing_token_logged = true
              end
              sleep @retry_delay
              next
            end

            missing_token_logged = false
            poll_once
          rescue => e
            Logging.instance.notify('telegram_writer.error', {
              error: e.message,
              backtrace: e.backtrace,
            })
            sleep @retry_delay if @running
          end
        end

        Logging.instance.notify('telegram_writer.stop', {})
      end

      private

      def stop(signal)
        Logging.instance.notify('telegram_writer.stop.requested', { signal: signal })
        @running = false
      end

      def resolve_token
        config = AppConfig.load
        config['telegram_bot_token'] || config.dig('telegram', 'bot_token')
      end

      def poll_once
        uri = URI("https://api.telegram.org/bot#{@bot_token}/getUpdates")
        req = Net::HTTP::Post.new(uri)
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate({
          timeout: @poll_timeout,
          offset: @offset,
          # Pick up group/supergroup events too.
          # Telegram delivers them as message/channel_post; ignoring them causes the writer
          # to miss group content.
          allowed_updates: ['message', 'edited_message', 'channel_post', 'edited_channel_post']
        })

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: @poll_timeout + 10) do |http|
          http.request(req)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise "Telegram API HTTP #{response.code}: #{response.body}"
        end

        body = JSON.parse(response.body)
        unless body['ok']
          raise "Telegram API error: #{body['description'] || 'unknown'}"
        end

        updates = Array(body['result'])
        return if updates.empty?

        updates.each do |update|
          process_update(update)
          next_offset = update['update_id'].to_i + 1
          if next_offset > @offset
            @offset = next_offset
            persist_offset
          end
        end

        Logging.instance.notify('telegram_writer.poll', {
          updates_count: updates.count,
          next_offset: @offset,
        })
      end

      def process_update(update)
        # Updates from groups/supergroups can arrive as `message` (including from bots)
        # while channels arrive as `channel_post`. We accept both.
        message = update['message'] || update['channel_post'] || update['edited_message'] || update['edited_channel_post']
        return unless message

        photo_file_ids = extract_photo_file_ids(message['photo'])
        image_downloads = download_photos(message['photo'])
        attachment_downloads = download_message_attachments(message)
        voice_file_id = present_string(message.dig('voice', 'file_id'))

        content = extract_message_content(message, has_photo: photo_file_ids.any?, voice_file_id: voice_file_id)
        unless content
          Logging.instance.notify('telegram_writer.message.skipped', {
            update_id: update['update_id'],
            message_id: message['message_id'],
            chat_id: message.dig('chat', 'id').to_s,
            chat_type: message.dig('chat', 'type'),
            reason: 'unsupported_or_empty_message',
          })
          return
        end

        chat_id = message.dig('chat', 'id').to_s
        from = message['from'] || {}

        chat_type = message.dig('chat', 'type')
        scope = if chat_type == 'private'
          'dm'
        elsif %w[group supergroup channel].include?(chat_type)
          'group'
        end

        @inbox.insert_message(
          platform: 'telegram',
          channel_id: chat_id,
          scope: scope,
          sender_id: from['id'],
          sender_username: from['username'],
          sender_name: from['first_name'],
          provider_message_id: message['message_id'],
          provider_update_id: update['update_id'],
          message: content,
          metadata: {
            update_id: update['update_id'],
            message_id: message['message_id'],
            from_id: from['id'],
            from_username: from['username'],
            from_first_name: from['first_name'],
            chat_type: chat_type,
            photo_file_ids: photo_file_ids,
            photo_file_paths: image_downloads.map { |item| item[:path] },
            image_file_paths: image_downloads.map { |item| item[:path] },
            has_voice: !voice_file_id.nil?,
            voice_file_id: voice_file_id,
            has_attachments: !attachment_downloads.empty?,
            attachment_files: attachment_downloads,
            attachment_file_paths: attachment_downloads.map { |item| item[:path] },
          }
        )

        Logging.instance.notify('telegram_writer.message.inserted', {
          chat_id: chat_id,
          update_id: update['update_id'],
          message_id: message['message_id'],
          has_photo: photo_file_ids.any?,
          image_downloaded_count: image_downloads.length,
          has_attachments: !attachment_downloads.empty?,
          attachment_downloaded_count: attachment_downloads.length,
          has_voice: !voice_file_id.nil?,
        })
      end

      def extract_message_content(message, has_photo:, voice_file_id:)
        text = message['text'].to_s.strip
        caption = message['caption'].to_s.strip
        return text unless text.empty?
        return caption unless caption.empty?

        poll_question = message.dig('poll', 'question').to_s.strip
        return "[Poll] #{poll_question}" unless poll_question.empty?

        return '[Photo message]' if has_photo
        return '[Voice message]' if voice_file_id
        return '[Sticker message]' if message['sticker']
        return '[Document message]' if message['document']
        return '[Video message]' if message['video']
        return '[Animation message]' if message['animation']
        return '[Audio message]' if message['audio']

        nil
      end

      def present_string(value)
        str = value.to_s.strip
        return nil if str.empty?

        str
      end

      def extract_photo_file_ids(photo_entries)
        Array(photo_entries).filter_map { |entry| present_string(entry['file_id']) }.uniq
      end

      def download_photos(photo_entries)
        file_ids = Array(photo_entries).filter_map { |entry| present_string(entry['file_id']) }.uniq
        return [] if file_ids.empty?

        file_ids.filter_map.with_index do |file_id, index|
          begin
            downloaded = telegram_client.download_file(file_id)
            saved_path = MediaStorage.save_bytes(
              dir_name: 'images',
              bytes: downloaded['bytes'],
              identifier: file_id,
              index: index,
              fallback_prefix: 'photo',
              filename_hint: downloaded['file_path'],
              fallback_ext: '.jpg',
              content_type: downloaded['content_type']
            )
            { type: 'image', file_id: file_id, path: saved_path }
          rescue => e
            Logging.instance.notify('telegram_writer.photo_download_error', {
              file_id: file_id,
              error: e.message,
            })
            nil
          end
        end
      end

      def download_message_attachments(message)
        refs = []
        refs << { type: 'document', data: message['document'] } if message['document']
        refs << { type: 'video', data: message['video'] } if message['video']
        refs << { type: 'animation', data: message['animation'] } if message['animation']
        refs << { type: 'audio', data: message['audio'] } if message['audio']
        refs << { type: 'voice', data: message['voice'] } if message['voice']
        refs << { type: 'sticker', data: message['sticker'] } if message['sticker']

        refs.filter_map.with_index do |ref, index|
          file_id = present_string(ref[:data]['file_id'])
          next unless file_id

          begin
            downloaded = telegram_client.download_file(file_id)
            filename_hint = ref[:data]['file_name']
            saved_path = MediaStorage.save_bytes(
              dir_name: 'attachments',
              bytes: downloaded['bytes'],
              identifier: file_id,
              index: index,
              fallback_prefix: ref[:type],
              filename_hint: filename_hint || downloaded['file_path'],
              content_type: downloaded['content_type']
            )

            {
              type: ref[:type],
              file_id: file_id,
              file_name: filename_hint,
              path: saved_path,
            }
          rescue => e
            Logging.instance.notify('telegram_writer.attachment_download_error', {
              file_id: file_id,
              attachment_type: ref[:type],
              error: e.message,
            })
            nil
          end
        end
      end

      def telegram_client
        @telegram_client ||= Client.new(bot_token: @bot_token)
      end

      def load_offset
        return 0 unless File.exist?(STATE_FILE)

        state = JSON.parse(File.read(STATE_FILE))
        state['offset'].to_i
      rescue JSON::ParserError
        0
      end

      def persist_offset
        File.write(STATE_FILE, JSON.pretty_generate({ offset: @offset }))
      rescue StandardError => e
        Logging.instance.notify('telegram_writer.state_write_error', {
          error: e.message,
        })
      end
    end
  end
end
