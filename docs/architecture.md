# Architecture

This document describes how these core pieces fit together:

- `Agent`
- `AgentSession`
- `SqlSessionManager`
- `Inbox`
- Writers

## High-level flow

```text
Telegram/Discord Writers
        |
        v
      Inbox  <---- clone task worker can also insert messages here
        |
        v
   DaemonMode polls `Inbox#next_pending`
        |
        v
   AgentSession
      |- wraps Agent
      `- uses SqlSessionManager for transcript persistence
        |
        v
      Agent
      |- sends prompt to model
      |- emits assistant output
      `- executes tool calls, then continues
        |
        v
   DaemonMode marks inbox row processed/failed
```

## 1. Writers: external input into the system

Writers are the ingestion side of the architecture.

Current writer families are:

- Telegram writer (`CommunicationPlatform::Telegram::Poller`)
- Discord writer (`CommunicationPlatform::Discord::Poller`)

Their job is to:

1. poll or receive messages from an external platform
2. normalize them into the app's inbox shape
3. optionally download attachments/media to local storage
4. call `Inbox#insert_message`

So writers do **not** talk to `Agent` directly.
They only produce inbox rows.

### Writer registration

`WriterRegistry` is the glue between the daemon/supervisor and the writer implementations.

- `modes/telegram_writer.rb` registers the Telegram poller if Telegram config exists
- `modes/discord_writer.rb` registers the Discord poller if Discord config exists
- `DaemonSupervisorMode` uses `WriterRegistry.roles` to spawn one child process per configured writer

`WriterRegistry.for_platform(platform)` is also used later by the daemon when it needs a sender for outbound replies or rate-limit notices.

## 2. Inbox: queue between writers and agent execution

`Inbox` is the boundary between message ingestion and message processing.

It stores work in SQLite-backed tables, mainly `messages` and `channel_attachments`.

### What goes into the inbox

Each inserted message includes things like:

- `platform`
- `channel_id`
- sender fields
- message text
- metadata
- timestamps/state

Attachments discovered by writers are also persisted through `Inbox#insert_channel_attachments`.

### What the inbox does architecturally

`Inbox` is responsible for:

- accepting new work from writers via `insert_message`
- leasing one pending message to the daemon via `next_pending`
- reclaiming stale `processing` rows
- marking rows `processed` or `failed`

This makes the inbox the system's durable handoff point.
If a writer and the daemon run in different processes, the inbox is the shared contract between them.

## 3. DaemonMode: bridge from inbox rows to conversations

`DaemonMode` is the main consumer of `Inbox`.

For each loop iteration it:

1. asks `Inbox` for the next pending row
2. logs receipt/start
3. converts the inbox row into a YAML-wrapped prompt payload
4. finds or creates a session for that channel
5. runs the session
6. marks the inbox row processed or failed

Important current behavior:

- daemon sessions are keyed by `channel_id`
- `SqlSessionManager.new(channel_id: channel_id)` uses that channel id as the session id
- this means conversation continuity is currently per channel, not per inbox message

## 4. AgentSession: conversation wrapper around an agent

`AgentSession` sits between `DaemonMode` and `Agent`.

It is a thin coordination layer with three main jobs:

1. connect the `Agent` to a session manager
2. preload the agent transcript from persisted history
3. trigger compaction when the transcript gets too large

When created, `AgentSession`:

- subscribes the session manager to agent events
- sets `agent.transcript = compacted_transcript`

When `run(message)` is called, it:

- logs the input
- calls `agent.run(message)`
- compacts if `session_manager.total_tokens > 20000`

So `AgentSession` is not the LLM itself and not storage itself.
It is the runtime wrapper that keeps the in-memory `Agent` and the persistent transcript in sync.

## 5. SqlSessionManager: durable transcript storage

`SqlSessionManager` is the persistence layer used by daemon conversations.

It inherits from `BaseSessionManager` and stores session events in the `session_events` table.

### Relationship to AgentSession

`AgentSession` depends on a session manager interface.
In daemon mode, that concrete implementation is `SqlSessionManager`.

The relationship is:

- `Agent` emits `:user_input` and `:message` events
- `AgentSession` has already subscribed the session manager to those events
- `SqlSessionManager#on_notify` persists them as session events
- later, `AgentSession` asks the session manager to rebuild the transcript with `assemble_transcript`

So `SqlSessionManager` is the durable memory for the `Agent`.

### What it stores

It persists:

- message events
- compaction events
- usage metadata
- event ordering and parent links


## 6. Agent: LLM loop and tool execution

`Agent` is the component that actually runs the conversation against the model.

Its responsibilities are:

- keep an in-memory `transcript`
- publish user input into that transcript
- construct a prompt object (`Prompt.new(transcript, client)`)
- call the LLM through `prompt.post`
- stream deltas to listeners
- append assistant output to the transcript
- detect `tool_use` blocks
- execute tools
- append `tool_result` blocks as a synthetic user message
- recurse until there are no more tool calls

So `Agent` is the execution engine.
It does the actual think/respond/use-tools loop.

It does **not** decide which inbox row to process, and it does **not** persist history by itself.
Those concerns belong to `Inbox` and `SqlSessionManager`/`AgentSession`.

## End-to-end relationship

A typical inbound message path looks like this:

1. A writer receives a platform event
2. The writer normalizes it and inserts it into `Inbox`
3. `DaemonMode` claims that inbox row
4. `DaemonMode` finds the `AgentSession` for the row's `channel_id`
5. `AgentSession` loads transcript state from `SqlSessionManager`
6. `Agent` runs the new message against the model
7. Any tool calls are executed inside `Agent`
8. Agent events are persisted by `SqlSessionManager`
9. `DaemonMode` marks the inbox row processed or failed
10. If needed, outbound platform sending uses the sender associated with the writer platform

## Responsibilities summary

### Writers
- ingest from external platforms
- normalize message shape
- persist inbound work into `Inbox`

### Inbox
- durable queue / lease system
- stores inbound messages and attachments
- hands work to daemon workers

### AgentSession
- runtime wrapper for a conversation
- connects `Agent` with persistent session storage
- reloads history and triggers compaction

### SqlSessionManager
- durable transcript/event storage for daemon sessions
- rebuilds transcript for future agent runs
- supports compaction

### Agent
- runs the LLM interaction loop
- handles tool use/results
- emits conversation events

## Design intent

The main architectural split is:

- **Writers + Inbox** handle ingestion and queueing
- **DaemonMode + AgentSession + SqlSessionManager + Agent** handle processing and memory

That separation lets the system:

- accept messages independently of model execution
- survive process restarts because messages and transcripts are persisted
- maintain long-running per-channel conversations while still processing one inbox row at a time
