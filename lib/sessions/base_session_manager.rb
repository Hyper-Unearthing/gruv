require 'securerandom'
require 'time'
require_relative 'concerns/basic_compaction'
require_relative '../llm_gateway_providers/usage_normalizer'

class BaseSessionManager
  include BasicCompaction

  attr_reader :session_id, :session_start, :events
  attr_accessor :model

  def initialize(events)
    if(events)
      session_event = events[0]
      @session_id = session_event[:id]
      @session_start = session_event[:timestamp]
      @events = events
    else
      @session_id = SecureRandom.uuid
      @session_start = Time.now.strftime('%Y%m%d_%H%M%S')
      @events = [{ type: 'session', id: session_id, timestamp: session_start }]
    end
  end

  def on_notify(event)
    payload = event[:payload]
    name = event[:name]

    case name
    when :user_input, :message
      push_entry(
        type: 'message',
        usage: message_usage(payload),
        data: {
          role: payload[:role],
          content: payload[:content]
        }
      )
    end
  end

  def push_entry(entry)
    id = SecureRandom.uuid
    new_entry = {
      id: id,
      parent_id: parent_id_for_new_entry,
      timestamp: Time.now.iso8601,
      **entry
    }

    persist_entry(new_entry)
  end

  def current_transcript
    message_entries.map { |event| event[:data] }
  end

  def assemble_transcript
    latest_transcript = fetch_latest_transcript
    assemble_with_compaction(messages: latest_transcript[:messages], compaction_data: latest_transcript[:compaction_data])
  end

  def total_tokens
    message_entries.reverse.find { |entry| entry.dig(:usage, :total_tokens) }&.dig(:usage, :total_tokens).to_i
  end

  private

  def assemble_with_compaction(messages:, compaction_data:)
    return messages unless compaction_data && compaction_data[:first_kept_entry_id]

    summary_message = {
      role: 'assistant',
      content: [
        {
          type: 'text',
          text: compaction_data[:summary]
        }
      ]
    }

    [summary_message, *drop_leading_non_text_messages(messages)]
  end

  def drop_leading_non_text_messages(messages)
    messages.drop_while { |message| !text_only_message?(message) }
  end

  def text_only_message?(message)
    return false if message[:content].empty?

    message[:content].all? { |part| ['text', 'input_text', 'output_text'].include?(part[:type]) }
  end

  def fetch_latest_transcript
    raise NotImplementedError, '#fetch_latest_transcript must be implemented in subclasses'
  end

  def parent_id_for_new_entry
    raise NotImplementedError, '#parent_id_for_new_entry must be implemented in subclasses'
  end

  def persist_entry(_entry)
    raise NotImplementedError, '#persist_entry must be implemented in subclasses'
  end

  def message_entries
    raise NotImplementedError, '#message_entries must be implemented in subclasses'
  end

  def last_summary
    raise NotImplementedError, '#last_summary must be implemented in subclasses'
  end

  def last_compaction_entry
    raise NotImplementedError, '#last_compaction_entry must be implemented in subclasses'
  end

  def message_usage(message)
    UsageNormalizer.normalize(message[:usage])
  end
end
