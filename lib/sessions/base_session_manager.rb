require 'securerandom'
require 'time'

class BaseSessionManager
  attr_reader :session_id, :session_start, :events
  attr_accessor :model

  def initialize(session_id:, session_start:, events: [])
    @session_id = session_id
    @session_start = session_start
    @events = events
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

  def compaction(adapter, messages_to_keep: 2)
    entries = message_entries
    return nil if entries.length <= messages_to_keep

    split_index = entries.length - messages_to_keep
    entries_to_summarise = entries[0...split_index]
    first_kept_entry = entries[split_index]

    result = CompactionPrompt.new(adapter, entries_to_summarise).post
    text_parts = result[:choices]&.dig(0, :content).select { |part| part[:type] == 'text' }
    summary = text_parts[0][:text]
    raise 'Compaction Error' if summary.empty?

    compaction_entry = {
      type: 'compaction',
      usage: result[:usage],
      data: {
        summary: summary,
        first_kept_entry_id: first_kept_entry[:id]
      }
    }

    push_entry(compaction_entry)
    compaction_entry
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

    [summary_message, *messages]
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

  def message_usage(message)
    message[:usage]
  end
end
