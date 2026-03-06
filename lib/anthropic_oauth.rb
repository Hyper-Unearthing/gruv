# frozen_string_literal: true

require "llm_gateway"
require_relative "llm_gateway_providers/anthropic_oauth/client"

module AnthropicOAuth
end

# Override the built-in anthropic_oauth_messages registration so reasoning_effort
# is handled by this repository's client rather than LlmGateway::Clients::ClaudeCode.
LlmGateway::ProviderRegistry.register("anthropic_oauth_messages",
  client: AnthropicOAuth::Client,
  adapter: LlmGateway::Adapters::ClaudeCode::MessagesAdapter)
