module BasicCompaction
  def compaction(adapter)
    result = CompactionPrompt.new(adapter, active_messages, last_summary: last_compaction_entry&.dig(:data, :summary)).post
    text_parts = result[:choices]&.dig(0, :content).select { |part| part[:type] == 'text' }
    summary = text_parts[0][:text]
    raise 'Compaction Error' if summary.empty?

    compaction_entry = {
      type: 'compaction',
      usage: result[:usage],
      data: {
        summary: summary
      }
    }

    push_entry(compaction_entry)
    compaction_entry
  end
end
