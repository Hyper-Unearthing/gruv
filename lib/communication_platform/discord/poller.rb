# frozen_string_literal: true

require 'net/http'
require 'uri'
require_relative '../../inbox'
require_relative '../../logging'
require_relative '../../console_log_writer'
require_relative '../../log_file_writer'
require_relative '../../instance_file_scope'
require_relative '../../app_config'
require_relative '../../media_storage'
require_relative 'gateway/client'
require_relative 'sender'
require_relative '../concerns/poller'

module CommunicationPlatform
  module Discord
    class Poller < Gateway::Client
      include Concerns::Poller
      DEFAULT_RETRY_DELAY = 2

      def initialize(inbox_path)
        @inbox = Inbox.new(inbox_path)
        @running = false
        @retry_delay = DEFAULT_RETRY_DELAY
        @bot_user_id = nil
        @stop_signal = nil
        super(self)
      end

      def self.sender
        Sender.new
      end

      def start
        console_log_writer = ConsoleLogWriter.new
        log_file_writer = LogFileWriter.new(file_path: InstanceFileScope.path('daemon_logs.jsonl'), process_name: 'discord_writer')
        Logging.instance.attach(console_log_writer)
        Logging.instance.attach(log_file_writer)

        @running = true
        missing_token_logged = false

        Logging.instance.notify('discord_writer.start', { retry_delay: @retry_delay })

        trap('INT') { request_stop('INT') }
        trap('TERM') { request_stop('TERM') }

        while @running
          begin
            if missing_token?
              unless missing_token_logged
                Logging.instance.notify('discord_writer.disabled', {
                  reason: 'missing_bot_token',
                  config_path: AppConfig.config_path,
                })
                missing_token_logged = true
              end

              sleep @retry_delay
              next
            end

            missing_token_logged = false
            connect
          rescue LoadError => e
            Logging.instance.notify('discord_writer.error', {
              error: e.message,
              hint: 'Install async gems: bundle install',
            })
            sleep @retry_delay if @running
          rescue => e
            Logging.instance.notify('discord_writer.error', {
              error: e.message,
              backtrace: e.backtrace,
            })
            sleep @retry_delay if @running
          end
        end

        if @stop_signal
          Logging.instance.notify('discord_writer.stop.requested', { signal: @stop_signal })
          stop
        end

        Logging.instance.notify('discord_writer.stop', {})
      end

      private

      def request_stop(signal)
        @stop_signal ||= signal
        @running = false
      end

      def ready(data)
        @bot_user_id = data.dig(:user, :id)
        Logging.instance.notify('discord_writer.ready', {
          session_id: data[:session_id],
          bot_user_id: @bot_user_id,
        })
      end

      def message_create(data)
        Logging.instance.notify('discord_writer.message.recieved', data)
        author = data[:author]
        return if @bot_user_id && author[:id] == @bot_user_id

        Logging.instance.notify('discord_writer.message.extracting_content', data)
        content = extract_message_content(data)
        return unless content

        attachment_downloads = download_attachments(
          data[:attachments],
          channel_id: data[:channel_id],
          message_id: data[:id]
        )

        Logging.instance.notify('discord_writer.message.content_extracted', content)
        scope = data[:guild_id].nil? ? 'dm' : 'guild_channel'

        @inbox.insert_message(
          platform: 'discord',
          channel_id: data[:channel_id],
          scope: scope,
          sender_id: author[:id],
          sender_username: author[:username],
          sender_name: author[:global_name],
          provider_message_id: data[:id],
          provider_update_id: nil,
          message: content,
          metadata: {
            event_type: 'MESSAGE_CREATE',
            message_id: data[:id],
            channel_id: data[:channel_id],
            guild_id: data[:guild_id],
            author_id: author[:id],
            author_username: author[:username],
            author_global_name: author[:global_name],
            has_attachments: data[:attachments] && !data[:attachments].empty?,
            attachment_files: attachment_downloads,
            attachment_file_paths: attachment_downloads.map { |item| item[:path] },
            image_file_paths: attachment_downloads.select { |item| MediaStorage.image_file?(content_type: item[:content_type], filename: item[:filename]) }.map { |item| item[:path] },
          }
        )

        Logging.instance.notify('discord_writer.message.inserted', {
          channel_id: data[:channel_id],
          message_id: data[:id],
          author_id: author[:id],
          has_attachments: data[:attachments] && !data[:attachments].empty?,
          attachment_downloaded_count: attachment_downloads.length,
        })
      rescue => e
        Logging.instance.notify('discord_gateway.error', {
          message: e.message,
          backtrace: e.backtrace,
        })
      end

      def extract_message_content(data)
        content = data[:content]
        return content unless content.nil? || content.strip.empty?

        attachments = data[:attachments]
        return '[Attachment message]' unless attachments.nil? || attachments.empty?

        sticker_items = data[:sticker_items]
        return '[Sticker message]' unless sticker_items.nil? || sticker_items.empty?

        nil
      end

      def download_attachments(attachments, channel_id:, message_id:)
        return [] if attachments.nil? || attachments.empty?

        attachments.filter_map.with_index do |attachment, index|
          url = attachment[:url]
          next if url.nil? || url.strip.empty?

          begin
            bytes, content_type = fetch_attachment_bytes(url)
            saved_path = MediaStorage.save_bytes(
              dir_name: 'discord_attachments',
              bytes: bytes,
              identifier: "#{channel_id}_#{message_id}",
              index: index,
              fallback_prefix: 'attachment',
              filename_hint: attachment[:filename],
              content_type: attachment[:content_type] || content_type
            )

            {
              id: attachment[:id],
              filename: attachment[:filename],
              content_type: attachment[:content_type] || content_type,
              url: url,
              path: saved_path,
            }
          rescue => e
            Logging.instance.notify('discord_writer.attachment_download_error', {
              channel_id: channel_id,
              message_id: message_id,
              attachment_id: attachment[:id],
              url: url,
              error: e.message,
            })
            nil
          end
        end
      end

      def fetch_attachment_bytes(url)
        uri = URI(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
          req = Net::HTTP::Get.new(uri)
          http.request(req)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise "Attachment download failed HTTP #{response.code}"
        end

        [response.body, response['Content-Type']]
      end

      def missing_token?
        config = AppConfig.load
        token = config['discord_bot_token'] || config.dig('discord', 'bot_token') || ENV['DISCORD_BOT_TOKEN']
        token.nil? || token.strip.empty?
      end

      def info(message)
        Logging.instance.notify('discord_gateway.info', { message: message })
      end

      def warn(message)
        Logging.instance.notify('discord_gateway.warn', { message: message })
      end

      def error(message)
        Logging.instance.notify('discord_gateway.error', { message: message })
      end

      def debug(message)
        Logging.instance.notify('discord_gateway.debug', { message: message })
      end

      public :info, :warn, :error, :debug
    end
  end
end
