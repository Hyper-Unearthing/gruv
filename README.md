# Purpose 
Just an exploration of building my own agent

# Running

```
git clone git@github.com:Hyper-Unearthing/gruv.git
cd gruv
```

Run the unified setup wizard (can be run multiple times safely):
```bash
bundle exec ruby setup.rb
```

The wizard lets you pick which things to configure:
- **Anthropic / OpenAI** — OAuth flow; re-running the same provider refreshes tokens while
  preserving model and reasoning settings unless you change them
- **Telegram** — bot token
- **Discord** — bot token, app credentials, install URL generation
- **AssemblyAI** — transcription API key

Config is written to `instance/config.json` and `instance/providers.json`.

After setup, run gruv with your chosen provider:
```bash
./gruv -p openai_oauth_responses
./gruv -p anthropic_oauth_messages
```

You can set up multiple providers — they'll all be stored in `instance/providers.json`. Use `-p` to specify which one.

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
  # interactive mode
  ./gruv
```

```bash
  # Single message mode
  ./gruv -m "whats this app"
```

```bash
  # Resume a session (works in -m or interactive mode)
  ./gruv -s sessions/20260224_164714_1846b412-9260-4e18-aa96-c1b67eb93581.jsonl
```

```bash
  # Daemon mode (supervisor): starts ALL
  # 1) daemon worker (inbox reader/agent)
  # 2) registered writers (inbox writer)
  ./gruv --daemon                    # Poll every 1 second (default)
  ./gruv --daemon --poll-interval 5  # Poll every 5 seconds
```

Capability configs are set here `instance/config.json`


Ctrl+C (`SIGINT`) on `./gruv --daemon` interrupts all child processes.

## Cron job conventions

Gruv can manage cron jobs via bash/`crontab`. To keep scheduling safe and maintainable:

- Only manage entries marked with a Gruv job marker comment:
  - `# gruv:job_id=<id>`
- Do not edit unrelated crontab entries.
- Reuse/update an existing `job_id` instead of creating duplicates.
- Prefer checked-in scripts over complex inline cron commands.
- Capture output to logs so runs can be inspected.
- Default notifications to failure-only. Notify on success only when agent follow-up is needed.
- After creating/updating a cron entry, verify with `crontab -l` and manually test the target script.

Example:

```cron
# gruv:job_id=daily_inbox_summary
0 9 * * * /app/gruv/scripts/daily_inbox_summary.sh >> /app/gruv/instance/logs/cron_daily_inbox_summary.log 2>&1
```

## Inbox System

Gruv includes a SQLite-backed inbox for message processing with priority-based queuing and daemon mode.

**📚 Full documentation**: [docs/INBOX_INDEX.md](docs/INBOX_INDEX.md)

## Database migrations (SQLite + ActiveRecord)

Database file:
- `instance/gruv.sqlite3`

Migration files:
- `db/migrate/*.rb`

Install deps (once):
```bash
bundle install
```

Create a migration:
```bash
bundle exec ruby db_tool.rb new create_users
```

Run migrations:
```bash
bundle exec ruby db_tool.rb migrate
```

Rollback one step:
```bash
bundle exec ruby db_tool.rb rollback
```

Useful commands:
```bash
bundle exec ruby db_tool.rb status
bundle exec ruby db_tool.rb version
bundle exec ruby db_tool.rb migrate 20260224130000   # migrate to specific version
bundle exec ruby db_tool.rb rollback 2               # rollback 2 steps
DB_LOG=1 bundle exec ruby db_tool.rb migrate         # show SQL logs
```

## Distribution

Packaging/distributable tarball flow has been removed.
Run Gruv directly from source with Bundler (`./gruv ...`).
