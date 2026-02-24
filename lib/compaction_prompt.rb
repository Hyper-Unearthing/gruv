require 'json'

class CompactionPrompt < LlmGateway::Prompt
  SYSTEM_PROMPT = <<~PROMPT.freeze
    You are compressing prior conversation context.

    Produce a concise summary that preserves:
    - user goals and constraints
    - decisions that were made
    - unfinished tasks and important open questions
    - key file names, commands, and code-level details that matter later

    Keep the summary factual and easy to continue from.
  PROMPT

  def initialize(client, messages)
    super(client)
    @client = client
    @messages = messages
  end

  def prompt
    payload = JSON.pretty_generate(@messages)
    [
      {
        role: 'user',
        content: [
          {
            type: 'text',
            text: "Summarize the following conversation messages:\n\n#{payload}"
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
end
