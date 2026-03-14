# frozen_string_literal: true

require 'json'
require_relative '../writer_registry'
require_relative '../errors'

class SendMessageTool < LlmGateway::Tool
  name 'SendMessage'
  description <<~DESC
    Send a text message to Telegram or Discord using a unified interface.

    When replying to an inbox message, map fields as follows:
      platform             <- msg[:platform]
      channel_id           <- msg[:channel_id]
      message              <- (the reply text you compose)
      reply_to_message_id  <- msg[:provider_message_id]  (optional, threads the reply)
      parse_mode           <- set explicitly if needed (Telegram only, not in inbox)
  DESC

  input_schema({
    type: 'object',
    properties: {
      platform: { type: 'string', enum: %w[telegram discord], description: 'Platform to send to' },
      channel_id: { type: 'string', description: 'Unified destination id: Telegram chat_id or Discord channel_id' },
      message: { type: 'string', description: 'Text to send' },
      reply_to_message_id: { type: 'string', description: 'Reply target message id (Telegram/Discord mapping handled automatically)' },
      parse_mode: { type: 'string', description: 'Telegram-only parse mode (Markdown/HTML)' }
    },
    required: ['platform', 'channel_id', 'message']
  })

  def execute(input)
    platform = input[:platform]
    channel_id = input[:channel_id]
    message = input[:message]

    return JSON.generate({ ok: false, error: 'Missing platform' }) if platform.nil? || platform.strip.empty?
    return JSON.generate({ ok: false, error: 'Missing channel_id' }) if channel_id.nil? || channel_id.strip.empty?
    return JSON.generate({ ok: false, error: 'Missing message' }) if message.nil? || message.strip.empty?

    sender = WriterRegistry.for_platform(platform)
    return JSON.generate({ ok: false, error: "Platform '#{platform}' not configured" }) unless sender

    reply_to = input[:reply_to_message_id]
    reply_to = nil if reply_to && reply_to.strip.empty?

    result = sender.send_message(
      channel_id: channel_id,
      message: message,
      reply_to_message_id: reply_to,
      parse_mode: input[:parse_mode]
    )

    JSON.generate({ ok: true, platform: platform, **result })
  rescue APIError => e
    JSON.generate({ ok: false, platform: platform, error: e.message })
  rescue => e
    JSON.generate({ ok: false, platform: platform, error: e.message })
  end
end
