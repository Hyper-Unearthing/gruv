module BasicCompaction
  def compaction(adapter, messages_to_keep: 2)
    all_messages = message_entries
    return nil if all_messages.length <= messages_to_keep

    last_compaction = last_compaction_entry
    start_index = 0
    # for now we always summarize from the beginning to ensure the full context is integrated
    # even if we have a previous summary.

    split_index = all_messages.length - messages_to_keep
    return nil if start_index >= split_index

    entries_to_summarise = all_messages[start_index...split_index]
    first_kept_entry = all_messages[split_index]

    result = CompactionPrompt.new(adapter, entries_to_summarise, last_summary: last_summary).post
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
