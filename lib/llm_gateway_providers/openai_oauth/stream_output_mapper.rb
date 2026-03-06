# frozen_string_literal: true

require_relative "../usage_normalizer"

module OpenAiOAuth
  # Maps OpenAI Responses API SSE stream events to the normalized format
  # used by the agent (same shape as Claude's streaming events).
  #
  # Responses API event types:
  #   response.output_item.added   — new output item (message, function_call, reasoning)
  #   response.content_part.added  — content part added to a message
  #   response.output_text.delta   — text delta
  #   response.function_call_arguments.delta — tool call arguments delta
  #   response.output_item.done    — output item completed
  #   response.completed           — full response with usage
  class StreamOutputMapper
    def initialize
      @id = nil
      @model = nil
      @content = []
      @current_item_type = nil
      @current_tool = nil
      @usage = {}
    end

    # Process a raw SSE event, return normalized event or nil
    def map_event(sse_event)
      event_type = sse_event[:event]
      data = sse_event[:data]

      return nil if data == { raw: "[DONE]" }

      case event_type
      when "response.created"
        @id = data[:id] if data.is_a?(Hash)
        @model = data[:model] if data.is_a?(Hash)
        nil

      when "response.output_item.added"
        handle_output_item_added(data)

      when "response.content_part.added"
        # A content part added to a message item — we already created the text block
        nil

      when "response.output_text.delta"
        handle_text_delta(data)

      when "response.function_call_arguments.delta"
        handle_function_call_delta(data)

      when "response.output_item.done"
        handle_output_item_done(data)

      when "response.completed"
        handle_completed(data)

      when "response.reasoning_summary_text.delta"
        handle_thinking_delta(data)

      when "error"
        handle_error(data)

      when "response.failed", "response.incomplete"
        handle_response_failure(data)

      else
        nil
      end
    end

    # Return accumulated response in normalized shape
    def to_message
      {
        id: @id,
        model: @model,
        choices: [{
          content: finalized_content
        }],
        usage: @usage
      }
    end

    private

    def handle_output_item_added(data)
      return nil unless data.is_a?(Hash)

      item = data[:item] || data
      case item[:type]
      when "message"
        @current_item_type = "message"
        ensure_text_block
        nil
      when "function_call"
        @current_item_type = "function_call"
        @current_tool = {
          type: "tool_use",
          id: item[:call_id] || item[:id],
          name: item[:name] || "",
          input_json: +""
        }
        @content << @current_tool
        nil
      when "reasoning"
        @current_item_type = "reasoning"
        @content << { type: "thinking", thinking: +"" }
        nil
      else
        nil
      end
    end

    def handle_text_delta(data)
      return nil unless data.is_a?(Hash)

      delta = data[:delta]
      return nil unless delta

      ensure_text_block
      text_block = @content.select { |b| b[:type] == "text" }.last
      text_block[:text] << delta if text_block
      { type: :text_delta, text: delta }
    end

    def handle_thinking_delta(data)
      return nil unless data.is_a?(Hash)

      delta = data[:delta]
      return nil unless delta

      thinking_block = @content.select { |b| b[:type] == "thinking" }.last
      if thinking_block
        thinking_block[:thinking] << delta
        { type: :thinking_delta, thinking: delta }
      end
    end

    def handle_function_call_delta(data)
      return nil unless data.is_a?(Hash)

      delta = data[:delta]
      return nil unless delta && @current_tool

      @current_tool[:input_json] << delta
      nil
    end

    def handle_output_item_done(data)
      return nil unless data.is_a?(Hash)

      item = data[:item] || data
      if item[:type] == "function_call" && @current_tool
        @current_tool[:input] = parse_json(@current_tool[:input_json])
        @current_tool = nil
      elsif item[:type] == "reasoning"
        thinking_block = @content.select { |b| b[:type] == "thinking" }.last
        thinking_block[:signature] = JSON.generate(item) if thinking_block
      end
      nil
    end

    def handle_completed(data)
      return nil unless data.is_a?(Hash)

      response = data[:response] || data
      if response[:usage]
        @usage = UsageNormalizer.normalize(response[:usage])
      end
      @id ||= response[:id]
      @model ||= response[:model]
      nil
    end

    def handle_error(data)
      error = data[:error] || data
      error_type = (error[:type] || "unknown_error").to_s
      error_code = error[:code] || error_type
      error_message = error[:message] || "Unknown streaming error"

      raise_stream_error(error_type, error_code, error_message)
    end

    def handle_response_failure(data)
      response = data[:response] || data
      error = response[:error] || response[:incomplete_details] || {}

      error_type = (error[:type] || response[:status] || "response_failed").to_s
      error_code = error[:code] || error_type
      error_message = error[:message] || "Response failed"

      raise_stream_error(error_type, error_code, error_message)
    end

    def raise_stream_error(error_type, error_code, error_message)
      case error_type
      when "authentication_error", "invalid_api_key"
        raise LlmGateway::Errors::AuthenticationError.new(error_message, error_code)
      when "rate_limit_error", "rate_limit_exceeded", "insufficient_quota"
        raise LlmGateway::Errors::RateLimitError.new(error_message, error_code)
      when "overloaded_error", "server_overloaded", "service_unavailable"
        raise LlmGateway::Errors::OverloadError.new(error_message, error_code)
      when "invalid_request_error", "context_length_exceeded"
        if error_code.to_s == "context_length_exceeded" || error_message.downcase.include?("context window")
          raise LlmGateway::Errors::PromptTooLong.new(error_message, error_code)
        end

        raise LlmGateway::Errors::BadRequestError.new(error_message, error_code)
      else
        raise LlmGateway::Errors::APIStatusError.new(error_message, error_code)
      end
    end

    def ensure_text_block
      if @content.empty? || @content.last[:type] != "text"
        @content << { type: "text", text: +"" }
      end
    end

    def finalized_content
      @content.map do |block|
        case block[:type]
        when "text"
          { type: "text", text: block[:text] }
        when "tool_use"
          {
            type: "tool_use",
            id: block[:id],
            name: block[:name],
            input: block[:input] || parse_json(block[:input_json])
          }
        when "thinking"
          { type: "thinking", thinking: block[:thinking], signature: block[:signature] }
        else
          block
        end
      end
    end

    def parse_json(str)
      return {} if str.nil? || str.empty?
      LlmGateway::Utils.deep_symbolize_keys(JSON.parse(str))
    rescue JSON::ParserError
      {}
    end
  end
end
