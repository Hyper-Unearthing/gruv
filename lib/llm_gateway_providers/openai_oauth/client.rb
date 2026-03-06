# frozen_string_literal: true

require "llm_gateway"
require_relative "oauth_flow"
require_relative "token_manager"
require_relative "stream_output_mapper"

module OpenAiOAuth
  # OpenAI OAuth client that uses the OpenAI Chat Completions API
  # with OAuth bearer tokens (ChatGPT Plus/Pro subscription).
  #
  # Extends LlmGateway::Clients::OpenAi for the API format,
  # adds OAuth token management on top.
  class Client < LlmGateway::Clients::OpenAi
    attr_reader :token_manager, :account_id
    attr_accessor :prompt_cache_key

    def initialize(
      model_key: "gpt-5.1-codex-mini",
      access_token: nil,
      refresh_token: nil,
      expires_at: nil,
      account_id: nil,
      client_id: OAuthFlow::CLIENT_ID,
      reasoning_effort: nil
    )
      @reasoning_effort = reasoning_effort

      if refresh_token
        @token_manager = TokenManager.new(
          access_token: access_token,
          refresh_token: refresh_token,
          expires_at: expires_at,
          account_id: account_id,
          client_id: client_id
        )
        @token_manager.ensure_valid_token if access_token.nil?
        access_token = @token_manager.access_token
        @account_id = @token_manager.account_id
      end

      @oauth_access_token = access_token
      @account_id = account_id || @account_id

      # Initialize parent with the access token as api_key
      # ChatGPT Plus OAuth tokens must hit the ChatGPT backend, not api.openai.com
      super(model_key: model_key, api_key: access_token)
      @base_endpoint = "https://chatgpt.com/backend-api/codex"
    end

    # Delegate token refresh callback
    def on_token_refresh=(callback)
      @token_manager&.on_token_refresh = callback
    end

    def chat(messages, response_format: { type: "text" }, tools: nil, system: [], max_completion_tokens: 4096, &block)
      ensure_valid_token

      # Extract instructions from system messages
      instructions = (system || []).map { |s| s[:content] }.compact.join("\n")
      instructions = "You are a helpful assistant." if instructions.empty?

      body = {
        model: model_key,
        instructions: instructions,
        input: messages,
        store: false,
        include: ["reasoning.encrypted_content"]
      }
      body[:prompt_cache_key] = @prompt_cache_key if @prompt_cache_key
      body[:prompt_cache_retention] = "24h" if @prompt_cache_key
      body[:tools] = tools if tools
      body[:reasoning] = { effort: @reasoning_effort, summary: 'detailed' } if @reasoning_effort

      # Codex OAuth backend currently requires streaming mode.
      body[:stream] = true

      if block_given?
        post_stream_with_retry("responses", body, &block)
      else
        stream_mapper = StreamOutputMapper.new

        post_stream_with_retry("responses", body) do |raw_sse|
          stream_mapper.map_event(raw_sse)
        end

        stream_mapper.to_message
      end
    end

    private

    def ensure_valid_token
      return unless @token_manager

      @token_manager.ensure_valid_token
      @oauth_access_token = @token_manager.access_token
      @account_id = @token_manager.account_id
    end

    def post_with_retry(url_part, body = nil, extra_headers = {})
      post(url_part, body, extra_headers)
    rescue LlmGateway::Errors::AuthenticationError => e
      raise e unless @token_manager&.token_expired?

      @token_manager.refresh_access_token!
      @oauth_access_token = @token_manager.access_token
      post(url_part, body, extra_headers)
    end

    def post_stream_with_retry(url_part, body = nil, extra_headers = {}, &block)
      post_stream(url_part, body, extra_headers, &block)
    rescue LlmGateway::Errors::AuthenticationError => e
      raise e unless @token_manager&.token_expired?

      @token_manager.refresh_access_token!
      @oauth_access_token = @token_manager.access_token
      post_stream(url_part, body, extra_headers, &block)
    end

    def build_headers
      headers = {
        "content-type" => "application/json",
        "Authorization" => "Bearer #{@oauth_access_token}",
        "OpenAI-Beta" => "responses=experimental"
      }
      headers["chatgpt-account-id"] = @account_id if @account_id
      headers
    end
  end
end
