# Building Tools

Tools are how the agent interacts with the outside world. Each tool is a Ruby class that extends `LlmGateway::Tool`, declares a schema the LLM can understand, and implements an `execute` method. When the LLM decides to use a tool, the agent framework calls `execute` with the parsed input and returns the result string back to the model.

This document covers the architecture, conventions, and patterns for building tools — including how they relate to third-party API clients.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  LLM (Claude, GPT, etc.)                            │
│  Sees tool name, description, and input_schema      │
│  Decides when to call a tool and with what params    │
└──────────────────────┬──────────────────────────────┘
                       │ tool_use
                       ▼
┌─────────────────────────────────────────────────────┐
│  Agent (agent.rb)                                    │
│  Routes tool_use to the correct Tool class           │
│  Calls tool.execute(input), returns result to LLM   │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  Tool (tools/*.rb)                                   │
│  Validates input, orchestrates logic, formats output │
│  Thin layer — delegates API work to clients          │
└──────────────────────┬──────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  Client (lib/clients/*.rb)                           │
│  Handles HTTP, auth, request/response parsing        │
│  Reusable across multiple tools                      │
└─────────────────────────────────────────────────────┘
```

The key separation: **tools are the interface for the LLM**, **clients are the interface for external APIs**. A tool should never contain raw HTTP calls or API-specific logic — that belongs in a client.

---

## Project Structure

```
rubister/
├── config.json                        # API keys, tokens, settings
├── lib/
│   ├── config.rb                      # Config loader (AppConfig module)
│   └── clients/
│       ├── telegram_client.rb         # Telegram Bot API
│       ├── elevenlabs_client.rb       # ElevenLabs TTS API
│       └── assemblyai_client.rb       # AssemblyAI transcription API
├── tools/
│   ├── bash_tool.rb                   # Local tools (no client needed)
│   ├── read_tool.rb
│   ├── edit_tool.rb
│   ├── grep_tool.rb
│   ├── telegram_send_tool.rb          # Uses TelegramClient
│   ├── telegram_send_photo_tool.rb    # Uses TelegramClient
│   ├── telegram_send_voice_tool.rb    # Uses ElevenlabsClient + TelegramClient
│   ├── telegram_get_updates_tool.rb   # Uses TelegramClient
│   ├── telegram_get_me_tool.rb        # Uses TelegramClient
│   ├── telegram_get_photo_tool.rb     # Uses TelegramClient
│   └── telegram_get_voice_tool.rb     # Uses TelegramClient + AssemblyaiClient
└── prompt.rb                          # Registers all tools
```

---

## Building a Tool

### Step 1: Define the Tool Class

Every tool inherits from `LlmGateway::Tool` and declares three class-level attributes:

```ruby
# tools/weather_tool.rb
class WeatherTool < LlmGateway::Tool
  name 'GetWeather'
  description 'Get the current weather for a location.'
  input_schema({
    type: 'object',
    properties: {
      city: { type: 'string', description: 'City name' },
      units: { type: 'string', description: 'celsius or fahrenheit (default: celsius)' }
    },
    required: %w[city]
  })

  def execute(input)
    # input is a Hash with symbolized keys: input[:city], input[:units]
    "Weather in #{input[:city]}: 22°C, sunny"
  end
end
```

| Attribute | Purpose |
|---|---|
| `name` | The tool name the LLM sees and calls. Use PascalCase. Must be unique. |
| `description` | Natural language description. This is what the LLM reads to decide when to use the tool. Be specific about what it does, what formats it accepts, and any gotchas. |
| `input_schema` | JSON Schema object describing parameters. The LLM generates JSON matching this schema. |

### Step 2: Implement `execute`

The `execute` method receives a single `input` hash with **symbolized keys** and must return a **string**. This string is sent back to the LLM as the tool result.

Rules:
- Always return a string, even on errors
- Return useful, concise information the LLM can act on
- Catch exceptions and return human-readable error messages
- Don't puts/print — the return value is the only output

```ruby
def execute(input)
  # Good: returns actionable info
  "Message sent successfully (message_id: 42)"

  # Good: error the LLM can understand and retry
  "Error: City 'Atlantis' not found. Try a real city name."

  # Bad: raises uncaught exception (will crash or produce ugly output)
  # Bad: returns nil
  # Bad: prints to stdout instead of returning
end
```

### Step 3: Register the Tool

Add a require and include the class in the tools array in `prompt.rb`:

```ruby
# prompt.rb
require_relative 'tools/weather_tool'

class Prompt < LlmGateway::Prompt
  def self.tools
    [EditTool, ReadTool, BashTool, GrepTool, WeatherTool]
  end
end
```

That's it — the agent framework handles routing, schema generation, and result passing.

---

## Building a Client

Clients live in `lib/clients/` and encapsulate all interaction with a third-party API. They know nothing about tools or the LLM.

### Client Conventions

1. **Constructor takes credentials** — API key, token, etc.
2. **Methods map to API operations** — `send_message`, `upload`, `transcribe`
3. **Return Ruby objects** — Hashes, strings, binary data. Not formatted strings for the LLM.
4. **Raise typed errors** — Define an `Error` class so tools can rescue specifically.
5. **No config dependency** — Clients receive credentials as constructor args. The tool reads config and passes values in.

### Example Client

```ruby
# lib/clients/weather_client.rb
require 'net/http'
require 'json'
require 'uri'

class WeatherClient
  class Error < StandardError; end

  def initialize(api_key)
    @api_key = api_key
    @base_url = 'https://api.weather.example.com/v1'
  end

  # Returns a Hash: { temp: 22.5, condition: 'sunny', humidity: 45 }
  def current(city, units: 'celsius')
    uri = URI("#{@base_url}/current")
    uri.query = URI.encode_www_form(q: city, units: units, key: @api_key)

    res = Net::HTTP.get_response(uri)
    unless res.code.to_i == 200
      raise Error, "Weather API failed (HTTP #{res.code}): #{res.body[0..200]}"
    end

    data = JSON.parse(res.body)
    {
      temp: data['temperature'],
      condition: data['condition'],
      humidity: data['humidity']
    }
  end
end
```

### Example Tool Using the Client

```ruby
# tools/weather_tool.rb
require_relative '../lib/config'
require_relative '../lib/clients/weather_client'

class WeatherTool < LlmGateway::Tool
  name 'GetWeather'
  description 'Get the current weather for a location.'
  input_schema({
    type: 'object',
    properties: {
      city: { type: 'string', description: 'City name' },
      units: { type: 'string', description: 'celsius or fahrenheit' }
    },
    required: %w[city]
  })

  def execute(input)
    api_key = AppConfig.load.dig('weather', 'api_key')
    return "Error: Weather API key not configured in config.json" if api_key.nil? || api_key.empty?

    client = WeatherClient.new(api_key)
    result = client.current(input[:city], units: input[:units] || 'celsius')

    "#{input[:city]}: #{result[:temp]}°, #{result[:condition]}, humidity #{result[:humidity]}%"
  rescue WeatherClient::Error => e
    "Weather API error: #{e.message}"
  rescue => e
    "Error: #{e.message}"
  end
end
```

Notice the pattern:
1. Read credentials from config
2. Validate credentials exist (fail early with a helpful message)
3. Instantiate the client
4. Call the client method
5. Format the result as a string for the LLM
6. Rescue client-specific errors separately from generic errors

---

## Configuration

All API keys and tokens live in `config.json` at the project root. The `AppConfig` module (`lib/config.rb`) provides typed accessors:

```json
{
  "telegram": {
    "bot_token": "123456:ABC-DEF...",
    "contacts": {
      "12345678": "Alice",
      "87654321": "Bob"
    }
  },
  "elevenlabs": {
    "api_key": "sk_...",
    "voice_id": "IKne3meq5aSn9XLyUdCD"
  },
  "assemblyai": {
    "api_key": "..."
  }
}
```

Adding a new service:

1. Add the key to `config.json`
2. Add an accessor to `lib/config.rb`:
   ```ruby
   def self.weather_api_key
     load.dig('weather', 'api_key')
   end
   ```
3. Use it in your tool: `AppConfig.weather_api_key`

**Never hardcode API keys in tool or client files.** Always read from config.

---

## Patterns

### Simple Tool (No Client Needed)

Some tools don't talk to external APIs — they operate locally. These don't need a client at all.

```ruby
class BashTool < LlmGateway::Tool
  name 'Bash'
  description 'Execute shell commands'
  input_schema({ ... })

  def execute(input)
    `#{input[:command]} 2>&1`
  end
end
```

### Single-Client Tool

Most tools wrap a single client. This is the common case.

```ruby
# Tool structure:
#   1. Get config
#   2. Create client
#   3. Call client method
#   4. Format result string

def execute(input)
  client = TelegramClient.new(AppConfig.telegram_token)
  result = client.send_message(chat_id: input[:chat_id], text: input[:message])
  "Sent (message_id: #{result['message_id']})"
end
```

### Multi-Client Pipeline Tool

Some tools orchestrate multiple clients in sequence. Each step's output feeds into the next.

`TelegramSendVoice` is the canonical example:

```
ElevenlabsClient.text_to_speech(text)     → MP3 binary
  ↓
ffmpeg (local shell)                       → OGG binary
  ↓
TelegramClient.send_voice(ogg_data)        → message_id
```

```ruby
def execute(input)
  # Client 1: ElevenLabs
  tts = ElevenlabsClient.new(AppConfig.elevenlabs_api_key)
  mp3_data = tts.text_to_speech(input[:message])

  # Local processing
  ogg_data = convert_mp3_to_ogg(mp3_data)

  # Client 2: Telegram
  telegram = TelegramClient.new(AppConfig.telegram_token)
  result = telegram.send_voice(chat_id: input[:chat_id], audio_data: ogg_data)

  "Voice message sent (message_id: #{result['message_id']})"
end
```

Similarly, `TelegramGetVoice` chains Telegram → AssemblyAI:

```ruby
def execute(input)
  telegram = TelegramClient.new(AppConfig.telegram_token)
  file_result = telegram.download_file(input[:file_id])

  aai = AssemblyaiClient.new(AppConfig.assemblyai_api_key)
  aai.upload_and_transcribe(file_result[:data])
end
```

The key rule: **each client handles its own API**. The tool is the glue between them.

### Client Reuse Across Tools

A single client can serve many tools. `TelegramClient` is used by 7 different tools — each calling different methods on the same client class:

| Tool | Client Method |
|---|---|
| `TelegramSend` | `client.send_message` |
| `TelegramSendPhoto` | `client.send_photo` |
| `TelegramSendVoice` | `client.send_voice` |
| `TelegramGetUpdates` | `client.get_updates` |
| `TelegramGetMe` | `client.get_me` |
| `TelegramGetPhoto` | `client.download_photo_base64` |
| `TelegramGetVoice` | `client.download_file` |

This is the main benefit of the client/tool split — the HTTP, auth, and parsing logic is written once.

---

## Error Handling

Tools should **never crash**. The LLM needs a string back, even when things fail. Layer your rescues from most specific to least:

```ruby
def execute(input)
  # ... do work ...
rescue TelegramClient::APIError => e
  # API returned an error (e.g., chat not found, rate limited)
  "Telegram API error: #{e.description}"
rescue ElevenlabsClient::Error => e
  # Third-party service failed
  "ElevenLabs error: #{e.message}"
rescue => e
  # Unexpected failure (network timeout, bug, etc.)
  "Error: #{e.message}"
end
```

Client error classes should carry useful context:

```ruby
class TelegramClient
  class APIError < Error
    attr_reader :error_code, :description
    def initialize(error_code, description)
      @error_code = error_code
      @description = description
      super("Telegram API error #{error_code}: #{description}")
    end
  end
end
```

---

## Writing Good Descriptions

The `description` string is the most important part of a tool. The LLM reads it to decide when and how to use the tool. Tips:

- **State what it does**, not how it works internally
- **Mention input formats** if they're not obvious (e.g., "accepts base64 or file path")
- **Call out gotchas** (e.g., "use HTML parse_mode for ASCII art")
- **Keep it to 1-2 sentences** — the schema provides parameter-level detail

```ruby
# Good
description 'Send a text message to a Telegram chat. For ASCII art, use parse_mode "HTML" and wrap in <pre></pre> tags.'

# Bad (too vague)
description 'Send a message'

# Bad (implementation detail the LLM doesn't need)
description 'Uses Net::HTTP to POST to api.telegram.org/bot/sendMessage with JSON body'
```

---

## Input Schema Design

The `input_schema` follows [JSON Schema](https://json-schema.org/) format. The LLM uses it to generate valid input.

```ruby
input_schema({
  type: 'object',
  properties: {
    chat_id:             { type: 'string',  description: 'Chat ID or username' },
    message:             { type: 'string',  description: 'Message text' },
    parse_mode:          { type: 'string',  description: 'Markdown, MarkdownV2, or HTML' },
    reply_to_message_id: { type: 'integer', description: 'Message ID to reply to' }
  },
  required: %w[chat_id message]
})
```

Guidelines:
- Use `description` on every property — the LLM reads these
- Only put truly mandatory params in `required`
- Use the right `type` — `string`, `integer`, `boolean`, `number`
- For enums, mention valid values in the description (the LLM understands this)

---

## Checklist for Adding a New Tool

1. **Does it need an external API?** → Create a client in `lib/clients/`
2. **Does the API need credentials?** → Add them to `config.json` and `lib/config.rb`
3. **Create the tool** in `tools/` — thin layer that delegates to the client
4. **Register the tool** in `prompt.rb` (require + add to tools array)
5. **Test it loads**: `ruby -e "require 'bundler/setup'; require 'llm_gateway'; require_relative 'prompt'; puts Prompt.tools.map { |t| t.definition[:name] }"`

---

## Summary

| Layer | Location | Responsibility | Knows about |
|---|---|---|---|
| **Config** | `config.json` + `lib/config.rb` | Store and load credentials | Nothing else |
| **Client** | `lib/clients/*.rb` | HTTP, auth, request/response | The third-party API |
| **Tool** | `tools/*.rb` | Schema, orchestration, formatting | Config + clients |
| **Prompt** | `prompt.rb` | Registration | Tool classes |
| **Agent** | `agent.rb` | Routing | Tool classes (via prompt) |

Keep tools thin. Keep clients reusable. Keep credentials in config.
