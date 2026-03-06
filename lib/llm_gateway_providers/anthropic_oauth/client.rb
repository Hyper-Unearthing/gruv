# frozen_string_literal: true

require "llm_gateway"

module AnthropicOAuth
  # Extends LlmGateway::Clients::ClaudeCode with reasoning_effort support.
  #
  # ClaudeCode uses OAuth tokens and the Anthropic API directly.
  # This client adds extended thinking (budget_tokens) when reasoning_effort
  # is set, using the same low/medium/high → budget_tokens mapping as
  # LlmGateway::Clients::Claude#build_thinking_config.
  class Client < LlmGateway::Clients::ClaudeCode
    def initialize(reasoning_effort: nil, **kwargs)
      super(**kwargs)
      # Must be set after super: Claude#initialize also sets @reasoning_effort = nil
      # (its default), which would overwrite any value we set before calling super.
      @reasoning_effort = reasoning_effort
    end

    def chat(messages, response_format: { type: "text" }, tools: nil, system: [], max_completion_tokens: 4096, &block)
      ensure_valid_token

      body = {
        model: model_key,
        max_tokens: max_completion_tokens,
        messages: messages
      }

      body.merge!(tools: tools) if LlmGateway::Utils.present?(tools)

      system = prepend_claude_code_identity(system)
      body.merge!(system: system) if LlmGateway::Utils.present?(system)

      body.merge!(thinking: build_thinking_config) if @reasoning_effort

      if block_given?
        body[:stream] = true
        post_stream_with_retry("messages", body, &block)
      else
        post_with_retry("messages", body)
      end
    end

    private

    REASONING_EFFORT_BUDGET_TOKENS = {
      "low" => 1024,
      "medium" => 5000,
      "high" => 10000
    }.freeze

    def build_thinking_config
      budget_tokens = if @reasoning_effort.is_a?(Integer)
        @reasoning_effort
      else
        REASONING_EFFORT_BUDGET_TOKENS[@reasoning_effort.to_s] ||
          raise(ArgumentError, "Invalid reasoning_effort '#{@reasoning_effort}'. Use 'low', 'medium', 'high', or an integer.")
      end

      { type: "enabled", budget_tokens: budget_tokens }
    end

    def build_headers
      beta_flags = "claude-code-20250219,oauth-2025-04-20"
      beta_flags += ",interleaved-thinking-2025-05-14" if @reasoning_effort

      {
        "anthropic-version" => "2023-06-01",
        "content-type" => "application/json",
        "Authorization" => "Bearer #{access_token}",
        "anthropic-dangerous-direct-browser-access" => "true",
        "anthropic-beta" => beta_flags,
        "user-agent" => "claude-cli/#{LlmGateway::Clients::ClaudeCode::CLAUDE_CODE_VERSION} (external, cli)",
        "x-app" => "cli"
      }
    end
  end
end
