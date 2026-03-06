# frozen_string_literal: true

module UsageNormalizer
  # Normalizes provider-specific usage hashes into a unified schema:
  #
  #   input_tokens      — non-cached input tokens billed at full price
  #   output_tokens     — output tokens
  #   cache_read_tokens — tokens served from cache (cheaper)
  #   cache_write_tokens — tokens written to cache (Anthropic only, 0 for OpenAI)
  #   total_tokens      — input + cache_read + cache_write + output
  #
  # Anthropic raw keys: input_tokens, cache_read_input_tokens,
  #                     cache_creation_input_tokens, output_tokens
  #
  # OpenAI raw keys: input_tokens, input_tokens_details: { cached_tokens },
  #                  output_tokens, total_tokens
  def self.normalize(usage)
    return nil unless usage

    if usage.key?(:cache_read_tokens) || usage.key?(:cache_write_tokens)
      normalize_unified(usage)
    elsif usage.key?(:cache_read_input_tokens) || usage.key?(:cache_creation_input_tokens)
      normalize_anthropic(usage)
    else
      normalize_openai(usage)
    end
  end

  def self.normalize_unified(usage)
    input       = usage[:input_tokens] || 0
    cache_read  = usage[:cache_read_tokens] || 0
    cache_write = usage[:cache_write_tokens] || 0
    output      = usage[:output_tokens] || 0

    {
      input_tokens:       input,
      output_tokens:      output,
      cache_read_tokens:  cache_read,
      cache_write_tokens: cache_write,
      total_tokens:       input + cache_read + cache_write + output
    }
  end

  def self.normalize_anthropic(usage)
    input       = usage[:input_tokens] || 0
    cache_read  = usage[:cache_read_input_tokens] || 0
    cache_write = usage[:cache_creation_input_tokens] || 0
    output      = usage[:output_tokens] || 0

    {
      input_tokens:       input,
      output_tokens:      output,
      cache_read_tokens:  cache_read,
      cache_write_tokens: cache_write,
      total_tokens:       input + cache_read + cache_write + output
    }
  end

  def self.normalize_openai(usage)
    input_total = usage[:input_tokens] || 0
    cache_read  = usage.dig(:input_tokens_details, :cached_tokens) || 0
    input       = input_total - cache_read
    output      = usage[:output_tokens] || 0

    {
      input_tokens:       input,
      output_tokens:      output,
      cache_read_tokens:  cache_read,
      cache_write_tokens: 0,
      total_tokens:       input + cache_read + output
    }
  end
end
