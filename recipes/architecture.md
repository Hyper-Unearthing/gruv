# Gruv Architecture

## Implementation Scope (Authoritative)

This architecture is implemented by extending the existing rubister codebase in this repository.

- `./gruv` is the user-facing command, implemented as an entrypoint/wrapper over existing project internals.
- Do not create or treat this as a separate standalone project.
- Reuse and extend existing modules, patterns, and runtime conventions already present in the repository.
- Configuration and runtime data locations must follow this project’s existing conventions (do not introduce alternate app-specific roots unless explicitly specified below).
- Documents in `recipes/` define how components should be implemented; `recipes/architecture.md` is the root document and source of truth.

## Overview

Gruv runs as a daemon by default. A single `./gruv` command starts everything: a background thread handles Telegram polling while the main loop reads pending messages from a SQLite inbox, processes them through the agent, and sends responses back.

Writers (background thread, clone workers, cron jobs) INSERT into the database independently. The main loop only reads.

```
  WRITERS (thread, child processes, cron)              READER (main loop)
 ┌──────────────────────────────────────┐         ┌──────────────────────┐
 │ Telegram poller thread (long poll)   │──┐      │                      │
 │ Clone wrapper (on child exit)        │──┤      │   gruv main loop     │
 │ Cron jobs (gruv-managed)             │──┤      │                      │
 └──────────────────────────────────────┘  │      │                      │
                                           │      │                      │
                                      INSERT│  ┌───────────┐              │
                                           └─►│  gruv.db  │              │
                                              │ messages  │◄─── SELECT   │
                                              │ contacts  │     pending  │
                                              │ tasks     │              │
                                              └───────────┘              │
                                                   │      │  UPDATE      │
                                                   │      │  processed   │
                                                   │      └──────────────┘
                                                   │
                                              ./gruv.db
```

---

## Modes

```bash
./gruv                              # daemon mode (default)
./gruv -i                           # interactive REPL mode
./gruv -p "prompt"                  # one-shot prompt mode
./gruv -a --task-id <id>            # async clone worker mode (reads task from gruv.db)
```

One command to start. No cron jobs needed at launch. Gruv can set up its own cron jobs later for system messages.

### Output Formatting (Interactive/Prompt Modes)

Gruv supports **internal, pluggable output formatting** for non-daemon runs, so formatting does not require shell piping.

```bash
./gruv -i                        # defaults to stream formatter
./gruv -i --formatter stream     # explicit stream formatter
./gruv -p "hello" --formatter raw
```

- Formatter selection is done with `--formatter <name>`.
- Built-in formatters:
  - `raw` — prints event hashes as-is (legacy behavior)
  - `stream` — renders streaming deltas, tool calls, and results in a human-friendly terminal format (equivalent style to `format_stream.rb`)
- Default behavior:
  - `./gruv -i` → `stream`
  - other modes (e.g. prompt) → `raw` unless overridden

Implementation points:
- Registry: `lib/output/formatter_registry.rb`
- Formatters:
  - `lib/output/formatters/raw.rb`
  - `lib/output/formatters/stream.rb`
- Runner integration:
  - `run_agent.rb` builds formatter once and routes emitted agent events through it (`emit_output`)

This keeps output presentation modular and extensible while preserving daemon behavior.

---

## Database

SQLite database at `./gruv.db`, using **WAL mode** for safe concurrent access between the poller thread, main loop, clone workers, and cron jobs.

### Messages Table

```sql
CREATE TABLE messages (
  id         TEXT PRIMARY KEY,   -- "{timestamp}_{source}_{source_id}"
  source     TEXT NOT NULL,      -- 'system' | 'clone' | 'telegram'
  source_id  TEXT NOT NULL,      -- cron job name | clone PID | chat ID
  state      TEXT NOT NULL DEFAULT 'pending',  -- 'pending' | 'processed'
  message    TEXT NOT NULL,      -- text content
  metadata   TEXT,               -- nullable JSON blob for source-specific data
  timestamp  TEXT NOT NULL       -- ISO 8601
);

CREATE INDEX idx_state ON messages(state);
CREATE INDEX idx_source ON messages(source);
CREATE INDEX idx_timestamp ON messages(timestamp);
```

### Contacts Table

```sql
CREATE TABLE contacts (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  name              TEXT NOT NULL,
  telegram_username TEXT UNIQUE,       -- @username, nullable
  telegram_chat_id  TEXT UNIQUE,       -- nullable, links to messages.source_id
  tags              TEXT,              -- JSON array: '["creator", "engineer", "friend"]'
  notes             TEXT,              -- freeform info about the person
  user_requests     TEXT,              -- JSON array: '["remind me of his birthday", ...]'
  added_at          TEXT NOT NULL,     -- ISO 8601
  updated_at        TEXT NOT NULL      -- ISO 8601
);

CREATE INDEX idx_contacts_name ON contacts(name);
CREATE INDEX idx_contacts_telegram_chat_id ON contacts(telegram_chat_id);
```

Contacts are decoupled from Telegram — a contact can exist with just a name and notes.

### Tasks Table

```sql
CREATE TABLE tasks (
  id          TEXT PRIMARY KEY,   -- UUID or "{timestamp}_{clone_pid}"
  state       TEXT NOT NULL DEFAULT 'pending',  -- 'pending' | 'running' | 'completed' | 'failed'
  prompt      TEXT NOT NULL,      -- the task description / prompt for the clone
  chat_id     TEXT,               -- Telegram chat ID to reply to when done (nullable)
  context     TEXT,               -- nullable JSON blob for enrichment (contact info, parent task, etc.)
  spawned_by  TEXT,               -- session ID or 'daemon' — who created this task
  clone_pid   INTEGER,            -- PID of the clone process (set when spawned)
  created_at  TEXT NOT NULL,      -- ISO 8601
  started_at  TEXT,               -- ISO 8601, set when clone picks it up
  finished_at TEXT                 -- ISO 8601, set on completion/failure
);

CREATE INDEX idx_tasks_state ON tasks(state);
```

The tasks table gives clones the same structured flow as telegram messages. When a clone starts, it reads its task row for the prompt and any enriched context (e.g. which contact requested the work, parent task chain). When it finishes, it UPDATEs the task state and INSERTs a report into `messages`.

### Source ID Mapping

| Source | `source_id` | `metadata` examples |
|---|---|---|
| `telegram` | Chat ID | `{"message_id": 4821, "from": "seb", "chat_type": "private"}` |
| `clone` | Clone PID | `{"status": "completed", "task": "research_memory", "duration_seconds": 45}` |
| `system` | Cron job name | `{"cron": "proactive_thought"}` |

### Metadata

Nullable JSON column. Keeps the core table clean while each source stores its own extras:
- **Telegram**: `message_id` (for reply threading), `from`, `chat_type`, `photo_file_id`
- **Clone**: `status` (`completed` / `failed` / `partial`), `task`, `duration_seconds`
- **System**: `cron` job name, any context the script wants to pass

---

## Writers

Writers INSERT messages into `gruv.db`. They never read or modify existing messages.

| Writer | Trigger | How |
|---|---|---|
| Telegram poller thread | Long poll (~30s blocks) | In-process thread, uses Ruby SQLite |
| Clone wrapper | Child process exit | Uses `sqlite3` CLI |
| Cron jobs (e.g. proactive thought) | Scheduled by gruv | Uses `sqlite3` CLI |

Example CLI insert (for clone/cron writers):

```bash
sqlite3 ./gruv.db \
  "INSERT INTO messages (id, source, source_id, state, message, metadata, timestamp)
   VALUES ('${msg_id}', 'telegram', '${chat_id}', 'pending', '${text}', '${meta_json}', '${ts}');"
```

### Telegram Poller Thread

A dedicated background thread spawned at daemon startup. Uses **long polling** (`timeout: 30`) for near-instant message delivery with minimal API calls.

```
Thread: telegram_poller
┌──────────────────────────────────────┐
│ loop {                               │
│   getUpdates(timeout: 30,            │
│              offset: last+1)         │
│   for each message:                  │
│     INSERT INTO messages (...)       │
│   save offset                        │
│ }                                    │
└──────────────────────────────────────┘
```

Long polling means the HTTP request blocks for up to 30 seconds waiting for new messages. When a message arrives, Telegram responds immediately.

The offset is tracked in `./telegram_last_update_id` (or a future `config` table).

If the thread crashes, the daemon detects it and restarts it automatically with a brief backoff delay.

### Poller Stop Semantics (Shutdown/Restart)

A daemon shutdown or restart must not wait for the full long-poll timeout window.

Poller stop behavior is:
1. Set stop flag
2. Cancel active Telegram HTTP request(s) (close the in-flight long-poll connection)
3. Join thread with short timeout
4. If still alive, force-kill poller thread

This makes stop/restart latency bounded (seconds), instead of up to the long-poll timeout. Because daemon shutdown/restart is a terminal transition, dropping an in-flight poll response is acceptable; processing resumes from persisted `last_update_id` after boot.

### Clone Completion

When a clone finishes (or crashes), it:

1. UPDATEs its `tasks` row: `state` → `completed` or `failed`, sets `finished_at`
2. INSERTs a report into `messages` with `source = 'clone'`, including status, task summary, and duration in metadata

The clone reads its `chat_id` from the task row, so the daemon knows who to relay results to.

### Cron Jobs

Gruv sets up its own cron jobs (e.g. proactive thought) which INSERT into `messages` with `source = 'system'` via `sqlite3` CLI. These are external to the daemon process — gruv creates them, but they run independently.

---

## Main Loop

`run_daemon_mode()` initializes an `Agent` (with session context from the last run), starts the Telegram poller thread, and enters an infinite loop:

```
loop {
  1. SELECT pending messages from gruv.db (priority-ordered)
  2. For each message:
     a. Look up sender via LEFT JOIN contacts (for telegram messages)
     b. Build agent context with contact info (name, tags, notes, user_requests)
     c. Run agent inside catch(:agent_restart)
     d. Agent processes through cognitive loop, calls tools (including TelegramSend)
     e. UPDATE message state to 'processed' (always, even if Restart was requested)
     f. If restart was requested, re-throw :agent_restart after step (e)
  3. Outer loop catches :agent_restart and executes daemon restart handler
  4. sleep POLL_INTERVAL (1 second)
}
```

### Reading Messages

Each iteration, the main loop runs the priority query:

```sql
SELECT m.id, m.source, m.source_id, m.message, m.metadata, m.timestamp,
       c.name, c.tags, c.notes, c.user_requests
FROM messages m
LEFT JOIN contacts c ON m.source_id = c.telegram_chat_id
WHERE m.state = 'pending'
ORDER BY
  CASE m.source
    WHEN 'telegram' THEN 1
    WHEN 'clone'    THEN 2
    WHEN 'system'   THEN 3
  END,
  m.timestamp ASC;
```

**Priority**: telegram (human waiting) > clone (results ready) > system (cron-generated, lowest priority). Within each source, oldest first (FIFO).

After the agent finishes processing a message:

```sql
UPDATE messages SET state = 'processed' WHERE id = ?;
```

### Message State Transition Ordering

The daemon treats `messages.state` as the delivery acknowledgement boundary.

For each message row, the required order is:
1. Execute `agent.run(...)` (inside `catch(:agent_restart)`)
2. Persist output/log events
3. `UPDATE ... state = 'processed'`
4. Only then allow restart control-flow to continue (`throw(:agent_restart, ...)` to outer loop)

This ordering ensures the restart-triggering message itself is acknowledged before `exec ./gruv`. Without this ordering, the same row remains `pending` and is picked up again after boot.

Messages are never deleted during normal operation — they transition from `pending` to `processed`. Cleanup is handled by TTL/auto-purge.

### Contact-Enriched Context

When a telegram message arrives from a known contact (matched via `LEFT JOIN contacts` on `telegram_chat_id`), the main loop builds richer context for the agent:

```
[MESSAGE FROM TELEGRAM]
From: Sebastien (@seb)
Chat ID: 5560264375
Tags: creator, engineer, friend
Notes: Built the gruv system. Prefers concise responses.
User Requests: Always greet informally
Message: hey gruv what's up

Respond to this user via Telegram using their chat_id.
```

For unknown senders (no match in contacts), tags/notes/user_requests are omitted.

### Clone Report Processing

Clone reports (`source = 'clone'`) flow through the agent like any other message. The agent receives the full report in its transcript and decides what to do — it may summarize the results and send a polished message to the user via TelegramSend, ask follow-up questions, trigger further work, or decide the report doesn't need to be relayed at all. This gives the agent control over how information is presented, maintaining a single coherent voice rather than dumping raw clone output to users.

### Photo Handling

When a Telegram message includes a photo, the poller thread stores the `file_id` in `metadata` as `photo_file_id`. The main loop:

1. Reads `photo_file_id` from the metadata JSON column
2. Calls `getFile` → downloads the image → base64-encodes it
3. Resolves/normalizes media type (header → file extension → magic-byte sniffing)
4. Passes it to the agent as a vision content block alongside the text

**Critical content-block contract (must not regress):**

The in-process transcript representation for images is:

```ruby
{ type: 'image', media_type: 'image/jpeg', data: '<base64>' }
```

Do **not** nest `data`/`media_type` under `source` in the transcript payload. The provider mapper is responsible for adapting this internal shape into provider-specific API format (e.g. Anthropic's `image.source.base64`).

If `media_type` is missing or unsupported, coerce to a supported image type before sending (`image/jpeg`, `image/png`, `image/gif`, `image/webp`).

**Regression checklist for future refactors/regeneration:**
- Verify daemon logs include `photo enrichment success ... media_type=...`.
- Verify daemon logs include `agent input blocks ... image(media_type=..., source_type=none)`.
- Verify no transcript/user block uses `{ type: 'image', source: { ... } }` shape.
- Validate at least one real Telegram photo path end-to-end before release.

---

## Clone Spawning

When the daemon's agent decides to delegate work, it calls `CloneGRUV` which:

1. INSERTs a row into the `tasks` table with the prompt, chat_id, and enriched context (e.g. contact info for who requested the work)
2. Spawns a new `./gruv` process with `-a --task-id <task_id>`
3. The child reads its task row from `gruv.db`, gets the prompt and context
4. UPDATEs task state to `running`, sets `clone_pid` and `started_at`
5. Does the work
6. On exit, UPDATEs task state to `completed` or `failed`, sets `finished_at`
7. INSERTs a completion report into `messages` (`source = 'clone'`, `source_id = clone PID`)
8. The main loop picks it up on next SELECT, agent decides how to handle it

This keeps everything in `gruv.db` — no temp files. The task row provides full context to the clone, including which contact triggered the work and any parent task chain. The daemon can also query the `tasks` table to monitor running clones.

---

## Telegram Tools

The agent interacts with Telegram through a set of tools that wrap the `TelegramClient` library. All tools use the bot token from `AppConfig.telegram_token` and share the same underlying HTTP client.

### Tool Summary

| Tool | Description | External Dependencies |
|---|---|---|
| `TelegramSend` | Send a text message to a chat | — |
| `TelegramSendPhoto` | Send an image to a chat | — |
| `TelegramSendVoice` | Send a TTS voice message | ElevenLabs API, ffmpeg |
| `TelegramGetPhoto` | Download a photo by `file_id` → base64 | — |
| `TelegramGetVoice` | Download & transcribe a voice message | AssemblyAI API |
| `TelegramGetMe` | Get bot identity (username, ID) | — |

### TelegramSend

Sends a text message via `sendMessage`. Supports `parse_mode` (Markdown, MarkdownV2, HTML) and `reply_to_message_id` for threading replies. Returns the sent `message_id` and resolved contact name if known.

```
Agent → TelegramSend(chat_id, message, ?parse_mode, ?reply_to_message_id)
     → TelegramClient.send_message → Telegram API /sendMessage
```

This is the primary output tool. The main loop processes a pending message through the agent, and the agent calls `TelegramSend` to reply. The `chat_id` comes from the message's `source_id` (injected into the agent context by the main loop).

### TelegramSendPhoto

Sends an image via multipart upload to `sendPhoto`. Accepts three input formats:
- **Absolute file path** — reads the file from disk
- **Base64 string** — decodes to binary
- **JSON object** — `{"base64": "...", "media_type": "image/png"}`

Supports optional `caption` and `parse_mode`. Returns dimensions of the sent photo.

```
Agent → TelegramSendPhoto(chat_id, photo, ?caption, ?parse_mode)
     → resolve input format → TelegramClient.send_photo (multipart) → Telegram API /sendPhoto
```

Used when the agent generates or retrieves images (e.g., from a clone task, DALL-E, or local file).

### TelegramSendVoice

Converts text to a voice message through a three-stage pipeline:

```
Agent → TelegramSendVoice(chat_id, message)
     → ElevenLabs TTS → MP3 audio
     → ffmpeg → OGG Opus conversion (Telegram requirement)
     → TelegramClient.send_voice (multipart) → Telegram API /sendVoice
```

Requires `elevenlabs_api_key` and `elevenlabs_voice_id` in config. Requires `ffmpeg` installed on the system. Temp files are created for the MP3→OGG conversion and cleaned up after send.

### TelegramGetPhoto

Downloads a photo from Telegram by `file_id` and returns base64-encoded image data with metadata. Used by the main loop during **photo handling** — when a message arrives with `photo_file_id` in its metadata, the main loop calls `getFile` → downloads → base64-encodes → passes to the model as an image content block.

```
Agent → TelegramGetPhoto(file_id)
     → TelegramClient.download_file → Telegram API /getFile → download URL
     → media_type resolution:
         content-type header
         → fallback extension from file_path
         → fallback magic-byte sniffing (jpeg/png/gif/webp)
         → fallback image/jpeg
     → Base64 encode → { file_path, size, media_type, base64 }
```

**Important:** Telegram may return `application/octet-stream` for photos. That value is not valid for model vision input and must be converted to one of the supported image media types before constructing the transcript image block.

### TelegramGetVoice

Downloads a voice message from Telegram and transcribes it via AssemblyAI:

```
Agent → TelegramGetVoice(file_id)
     → TelegramClient.download_file → Telegram API /getFile → binary audio data
     → AssemblyAI upload → transcription → text result
```

Requires `assemblyai_api_key` in config. Used when the poller inserts a message with `has_voice: true` and `voice_file_id` in metadata.

### TelegramGetMe

Returns bot identity info (ID, @username, display name, group permissions). No parameters. Used for self-identification or debugging.

### TelegramClient (shared library)

All tools instantiate `TelegramClient` from `lib/clients/telegram_client.rb`. It provides:

- **`send_message`** — JSON POST to `/sendMessage`
- **`send_photo`** — Multipart POST to `/sendPhoto` (resolves file paths, base64, raw binary)
- **`send_document`** — Multipart POST to `/sendDocument`
- **`send_voice`** — Multipart POST to `/sendVoice` (OGG opus)
- **`get_updates`** — GET `/getUpdates` (used by the poller, not directly by tools)
- **`get_me`** — GET `/getMe`
- **`download_file`** — Two-step: GET `/getFile` for path, then download from `api.telegram.org/file/bot<token>/<path>`; normalizes image media type (`octet-stream` fallback via extension/sniffing)
- **`download_photo_base64`** — Convenience wrapper: `download_file` + Base64 encode

Error handling: all API errors raise `TelegramClient::APIError` with `error_code` and `description`. Tools catch these and return human-readable error strings to the agent.

### How Telegram Tools Fit the Architecture

```
                         INBOUND                              OUTBOUND
                    ┌─────────────────┐                 ┌──────────────────┐
                    │ TelegramPoller  │                 │  Agent Tools     │
                    │ (background     │                 │                  │
  Telegram ──────►  │  thread)        │                 │  TelegramSend    │ ──────► Telegram
  Bot API           │                 │                 │  TelegramSend    │         Bot API
  /getUpdates       │ INSERT into     │                 │    Photo         │         /sendMessage
                    │ messages table  │                 │  TelegramSend    │         /sendPhoto
                    │ with metadata:  │                 │    Voice         │         /sendVoice
                    │  photo_file_id  │                 │                  │
                    │  voice_file_id  │                 └──────────────────┘
                    │  document_file_id                        ▲
                    └────────┬────────┘                        │
                             │                                 │
                             ▼                                 │
                    ┌─────────────────┐                        │
                    │    gruv.db      │                        │
                    │   messages      │──── SELECT pending ───►│
                    │   (pending)     │                        │
                    └─────────────────┘                  ┌─────┴──────┐
                                                         │ Main Loop  │
                    ┌─────────────────┐                  │            │
                    │ Media Download  │◄─── if metadata  │ Build      │
                    │                 │     has file_id ──│ context    │
                    │ TelegramGet     │                  │ + media    │
                    │   Photo         │──── base64 ─────►│            │
                    │ TelegramGet     │     or text      │ Pass to    │
                    │   Voice         │                  │ agent.run()│
                    └─────────────────┘                  └────────────┘
```

**Inbound flow**: The poller thread receives updates and stores them with media `file_id`s in metadata. The main loop reads pending messages, detects media via metadata flags (`has_photo`, `has_voice`), downloads/transcribes using the Get tools, and enriches the agent context before calling `agent.run()`.

**Outbound flow**: The agent decides how to respond and calls Send tools directly. The `chat_id` for replies comes from the message's `source_id`, injected into the agent prompt by the main loop's contact-enriched context.

---

## Agent Restart

If the agent calls the `Restart` tool during daemon mode:
- the tool sets a runtime restart signal
- `Agent#send_and_process` throws `:agent_restart`
- per-message processing catches that throw, marks the current message `processed`, then re-throws
- outer daemon loop catches it and runs restart handling
- restart handler notifies contacts, stops poller (cancels in-flight long poll first), finalizes session, closes DB, then `exec ./gruv`

`exec()` replaces the current process with a fresh daemon invocation (code reloaded, new poller thread, new session logger). There is no in-process "new Agent instance and continue" path for daemon restart.

---

## Session Logging

The daemon starts a session via `SessionLogger` on boot. All messages, tool calls, API usage, and events are logged to `~/gruv-sessions/YYYYMMDD_HHMMSS/`:

- `session.log` — real-time event log
- `transcript.json` — full conversation history
- `summary.md` — session metadata

### Daemon Operational Logging

In addition to structured message/tool logs, daemon mode emits explicit operational logs for what it is doing at runtime.

These logs are written in two places:
- **stderr** (human-visible runtime logs, prefixed with `[daemon]`)
- **session.log** as structured events (`event = "daemon.log"`)

Typical daemon operational log steps include:
- daemon boot/startup
- system writer installation result
- pending message picked up (`got message`)
- pre-agent work (building and enriching agent input)
- media enrichment steps (photo/voice requested, success/failure path)
- per-message input block summary (text/image block types, lengths, image media type)
- transcript snapshot before/after `agent.run()` (tail summary for quick forensics)
- agent run start for a message
- message state transition (`marking message processed`)
- poller shutdown path logs (`[telegram_poller] stop requested; cancelling pending long-poll request(s)`, optional force-kill warning, and `[telegram_poller] stopped`)

This operational logging is intended to make daemon behavior auditable and easy to debug, especially around the preprocessing work done before `agent.run()` and around media-shape/media-type regressions.

---

## Lifecycle

```
┌─────────────────────────────────────────────────────┐
│ 1. Auth (OAuth token refresh)                       │
│ 2. Print banner                                     │
│ 3. Create Agent (load last session summary)         │
│ 4. Start SessionLogger                              │
│ 5. Start Telegram poller thread (long poll loop)    │
│ 6. Enter main loop                                  │
│    ├── SELECT pending from gruv.db                  │
│    ├── JOIN contacts for sender enrichment           │
│    ├── Process each message through agent            │
│    ├── UPDATE state = 'processed'                   │
│    ├── If Restart requested, re-throw to outer loop │
│    └── sleep 1s                                     │
│ 7. Ctrl+C/restart → cancel long poll, stop poller,   │
│    save session, then exit/exec                      │
└─────────────────────────────────────────────────────┘
```
