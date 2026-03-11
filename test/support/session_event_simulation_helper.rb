module SessionEventSimulationHelper
  def simulate_three_messages(manager, user_text:, tool_id:, tool_name:, tool_input:, tool_result:)
    manager.on_notify(
      name: :user_input,
      payload: {
        role: 'user',
        content: [{ type: 'text', text: user_text }]
      }
    )

    manager.on_notify(
      name: :message,
      payload: {
        role: 'assistant',
        usage: { input_tokens: 1, output_tokens: 2, total_tokens: 3 },
        content: [
          { type: 'text', text: 'I will inspect the file.' },
          { type: 'tool_use', id: tool_id, name: tool_name, input: tool_input }
        ]
      }
    )

    manager.on_notify(
      name: :message,
      payload: {
        role: 'user',
        content: [{ type: 'tool_result', tool_use_id: tool_id, content: tool_result }]
      }
    )
  end
end
