# Purpose 
Just an exploration of building my own agent

# Running

```
git clone git@github.com:Hyper-Unearthing/rubister.git
cd rubister
```

Using OpenAI plan
```bash
bundle exec ruby setup_provider.rb openai
./gruv -p openai_oauth_responses
```
Using Anthropic plan
```bash
bundle exec ruby setup_provider.rb anthropic
./gruv -p anthropic_oauth_messages
```

You can set up multiple providers — they'll all be stored in `instance/providers.json`. not sure which will be called by default if you do, but you can always use -p to specify which one

## Logging

Gruv uses an event-based logging system (`lib/logging.rb`) instead of direct `puts` for operational messages.

- Runtime and operational logs are emitted via `Logging.instance.notify(name, payload)`.
- Use scoped names (for example: `daemon.start`, `daemon.message.complete`, `setup.error.provider_not_found`) and include details in the payload hash.
- Logs are written to `instance/logs.jsonl` by `LogFileWriter`.


Each JSONL log entry includes:
- `name` (event name, e.g. `log`, `setup.start`, `daemon.message.complete`)
- `payload` (event data)
- `timestamp`
- `source_location` (`filepath`, `lineno`, `label`) when available

```bash
  # Single message mode
  ./gruv -m "whats this app"
```

```bash
  # Single message mode
  ./gruv -m "whats this app"
```

```bash
  # resume, you can resume in -m or interactive mode
  ./gruv -s sessions/20260224_164714_1846b412-9260-4e18-aa96-c1b67eb93581.jsonl
```

## Distribution

Packaging/distributable tarball flow has been removed.
Run Gruv directly from source with Bundler (`./gruv ...`).
