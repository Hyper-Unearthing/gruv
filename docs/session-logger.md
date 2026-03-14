# Session Logger

Conversation sessions are persisted by session managers under `lib/sessions/`.

This document describes the session event model used by `SqlSessionManager` and the `session_events` table.

## Event model

Persisted events are usually one of:

- `message`
- `compaction`

Their common shape is:

```json
{
  "id": "UUID",
  "parent_id": "UUID or null",
  "timestamp": "ISO-8601",
  "type": "message | compaction",
  "usage": {
    "input_tokens": 0,
    "output_tokens": 0,
    "total_tokens": 0
  },
  "data": {}
}
```

Notes:

- `id` is generated for each appended event.
- `parent_id` points to the previous event in the session chain.
- `timestamp` is `Time.now.iso8601` for appended events.
- `usage` is optional and normalized through `UsageNormalizer.normalize`.
- `data` depends on `type`.

## `type: "message"`

`BaseSessionManager#on_notify` persists both `:user_input` and `:message` notifications as `message` events.

Stored shape:

```json
{
  "role": "user | assistant",
  "content": [
    { "type": "text", "text": "..." }
  ]
}
```

`content` is stored as received. It may contain mixed blocks, including:

- `text`
- `input_text`
- `output_text`
- `tool_use`
- `tool_result`

If the incoming payload includes usage, it is stored at the top level of the event, not inside `data`.

## `type: "compaction"`

Compaction is implemented by `BasicCompaction`.

A compaction event is written only when there are more messages than `messages_to_keep` (default: `2`).

Stored shape:

```json
{
  "summary": "string",
  "kept_messages_count": 2
}
```

Notes:

- The summary is generated from all message entries in the session.
- `kept_messages_count` records how many recent message events also remain verbatim after compaction.
- Top-level `usage` comes from the compaction LLM result.

## Read behavior

### `current_transcript`

Returns every persisted `message` event's `data`, in order.

It does not include `compaction` events.

### `assemble_transcript`

Builds the transcript used by the agent.

If there is no usable compaction entry, it returns the same message list as `current_transcript`.

If there is a compaction entry with a valid `summary`, it:

1. finds the latest compaction event
2. loads the most recent `kept_messages_count` message events
3. prepends a synthetic assistant message containing the summary text
4. drops leading non-text-only messages from the kept tail

That last step exists so the rebuilt transcript does not start with tool-only blocks.
A message counts as text-only when all content parts are one of:

- `text`
- `input_text`
- `output_text`

## Token counting

`total_tokens` is derived from the most recent `message` event that has `usage.total_tokens`.

`AgentSession#run` triggers compaction when this value exceeds `20000`.

## SQL-backed sessions

`SqlSessionManager` stores session events in the `session_events` table.

Important characteristics:

- there is no persisted `session` header row
- session identity is `(session_id, session_start)`
- daemon sessions use:
  - `session_id = channel_id`
  - `session_start = "continuous"`
- ordering is tracked by `position`
- `usage` and `data` are stored as JSON strings in `usage_json` and `data_json`

