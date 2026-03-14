# frozen_string_literal: true

require 'json'
require_relative '../writer_registry'
require_relative '../errors'

class SendPhotoTool < LlmGateway::Tool
  name 'SendPhoto'
  description 'Send a photo to Telegram or Discord using a unified interface.'
  input_schema({
    type: 'object',
    properties: {
      platform: { type: 'string', enum: %w[telegram discord], description: 'Platform to send to' },
      channel_id: { type: 'string', description: 'Telegram chat_id or Discord channel_id' },
      photo: { type: 'string', description: 'Local file path or base64:...' },
      caption: { type: 'string', description: 'Photo caption/message content' },
      reply_to_message_id: { type: 'string', description: 'Reply target message id (Telegram/Discord mapping handled automatically)' }
    },
    required: ['platform', 'channel_id', 'photo']
  })

  def execute(input)
    platform = input[:platform]

    sender = WriterRegistry.for_platform(platform)
    return JSON.generate({ ok: false, error: "Platform '#{platform}' not configured" }) unless sender

    result = sender.send_photo(
      channel_id: input[:channel_id],
      photo_input: input[:photo],
      caption: input[:caption],
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
