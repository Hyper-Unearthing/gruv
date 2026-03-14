# frozen_string_literal: true

require 'json'
require_relative '../writer_registry'
require_relative '../errors'

class GetMeTool < LlmGateway::Tool
  name 'GetMe'
  description 'Get bot identity for Telegram or Discord using a unified interface.'
  input_schema({
    type: 'object',
    properties: {
      platform: { type: 'string', enum: %w[telegram discord], description: 'Platform to query' }
    },
    required: ['platform']
  })

  def execute(input)
    platform = input[:platform]

    sender = WriterRegistry.for_platform(platform)
    return JSON.generate({ ok: false, error: "Platform '#{platform}' not configured" }) unless sender

    bot = sender.get_me
    JSON.generate({ ok: true, platform: platform, bot: bot })
  rescue APIError => e
    JSON.generate({ ok: false, platform: platform, error: e.message })
  rescue => e
    JSON.generate({ ok: false, platform: platform, error: e.message })
  end
end
