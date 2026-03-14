# frozen_string_literal: true

require 'json'
require_relative '../writer_registry'
require_relative '../errors'

class SendDocumentTool < LlmGateway::Tool
  def self.platform_tool? = true

  name 'SendDocument'
  description 'Send a document to Telegram or Discord using a unified interface.'
  input_schema({
    type: 'object',
    properties: {
      platform: { type: 'string', enum: %w[telegram discord], description: 'Platform to send to' },
      channel_id: { type: 'string', description: 'Telegram chat_id or Discord channel_id' },
      document: { type: 'string', description: 'Local file path or base64:...' },
      caption: { type: 'string', description: 'Document caption/message content' },
      filename: { type: 'string', description: 'Override filename (optional, auto-detected from path)' },
      reply_to_message_id: { type: 'string', description: 'Reply target message id (Telegram/Discord mapping handled automatically)' }
    },
    required: ['platform', 'channel_id', 'document']
  })

  def execute(input)
    platform = input[:platform]

    sender = WriterRegistry.for_platform(platform)
    return JSON.generate({ ok: false, error: "Platform '#{platform}' not configured" }) unless sender

    result = sender.send_document(
      channel_id: input[:channel_id],
      document_input: input[:document],
      caption: input[:caption],
      filename: input[:filename],
      parse_mode: input[:parse_mode],
      reply_to_message_id: input[:reply_to_message_id]
    )

    JSON.generate({ ok: true, platform: platform, **result })
  rescue APIError => e
    JSON.generate({ ok: false, platform: platform, error: e.message })
  rescue => e
    JSON.generate({ ok: false, platform: platform, error: e.message })
  end
end
