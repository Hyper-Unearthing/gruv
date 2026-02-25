module BasicCompaction
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
end
