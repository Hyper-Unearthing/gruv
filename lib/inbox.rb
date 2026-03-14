# frozen_string_literal: true

require 'active_record'
require 'json'
require 'time'

# ActiveRecord model for messages
class Message < ActiveRecord::Base
  validates :platform, presence: true
  validates :channel_id, presence: true
  validates :state, presence: true, inclusion: { in: %w[pending processing processed failed] }
  validates :message, presence: true
  validates :timestamp, presence: true

  def self.priority_query
    sql = <<~SQL
      SELECT m.id, m.platform, m.channel_id, m.scope,
             m.sender_id, m.sender_username, m.sender_name,
             m.provider_message_id, m.provider_update_id,
             m.attempt_count, m.message, m.metadata, m.timestamp,
             c.name, c.tags, c.notes, c.user_requests
      FROM messages m
      LEFT JOIN contacts c ON m.platform = 'telegram' AND m.channel_id = c.telegram_chat_id
      WHERE m.state = 'pending'
        AND NOT EXISTS (
          SELECT 1
          FROM messages processing_message
          WHERE processing_message.state = 'processing'
            AND processing_message.channel_id = m.channel_id
        )
      ORDER BY
        CASE m.platform
          WHEN 'system' THEN 3
          WHEN 'clone'  THEN 2
          ELSE 1
        END,
        m.timestamp ASC
    SQL
    find_by_sql(sql)
  end
end

# ActiveRecord model for channel attachments
class ChannelAttachment < ActiveRecord::Base
  validates :source, presence: true
  validates :channel_id, presence: true
  validates :path, presence: true
end

# ActiveRecord model for contacts
class Contact < ActiveRecord::Base
  validates :telegram_chat_id, presence: true, uniqueness: true
end

# Inbox system for managing pending messages
class Inbox
  def initialize(db_path)
    @db_path = db_path
    setup_connection
  end

  def setup_connection
    ActiveRecord::Base.establish_connection(
      adapter: 'sqlite3',
      database: @db_path,
      timeout: 5000
    )
  end

  # Insert a new message
  def insert_message(
    platform:,
    channel_id:,
    message:,
    metadata: nil,
    scope: nil,
    sender_id: nil,
    sender_username: nil,
    sender_name: nil,
    provider_message_id: nil,
    provider_update_id: nil
  )
    timestamp = Time.now.utc.iso8601
    normalized_metadata = metadata || {}

    msg = Message.create!({
      platform: platform,
      channel_id: channel_id,
      scope: scope,
      sender_id: sender_id,
      sender_username: sender_username,
      sender_name: sender_name,
      provider_message_id: provider_message_id,
      provider_update_id: provider_update_id,
      state: 'pending',
      attempt_count: 0,
      message: message,
      timestamp: timestamp,
      metadata: normalized_metadata
    })

    insert_channel_attachments(message_record: msg, metadata: normalized_metadata)
    msg
  end

  # Get next pending message with priority
  def next_pending(processing_timeout_seconds: 300)
    result = Message.priority_query.first
    return nil unless result

    claimed = Message.where(id: result.id, state: 'pending').update_all(
      ["state = ?, processing_started_at = ?, attempt_count = attempt_count + 1", 'processing', Time.now.utc.iso8601]
    )
    return nil if claimed == 0

    parsed_metadata = result.metadata
    message_attachments = ChannelAttachment.where(message_id: result.id).order(:id).map { |attachment| attachment_payload(attachment) }

    {
      id: result.id,
      platform: result.platform,
      channel_id: result.channel_id,
      scope: result.scope,
      sender_id: result.sender_id,
      sender_username: result.sender_username,
      sender_name: result.sender_name,
      provider_message_id: result.provider_message_id,
      provider_update_id: result.provider_update_id,
      attempt_count: result.attempt_count.to_i + 1,
      message: result.message,
      metadata: parsed_metadata,
      message_attachments: message_attachments,
      timestamp: result.timestamp,
      contact: if result.respond_to?(:name)
        {
          name: result.name,
          tags: result.tags,
          notes: result.notes,
          user_requests: result.user_requests
        }
      else
        nil
      end
    }
  end

  def insert_channel_attachments(message_record:, metadata:)
    seen_paths = {}
    provider_message_ref = metadata_value(metadata, :provider_message_id, :message_id)

    attachment_files = Array(metadata_value(metadata, :attachment_files))
    attachment_files.each do |attachment|
      path = metadata_value(attachment, :path)
      next if path.nil? || path.empty?
      next if seen_paths[path]

      ChannelAttachment.create!({
        message_id: message_record.id,
        source: message_record.platform,
        channel_id: message_record.channel_id,
        provider_message_id: provider_message_ref,
        attachment_type: metadata_value(attachment, :type) || 'attachment',
        provider_file_id: metadata_value(attachment, :file_id, :id),
        file_name: metadata_value(attachment, :file_name, :filename),
        content_type: metadata_value(attachment, :content_type),
        url: metadata_value(attachment, :url),
        path: path,
        timestamp: message_record.timestamp
      })

      seen_paths[path] = true
    end

    image_file_paths = Array(metadata_value(metadata, :image_file_paths))
    image_file_paths.each do |path|
      next if path.nil? || path.empty?
      next if seen_paths[path]

      ChannelAttachment.create!({
        message_id: message_record.id,
        source: message_record.platform,
        channel_id: message_record.channel_id,
        provider_message_id: provider_message_ref,
        attachment_type: 'image',
        path: path,
        timestamp: message_record.timestamp
      })

      seen_paths[path] = true
    end

    photo_file_paths = Array(metadata_value(metadata, :photo_file_paths))
    photo_file_paths.each do |path|
      next if path.nil? || path.empty?
      next if seen_paths[path]

      ChannelAttachment.create!({
        message_id: message_record.id,
        source: message_record.platform,
        channel_id: message_record.channel_id,
        provider_message_id: provider_message_ref,
        attachment_type: 'image',
        path: path,
        timestamp: message_record.timestamp
      })

      seen_paths[path] = true
    end
  end

  # On daemon startup, any message still in 'processing' was abandoned mid-run.
  # Mark them all failed with a timeout error so they don't block their channels.
  def cleanup_processing_on_startup
    Message.where(state: 'processing')
           .update_all(
             ["state = ?, processing_started_at = NULL, last_error = ?", 'failed', 'Processing timed out (daemon restarted)']
           )
  end

  def reclaim_stale_processing(processing_timeout_seconds: 300)
    cutoff = (Time.now - processing_timeout_seconds).utc.iso8601

    Message.where(state: 'processing')
           .where('processing_started_at < ?', cutoff)
           .update_all(
             ["state = ?, processing_started_at = NULL, last_error = ?", 'pending', 'Processing lease timed out; returned to pending']
           )
  end

  # Mark message as processed
  def mark_processed(id)
    Message.where(id: id).update_all(
      ["state = ?, processed_at = ?, processing_started_at = NULL, last_error = NULL", 'processed', Time.now.utc.iso8601]
    )
  end

  def mark_failed(id, error:, max_attempts: 3)
    Message.where(id: id).update_all(
      ["state = ?, last_error = ?, processing_started_at = NULL", 'failed', error]
    )
  end

  # Get count of pending messages
  def pending_count
    Message.where(state: 'pending').count
  end

  # Get all pending messages (for debugging)
  def all_pending
    Message.where(state: 'pending').order(:timestamp)
  end

  # Cleanup old processed messages (optional TTL)
  def cleanup_processed(older_than_days: 30)
    cutoff = (Time.now - (older_than_days * 24 * 60 * 60)).utc.iso8601
    Message.where(state: 'processed').where('timestamp < ?', cutoff).delete_all
  end

  private

  def metadata_value(payload, *keys)
    return nil unless payload.respond_to?(:key?)

    keys.each do |key|
      return payload[key] if payload.key?(key)

      string_key = key.to_s
      return payload[string_key] if payload.key?(string_key)
    end

    nil
  end

  def attachment_payload(attachment)
    {
      id: attachment.id,
      message_id: attachment.message_id,
      source: attachment.source,
      channel_id: attachment.channel_id,
      provider_message_id: attachment.provider_message_id,
      attachment_type: attachment.attachment_type,
      provider_file_id: attachment.provider_file_id,
      file_name: attachment.file_name,
      content_type: attachment.content_type,
      url: attachment.url,
      path: attachment.path,
      timestamp: attachment.timestamp
    }
  end

end
