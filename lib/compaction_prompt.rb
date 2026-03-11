require 'json'

class CompactionPrompt < LlmGateway::Prompt
  SYSTEM_PROMPT = <<~PROMPT.freeze
    You are summarizing a long-running conversation between a user and an assistant.

    Update the summary using the transcript.

    For each topic include:
    1. Topic (top-level heading)
    2. What the user asked
    3. Actions you took
    4. Next actions to take

    Rules:
    - If a topic from the previous summary continues, merge the information.
    - If a topic from the previous summary is not continued, omit it.
    - Keep the summary concise and structured by topic.
  PROMPT

  def initialize(client, messages, last_summary: nil)
    super(client)
    @client = client
    @messages = messages
    @last_summary = last_summary
  end

  def prompt
    payload = JSON.pretty_generate(compaction_messages)
    summary_text = @last_summary || 'no previous summary'

    prompt_text = <<~TEXT
      Previous summary:
      <summary>
      #{summary_text}
      </summary>

      Current conversation transcript:
      <transcript>
      #{payload}
      </transcript>
    TEXT

    [
      {
        role: 'user',
        content: [
          {
            type: 'text',
            text: prompt_text
          }
        ]
      }
    ]
  end

  def system_prompt
    [{ role: 'system', content: SYSTEM_PROMPT }]
  end

  def post(&block)
    @client.chat(
      prompt,
      tools: [],
      system: system_prompt,
      &block
    )
  end

  private

  def compaction_messages
    @messages.map do |message|
      {
        role: message[:role],
        content: normalize_content_blocks(message[:content])
      }
    end
  end

  def normalize_content_blocks(content)
    content.map do |block|
      case block[:type]
      when 'thinking'
        { type: 'thinking', thinking: block[:thinking] }
      when 'text'
        { type: 'text', text: block[:text] }
      when 'tool_result'
        { type: 'tool_result', tool_use_id: block[:tool_use_id], content: block[:content] }
      else
        block
      end
    end
  end
end
