# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'time'
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
      MEDIA_GROUP_FLUSH_DELAY_SECONDS = 1.5
      MIN_PENDING_MEDIA_GROUP_POLL_TIMEOUT = 1
      STATE_FILE = InstanceFileScope.path('telegram_writer_state.json')

      def initialize(inbox_path)
        @inbox = Inbox.new(inbox_path)
        @running = false
        @bot_token = resolve_token
        @poll_timeout = DEFAULT_POLL_TIMEOUT
        @retry_delay = DEFAULT_RETRY_DELAY

        state = load_state
        @offset = state[:offset]
        @pending_media_groups = state[:pending_media_groups]
      end

      def self.sender
        Sender.new
      end

      def start
        log_file_writer = LogFileWriter.new(file_path: InstanceFileScope.path('daemon_logs.jsonl'), process_name: 'telegram_writer')
        Logging.instance.attach(log_file_writer)

        @running = true
        Logging.instance.notify('telegram_writer.start', {
          poll_timeout: @poll_timeout,
          retry_delay: @retry_delay,
          offset: @offset,
          pending_media_group_count: @pending_media_groups.length,
        })

        missing_token_logged = false

        trap('INT') { stop('INT') }
        trap('TERM') { stop('TERM') }

        while @running
          begin
            flush_ready_media_groups!

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

        flush_ready_media_groups!(force: true)
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
        timeout_seconds = current_poll_timeout
        uri = URI("https://api.telegram.org/bot#{@bot_token}/getUpdates")
        req = Net::HTTP::Post.new(uri)
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate({
          timeout: timeout_seconds,
          offset: @offset,
          # Pick up group/supergroup events too.
          # Telegram delivers them as message/channel_post; ignoring them causes the writer
          # to miss group content.
          allowed_updates: ['message', 'edited_message', 'channel_post', 'edited_channel_post']
        })

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: timeout_seconds + 10) do |http|
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
        if updates.empty?
          flush_ready_media_groups!
          return
        end

        updates.each do |update|
          process_update(update)
          advance_offset(update['update_id'])
        end

        flush_ready_media_groups!

        Logging.instance.notify('telegram_writer.poll', {
          updates_count: updates.count,
          next_offset: @offset,
          pending_media_group_count: @pending_media_groups.length,
          poll_timeout: timeout_seconds,
        })
      end

      def process_update(update)
        message = extract_update_message(update)
        return unless message

        media_group_id = present_string(message['media_group_id'])
        if media_group_id
          buffer_media_group_update(update: update, message: message, media_group_id: media_group_id)
        else
          insert_single_message(update: update, message: message)
        end
      end

      def extract_update_message(update)
        # Updates from groups/supergroups can arrive as `message` (including from bots)
        # while channels arrive as `channel_post`. We accept both.
        update['message'] || update['channel_post'] || update['edited_message'] || update['edited_channel_post']
      end

      def insert_single_message(update:, message:)
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

        @inbox.insert_message(
          platform: 'telegram',
          channel_id: chat_id,
          scope: scope_for_chat_type(chat_type),
          sender_id: from['id'],
          sender_username: from['username'],
          sender_name: from['first_name'],
          provider_message_id: message['message_id'],
          provider_update_id: update['update_id'],
          message: content,
          metadata: {
            update_id: update['update_id'],
            message_id: message['message_id'],
            provider_message_id: message['message_id'],
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
          media_group_id: nil,
        })
      end

      def buffer_media_group_update(update:, message:, media_group_id:)
        chat_id = message.dig('chat', 'id').to_s
        key = media_group_key(chat_id: chat_id, media_group_id: media_group_id)
        timestamp = Time.now.utc.iso8601

        group = @pending_media_groups[key] ||= {
          'chat_id' => chat_id,
          'media_group_id' => media_group_id,
          'entries' => [],
          'first_seen_at' => timestamp,
          'last_seen_at' => timestamp,
        }

        group['entries'].reject! { |entry| entry.dig('message', 'message_id').to_s == message['message_id'].to_s }
        group['entries'] << {
          'update_id' => update['update_id'],
          'message' => deep_copy_json(message)
        }
        group['entries'] = sort_media_group_entries(group['entries'])
        group['last_seen_at'] = timestamp

        Logging.instance.notify('telegram_writer.media_group.buffered', {
          chat_id: chat_id,
          media_group_id: media_group_id,
          message_id: message['message_id'],
          update_id: update['update_id'],
          item_count: group['entries'].length,
        })
      end

      def flush_ready_media_groups!(force: false)
        changed = false

        @pending_media_groups.keys.each do |key|
          group = @pending_media_groups[key]
          next unless group
          next unless force || media_group_ready?(group)

          changed ||= flush_media_group(key, group)
        end

        persist_state if changed
      end

      def flush_media_group(key, group)
        payload = build_media_group_payload(group)
        media_group_id = group['media_group_id']
        chat_id = group['chat_id']

        unless payload
          Logging.instance.notify('telegram_writer.message.skipped', {
            chat_id: chat_id,
            media_group_id: media_group_id,
            reason: 'unsupported_or_empty_media_group',
          })
          @pending_media_groups.delete(key)
          return true
        end

        @inbox.insert_message(**payload)

        Logging.instance.notify('telegram_writer.message.inserted', {
          chat_id: chat_id,
          update_id: payload[:provider_update_id],
          message_id: payload.dig(:metadata, :message_id),
          media_group_id: media_group_id,
          media_group_item_count: payload.dig(:metadata, :media_group_item_count),
          has_photo: payload.dig(:metadata, :photo_file_ids)&.any?,
          image_downloaded_count: payload.dig(:metadata, :image_file_paths)&.length.to_i,
          has_attachments: payload.dig(:metadata, :has_attachments),
          attachment_downloaded_count: payload.dig(:metadata, :attachment_files)&.length.to_i,
          has_voice: payload.dig(:metadata, :has_voice),
        })

        @pending_media_groups.delete(key)
        true
      rescue => e
        Logging.instance.notify('telegram_writer.media_group.flush_error', {
          chat_id: chat_id,
          media_group_id: media_group_id,
          error: e.message,
          backtrace: e.backtrace,
        })
        false
      end

      def build_media_group_payload(group)
        entries = sort_media_group_entries(group['entries'])
        return nil if entries.empty?

        representative_message = entries.first['message'] || {}
        chat_id = representative_message.dig('chat', 'id').to_s
        from = representative_message['from'] || {}
        chat_type = representative_message.dig('chat', 'type')
        provider_message_id = media_group_provider_message_id(group['media_group_id'])

        photo_file_ids = []
        image_downloads = []
        attachment_downloads = []
        voice_file_ids = []
        message_ids = []
        update_ids = []

        entries.each do |entry|
          message = entry['message'] || {}
          update_id = entry['update_id']

          message_ids << message['message_id'] if message['message_id']
          update_ids << update_id if update_id
          photo_file_ids.concat(extract_photo_file_ids(message['photo']))
          image_downloads.concat(download_photos(message['photo']))
          attachment_downloads.concat(download_message_attachments(message))

          voice_file_id = present_string(message.dig('voice', 'file_id'))
          voice_file_ids << voice_file_id if voice_file_id
        end

        photo_file_ids = photo_file_ids.compact.uniq
        image_file_paths = image_downloads.map { |item| item[:path] }.compact.uniq
        attachment_downloads = deduplicate_attachments_by_path(attachment_downloads)
        attachment_file_paths = attachment_downloads.map { |item| item[:path] }.compact.uniq
        voice_file_ids = voice_file_ids.compact.uniq
        update_ids = update_ids.compact
        message_ids = message_ids.compact

        content = extract_media_group_content(
          entries,
          has_photo: photo_file_ids.any?,
          has_attachments: attachment_downloads.any?,
          has_voice: voice_file_ids.any?
        )
        return nil unless content

        primary_update_id = update_ids.max_by(&:to_i)
        primary_message_id = message_ids.min_by(&:to_i)

        {
          platform: 'telegram',
          channel_id: chat_id,
          scope: scope_for_chat_type(chat_type),
          sender_id: from['id'],
          sender_username: from['username'],
          sender_name: from['first_name'],
          provider_message_id: provider_message_id,
          provider_update_id: primary_update_id,
          message: content,
          metadata: {
            update_id: primary_update_id,
            message_id: primary_message_id,
            provider_message_id: provider_message_id,
            from_id: from['id'],
            from_username: from['username'],
            from_first_name: from['first_name'],
            chat_type: chat_type,
            media_group_id: group['media_group_id'],
            is_media_group: true,
            media_group_item_count: entries.length,
            media_group_message_ids: message_ids,
            media_group_update_ids: update_ids,
            media_group_items: entries.map { |entry| media_group_item_metadata(entry) },
            photo_file_ids: photo_file_ids,
            photo_file_paths: image_file_paths,
            image_file_paths: image_file_paths,
            has_voice: voice_file_ids.any?,
            voice_file_id: voice_file_ids.first,
            voice_file_ids: voice_file_ids,
            has_attachments: attachment_downloads.any?,
            attachment_files: attachment_downloads,
            attachment_file_paths: attachment_file_paths,
          }
        }
      end

      def extract_media_group_content(entries, has_photo:, has_attachments:, has_voice:)
        captions = entries.filter_map do |entry|
          extract_text_or_caption(entry['message'])
        end
        return captions.join("\n\n") unless captions.empty?

        return '[Photo album]' if has_photo && !has_attachments && !has_voice
        return '[Media album]' if has_photo || has_attachments || has_voice

        nil
      end

      def media_group_item_metadata(entry)
        message = entry['message'] || {}

        {
          update_id: entry['update_id'],
          message_id: message['message_id'],
          caption: normalized_string(message['caption']),
          text: normalized_string(message['text']),
          photo_file_ids: extract_photo_file_ids(message['photo']),
          attachment_types: attachment_refs(message).map { |ref| ref[:type] },
          attachment_file_ids: attachment_refs(message).filter_map { |ref| present_string(ref.dig(:data, 'file_id')) }
        }
      end

      def media_group_key(chat_id:, media_group_id:)
        "#{chat_id}:#{media_group_id}"
      end

      def media_group_provider_message_id(media_group_id)
        "media_group:#{media_group_id}"
      end

      def media_group_ready?(group)
        Time.now.utc >= media_group_due_at(group)
      end

      def media_group_due_at(group)
        parse_time(group['last_seen_at']) + MEDIA_GROUP_FLUSH_DELAY_SECONDS
      end

      def current_poll_timeout
        return @poll_timeout if @pending_media_groups.empty?

        seconds_until_flush = seconds_until_next_media_group_flush
        [@poll_timeout, [seconds_until_flush.ceil, MIN_PENDING_MEDIA_GROUP_POLL_TIMEOUT].max].min
      end

      def seconds_until_next_media_group_flush
        now = Time.now.utc
        due_in = @pending_media_groups.values.map do |group|
          [media_group_due_at(group) - now, 0].max
        end
        due_in.min || @poll_timeout
      end

      def advance_offset(update_id)
        next_offset = update_id.to_i + 1
        return unless next_offset > @offset

        @offset = next_offset
        persist_state
      end

      def scope_for_chat_type(chat_type)
        if chat_type == 'private'
          'dm'
        elsif %w[group supergroup channel].include?(chat_type)
          'group'
        end
      end

      def extract_message_content(message, has_photo:, voice_file_id:)
        text_or_caption = extract_text_or_caption(message)
        return text_or_caption if text_or_caption

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

      def extract_text_or_caption(message)
        text = message['text'].to_s.strip
        return text unless text.empty?

        caption = message['caption'].to_s.strip
        return caption unless caption.empty?

        nil
      end

      def normalized_string(value)
        text = value.to_s.strip
        return nil if text.empty?

        text
      end

      def present_string(value)
        normalized_string(value)
      end

      def extract_photo_file_ids(photo_entries)
        # Only keep the largest/best quality photo (Telegram sends multiple sizes)
        largest = select_largest_photo(photo_entries)
        largest ? [present_string(largest['file_id'])].compact : []
      end

      def download_photos(photo_entries)
        # Only download the largest/best quality photo (Telegram sends multiple sizes)
        largest = select_largest_photo(photo_entries)
        return [] unless largest

        file_id = present_string(largest['file_id'])
        return [] unless file_id

        begin
          downloaded = telegram_client.download_file(file_id)
          saved_path = MediaStorage.save_bytes(
            dir_name: 'images',
            bytes: downloaded['bytes'],
            identifier: file_id,
            index: 0,
            fallback_prefix: 'photo',
            filename_hint: downloaded['file_path'],
            fallback_ext: '.jpg',
            content_type: downloaded['content_type']
          )
          [{ type: 'image', file_id: file_id, path: saved_path }]
        rescue => e
          Logging.instance.notify('telegram_writer.photo_download_error', {
            file_id: file_id,
            error: e.message,
          })
          []
        end
      end

      def select_largest_photo(photo_entries)
        photos = Array(photo_entries).compact
        return nil if photos.empty?

        # Telegram typically orders photos by size (smallest to largest)
        # Pick the one with the largest file_size, or fall back to the last one
        photos.max_by { |p| p['file_size'].to_i }
      end

      def attachment_refs(message)
        refs = []
        refs << { type: 'document', data: message['document'] } if message['document']
        refs << { type: 'video', data: message['video'] } if message['video']
        refs << { type: 'animation', data: message['animation'] } if message['animation']
        refs << { type: 'audio', data: message['audio'] } if message['audio']
        refs << { type: 'voice', data: message['voice'] } if message['voice']
        refs << { type: 'sticker', data: message['sticker'] } if message['sticker']
        refs
      end

      def download_message_attachments(message)
        attachment_refs(message).filter_map.with_index do |ref, index|
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

      def deduplicate_attachments_by_path(attachments)
        seen_paths = {}

        attachments.filter_map do |attachment|
          path = attachment[:path]
          next if path.nil? || path.empty?
          next if seen_paths[path]

          seen_paths[path] = true
          attachment
        end
      end

      def sort_media_group_entries(entries)
        Array(entries).sort_by do |entry|
          message_id = entry.dig('message', 'message_id').to_i
          update_id = entry['update_id'].to_i
          [message_id, update_id]
        end
      end

      def deep_copy_json(payload)
        JSON.parse(JSON.generate(payload))
      end

      def telegram_client
        @telegram_client ||= Client.new(bot_token: @bot_token)
      end

      def load_state
        return { offset: 0, pending_media_groups: {} } unless File.exist?(STATE_FILE)

        state = JSON.parse(File.read(STATE_FILE))
        {
          offset: state['offset'].to_i,
          pending_media_groups: normalize_pending_media_groups(state['pending_media_groups'])
        }
      rescue JSON::ParserError
        { offset: 0, pending_media_groups: {} }
      end

      def normalize_pending_media_groups(groups)
        return {} unless groups.is_a?(Hash)

        groups.each_with_object({}) do |(key, group), normalized|
          next unless group.is_a?(Hash)

          entries = Array(group['entries']).filter_map do |entry|
            next unless entry.is_a?(Hash) && entry['message'].is_a?(Hash)

            {
              'update_id' => entry['update_id'],
              'message' => entry['message']
            }
          end
          next if entries.empty?

          normalized[key.to_s] = {
            'chat_id' => group['chat_id'].to_s,
            'media_group_id' => group['media_group_id'].to_s,
            'entries' => sort_media_group_entries(entries),
            'first_seen_at' => group['first_seen_at'] || Time.now.utc.iso8601,
            'last_seen_at' => group['last_seen_at'] || Time.now.utc.iso8601,
          }
        end
      end

      def parse_time(value)
        Time.parse(value.to_s).utc
      rescue ArgumentError
        Time.at(0).utc
      end

      def persist_state
        File.write(STATE_FILE, JSON.pretty_generate({
          offset: @offset,
          pending_media_groups: @pending_media_groups
        }))
      rescue StandardError => e
        Logging.instance.notify('telegram_writer.state_write_error', {
          error: e.message,
        })
      end
    end
  end
end
