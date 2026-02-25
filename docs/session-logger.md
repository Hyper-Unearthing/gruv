# Session Logger

This project logs conversation sessions as JSONL via `FileSessionManager` (`lib/sessions/file_session_manager.rb`).

Each line in a session file is one event object.

## File location and naming

- Directory: `instance/sessions/`
- Filename format: `<YYYYMMDD_HHMMSS>_<session_uuid>.jsonl`
- Example: `20260225_162039_47fb4937-3243-4b9c-a8de-38858cc2935f.jsonl`

## Top-level event schema

All events use the same envelope:

```json
{
  "id": "UUID",
  "parent_id": "UUID or null",
  "timestamp": "ISO-8601",
  "type": "message | compaction",
  "usage": { "input_tokens": 0, "output_tokens": 0, "total_tokens": 0 },
  "data": {}
}
```

Notes:
- `parent_id` is `null` for the first entry; otherwise it points to the previous event id.
- `usage` is optional.
- `data` shape depends on `type`.

## `type: "message"`

`data` contains only message content:

```json
{
  "role": "user | assistant",
  "content": [
    { "type": "text", "text": "..." }
  ]
}
```

`content` can include mixed blocks like:
- `text`
- `tool_use`
- `tool_result`

For assistant LLM responses, `usage` is stored at top-level from `payload[:usage]`.

## `type: "compaction"`

`data` contains compaction metadata:

```json
{
  "summary": "string",
  "first_kept_entry_id": "UUID"
}
```

Top-level `usage` is set from the compaction prompt result (`result[:usage]`).

## Write path

`FileSessionManager#on_notify` listens to agent events:
- `:user_input`
- `:message`

Both are persisted as `type: "message"` entries.

`FileSessionManager#compaction` writes a `type: "compaction"` entry.

## Read path

- `current_transcript` returns all message `data` entries.
- `assemble_transcript`:
  - finds latest compaction event,
  - prepends the compaction summary as an assistant text message,
  - keeps messages from `first_kept_entry_id` onward.
