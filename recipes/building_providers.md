# Building Providers on llm_gateway

How to build a new LLM provider by extending `llm_gateway`'s base building blocks. Uses the [OpenAI Codex provider](openai_codex_integration.md) as a concrete example.

## Architecture

```
┌──────────────────────────────────────────────┐
│                   Agent                       │
│  (provider-agnostic, uses normalized format)  │
└──────────────┬───────────────────────────────┘
               │
┌──────────────▼───────────────────────────────┐
│              Adapter                          │
│  input_mapper  →  client  →  output_mapper    │
│                           →  stream_mapper    │
└──────────────────────────────────────────────┘
```

The `llm_gateway` gem provides a layered architecture:

1. **`BaseClient`** — HTTP transport, SSE parsing, error handling
2. **`Clients::OpenAi`** — OpenAI-specific base URL + headers + error codes
3. **`Adapters::Adapter`** — Wires together client + input/output mappers
4. **Input/Output Mappers** — Transform between normalized and provider-specific formats

A provider needs to supply an **Adapter** that combines a **Client** (HTTP transport) with **mappers** (format translation). The agent only sees the normalized format and never deals with provider specifics.

## Available Base Components

| Component | Module | Purpose |
|---|---|---|
| `BaseClient` | `LlmGateway::Clients::BaseClient` | HTTP POST, SSE stream parsing (`parse_sse_stream`), error handling |
| `Clients::OpenAi` | `LlmGateway::Clients::OpenAi` | OpenAI error code handling (429 → RateLimitError, etc.) |
| `Adapters::Adapter` | `LlmGateway::Adapters::Adapter` | Orchestration: normalize input → call client → map output |
| `Responses::InputMapper` | `LlmGateway::Adapters::OpenAi::Responses::InputMapper` | Converts normalized messages to Responses API `input` format |

## What to Implement

Every provider needs these pieces:

### 1. Client

The client handles HTTP transport and request construction. Extend an existing client or `BaseClient`:

| Override | Purpose |
|---|---|
| `@base_endpoint` | Point to the provider's API URL |
| `build_headers` | Provider-specific auth and content headers |
| `chat(messages, tools:, system:, &block)` | Build the request body, call `post_stream` |

**Example** (OpenAI Codex — see [full details](openai_codex_integration.md)):

```ruby
class Client < LlmGateway::Clients::OpenAi
  def initialize(...)
    super(model_key: model_key, api_key: access_token)
    # Override the base endpoint after super
    @base_endpoint = "https://chatgpt.com/backend-api/codex"
  end

  def chat(messages, tools:, system:, &block)
    instructions = system.map { |s| s[:content] }.join("\n")

    body = {
      model: model_key,
      instructions: instructions,
      input: messages,
      store: false
    }
    body[:tools] = tools if tools

    body[:stream] = true if block_given?
    post_stream("responses", body, &block)
  end

  def build_headers
    {
      "content-type" => "application/json",
      "Authorization" => "Bearer #{@oauth_access_token}",
      "OpenAI-Beta" => "responses=experimental",
      "chatgpt-account-id" => @account_id
    }
  end
end
```

Key insight: `@base_endpoint` must be set **after** calling `super` because the parent constructor sets it to its own default.

### 2. Stream Output Mapper

Maps provider-specific SSE events to the normalized event format the agent consumes:

```ruby
# SSE event from API:
{ event: "response.output_text.delta", data: { delta: "Hello" } }

# Mapped to normalized event:
{ type: :text_delta, text: "Hello" }
```

The mapper must also implement `to_message` to produce a final accumulated message:

```ruby
{
  choices: [{
    content: [
      { type: "text", text: "Hello! How can I help?" },
      { type: "tool_use", id: "call_123", name: "bash", input: { command: "ls" } }
    ]
  }],
  usage: { input_tokens: 50, output_tokens: 20 }
}
```

### 3. Output Mapper

After streaming completes, the adapter calls `output_mapper.map(stream_mapper.to_message)`. If your stream mapper's `to_message` already returns the normalized format, use a passthrough:

```ruby
class PassthroughOutputMapper
  def self.map(message)
    message
  end
end
```

Using the standard `Responses::OutputMapper` would fail in this case because it expects `output` (raw API format) not `choices` (normalized format).

### 4. Adapter

Wires the client and mappers together:

```ruby
class Adapter < LlmGateway::Adapters::Adapter
  def initialize(client)
    super(
      client,
      input_mapper: LlmGateway::Adapters::OpenAi::Responses::InputMapper,
      output_mapper: PassthroughOutputMapper,
      stream_output_mapper: StreamOutputMapper
    )
  end
end
```

### 5. Token Management (if applicable)

If the provider uses OAuth or expiring tokens, wrap the refresh logic:

```ruby
# Before every API call:
def ensure_valid_token
  refresh_access_token! if token_expired?
end
```

The client should call `ensure_valid_token` at the start of `chat()` and retry on `AuthenticationError`.

## Deciding What to Reuse vs Override

Start by identifying the closest existing client:

- **OpenAI-compatible API** → extend `Clients::OpenAi` (gets error code mapping for free)
- **Completely different API** → extend `BaseClient` (gets HTTP + SSE parsing)

Then decide on mappers:

- **Standard OpenAI Responses format** → reuse `Responses::InputMapper` and `Responses::OutputMapper`
- **Standard OpenAI Chat Completions format** → reuse the Chat Completions mappers
- **Custom stream format** → write your own `StreamOutputMapper`
- **Custom request format** → override `chat()` in the client

## Provider Registration

Providers are registered with `LlmGateway::ProviderRegistry` so they can be built generically via `LlmGateway.build_provider`. Registration maps a provider name to its **Client** class and **Adapter** class:

```ruby
LlmGateway::ProviderRegistry.register("my_provider_responses",
  client: MyProvider::Client,
  adapter: MyProvider::Adapter)
```

This is typically done at the top level of the entry-point file (e.g. `lib/my_provider.rb`), right after requiring the provider's classes.

**Example** (OpenAI OAuth provider):

```ruby
# lib/openai_oauth.rb
require_relative "llm_gateway_providers/openai_oauth/client"
require_relative "llm_gateway_providers/openai_oauth/adapter"
# ... other requires ...

module OpenAiOAuth
  def self.login
    flow = OAuthFlow.new
    flow.login
  end
end

LlmGateway::ProviderRegistry.register("openai_oauth_responses",
  client: OpenAiOAuth::Client,
  adapter: OpenAiOAuth::Adapter)
```

Built-in providers in `llm_gateway` are registered the same way:

```ruby
LlmGateway::ProviderRegistry.register("anthropic_apikey_messages",
  client: Clients::Claude,
  adapter: Adapters::Claude::MessagesAdapter)

LlmGateway::ProviderRegistry.register("openai_apikey_responses",
  client: Clients::OpenAi,
  adapter: Adapters::OpenAi::ResponsesAdapter)
```

## Provider Initialization

Providers are initialized via `LlmGateway.build_provider(config)`. The config is a hash that **must** include a `"provider"` key matching the registered name. All other keys are passed as keyword arguments to the Client constructor:

```ruby
config = {
  "provider" => "openai_oauth_responses",
  "model_key" => "gpt-5.1-codex-mini",
  "access_token" => "eyJ...",
  "refresh_token" => "rt_...",
  "expires_at" => 1772434168,
  "account_id" => "6f6473c8-..."
}

client = LlmGateway.build_provider(config)
agent = Agent.new(Prompt, model, client)
```

Under the hood, `build_provider` does:

1. Extracts the `provider` key from the config
2. Resolves the registered Client and Adapter classes via `ProviderRegistry.resolve`
3. Instantiates the Client with the remaining config as keyword arguments: `entry[:client].new(**config)`
4. Wraps it in the Adapter: `entry[:adapter].new(client)`

This means your **Client's `initialize` must accept keyword arguments matching the config keys** from your `providers.json` (e.g. `model_key:`, `access_token:`, `refresh_token:`, etc.).

### Configuration via `providers.json`

In practice, provider configs are stored in a `providers.json` file. Each top-level key is the registered provider name, and its value contains the constructor arguments:

```json
{
  "openai_oauth_responses": {
    "model_key": "gpt-5.1-codex-mini",
    "access_token": "eyJ...",
    "refresh_token": "rt_...",
    "expires_at": 1772434168,
    "account_id": "6f6473c8-..."
  },
  "anthropic_oauth_messages": {
    "model_key": "claude_code/claude-sonnet-4-5",
    "access_token": "sk-ant-...",
    "refresh_token": "sk-ant-ort01-...",
    "expires_at": 1771598923
  }
}
```

The agent runner merges the provider name into the config and passes it to `build_provider`:

```ruby
config = provider_config.merge("provider" => name)
client = LlmGateway.build_provider(config)
```

## File Structure Convention

Place provider code under `lib/llm_gateway_providers/<provider_name>/`:

```
lib/llm_gateway_providers/<provider_name>/
├── client.rb              # HTTP client
├── stream_output_mapper.rb # SSE → normalized events
├── adapter.rb             # Wires client + mappers together
├── token_manager.rb       # Token refresh (if needed)
└── oauth_flow.rb          # OAuth login (if needed)
```

With an entry point at `lib/<provider_name>.rb` that requires the individual files and registers the provider with `LlmGateway::ProviderRegistry`.
