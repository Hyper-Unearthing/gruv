# Inbox System

Gruv uses a SQLite-backed inbox at `instance/gruv.sqlite3`.

## Overview

The inbox is centered on the `messages` table.

Current producers:
- Telegram writer (`modes/telegram_writer.rb` → `CommunicationPlatform::Telegram::Poller`)
- Discord writer (`modes/discord_writer.rb` → `CommunicationPlatform::Discord::Poller`)
- Clone task worker (`scripts/clone_task_worker.rb`), which inserts follow-up messages with `platform: 'clone'`

Current consumer:
- daemon worker (`modes/daemon.rb`)

Process model when running `./gruv --daemon`:
1. `gruv` loads all `modes/*_writer.rb` files.
2. Each writer file registers its role in `WriterRegistry` only if it is configured.
3. `DaemonSupervisorMode` starts:
   - 1 daemon worker via `run_agent.rb --daemon`
   - 1 child per registered writer role
4. If any child exits, the supervisor stops the whole group.
5. `SIGINT`/`SIGTERM` force-kill all children.
6. `SIGHUP` reloads only the daemon worker.

Important: clone task workers are **not** registered writer roles. They are spawned separately and write into the inbox directly.

## Writer Registry

Writers are registered through `lib/writer_registry.rb`.

Current registrations:
- `telegram` in `modes/telegram_writer.rb`
- `discord` in `modes/discord_writer.rb`

Registration flow:
1. `gruv` requires every `modes/*_writer.rb` file.
2. Each file calls `WriterRegistry.register_if_configured(...)`.
3. `register_if_configured` loads `AppConfig` and only registers the role if the top-level config key exists.
4. In supervisor mode, `WriterRegistry.roles` is used to spawn one process per role.
5. Writer child processes are started by relaunching `./gruv` with `GRUV_ROLE=<role>`.
6. `gruv` resolves that role with `WriterRegistry.resolve(role)` and runs `klass.new(INBOX_DB_PATH).start`.

`WriterRegistry.for_platform(platform)` is also used by the daemon to find the correct sender when it needs to notify a user (for example on rate limits).

## Messages Table

Current schema from `db/migrate/20260224134910_create_messages_table.rb`:

```sql
CREATE TABLE messages (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  platform              VARCHAR NOT NULL,
  channel_id            VARCHAR NOT NULL,
  scope                 VARCHAR,
  sender_id             VARCHAR,
  sender_username       VARCHAR,
  sender_name           VARCHAR,
  provider_message_id   VARCHAR,
  provider_update_id    VARCHAR,
  state                 VARCHAR NOT NULL DEFAULT 'pending',
  attempt_count         INTEGER NOT NULL DEFAULT 0,
  last_error            TEXT,
  processing_started_at VARCHAR,
  processed_at          VARCHAR,
  message               TEXT NOT NULL,
  metadata              JSON NOT NULL DEFAULT '{}',
  timestamp             VARCHAR NOT NULL
);
```

Indexes:

```sql
CREATE INDEX index_messages_on_state ON messages(state);
CREATE INDEX index_messages_on_platform ON messages(platform);
CREATE INDEX index_messages_on_platform_channel_id ON messages(platform, channel_id);
CREATE INDEX index_messages_on_platform_sender_timestamp ON messages(platform, sender_id, timestamp);
CREATE INDEX index_messages_on_timestamp ON messages(timestamp);
CREATE UNIQUE INDEX index_messages_on_platform_channel_provider_message
  ON messages(platform, channel_id, provider_message_id)
  WHERE provider_message_id IS NOT NULL;
```

Notes:
- `state` can be `pending`, `processing`, `processed`, or `failed`.
- `metadata` is non-null and defaults to `{}`.
- `provider_message_id` is deduplicated per `(platform, channel_id)` when present.
- `timestamp`, `processing_started_at`, and `processed_at` are stored as strings, typically ISO-8601 UTC.

## Channel Attachments Table

Current schema from `db/migrate/20260227175800_create_channel_attachments_table.rb`:

```sql
CREATE TABLE channel_attachments (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  message_id          INTEGER NOT NULL,
  source              VARCHAR NOT NULL,
  channel_id          VARCHAR NOT NULL,
  provider_message_id VARCHAR,
  attachment_type     VARCHAR NOT NULL,
  provider_file_id    VARCHAR,
  file_name           VARCHAR,
  content_type        VARCHAR,
  url                 VARCHAR,
  path                VARCHAR NOT NULL,
  timestamp           VARCHAR NOT NULL
);
```

Indexes:

```sql
CREATE INDEX index_channel_attachments_on_message_id ON channel_attachments(message_id);
CREATE INDEX index_channel_attachments_on_source_channel_id ON channel_attachments(source, channel_id);
CREATE INDEX index_channel_attachments_on_provider_message_id ON channel_attachments(provider_message_id);
CREATE INDEX index_channel_attachments_on_timestamp ON channel_attachments(timestamp);
CREATE UNIQUE INDEX index_channel_attachments_on_path ON channel_attachments(path);
```

This table stores downloaded media/attachment files associated with inbox rows.

## Contacts Enrichment

`messages` are enriched at read time with `contacts`, but only for Telegram messages.

Current join in `Message.priority_query`:

```sql
LEFT JOIN contacts c
  ON m.platform = 'telegram'
 AND m.channel_id = c.telegram_chat_id
```

The daemon receives this as:

```ruby
contact: {
  name: ...,
  tags: ...,
  notes: ...,
  user_requests: ...
}
```

For non-Telegram platforms, `contact` is effectively empty.

## Telegram Message Shape

Telegram writer inserts rows with:
- `platform: 'telegram'`
- `channel_id: <chat id as string>`
- `scope: 'dm'` for private chats
- `scope: 'group'` for group/supergroup/channel chats
- sender fields from `message['from']`
- `provider_message_id: message['message_id']`
- `provider_update_id: update['update_id']`

Current Telegram metadata keys:
- `update_id`
- `message_id`
- `from_id`
- `from_username`
- `from_first_name`
- `chat_type`
- `photo_file_ids`
- `photo_file_paths`
- `image_file_paths`
- `has_voice`
- `voice_file_id`
- `has_attachments`
- `attachment_files`
- `attachment_file_paths`

Telegram content extraction currently works like this:
1. `text`
2. `caption`
3. poll question as `[Poll] ...`
4. placeholder strings such as `[Photo message]`, `[Voice message]`, `[Sticker message]`, `[Document message]`, `[Video message]`, `[Animation message]`, `[Audio message]`
5. otherwise the update is skipped

Telegram writer also downloads photos and attachments to local storage and records them in both message metadata and `channel_attachments`.

## Discord Message Shape

Discord writer inserts rows with:
- `platform: 'discord'`
- `channel_id: <channel id>`
- `scope: 'dm'` when `guild_id` is nil
- `scope: 'guild_channel'` otherwise
- sender fields from `author`
- `provider_message_id: data[:id]`
- `provider_update_id: nil`

Current Discord metadata keys:
- `event_type` (`MESSAGE_CREATE`)
- `message_id`
- `channel_id`
- `guild_id`
- `author_id`
- `author_username`
- `author_global_name`
- `has_attachments`
- `attachment_files`
- `attachment_file_paths`
- `image_file_paths`

Discord content extraction currently works like this:
1. message `content`
2. `[Attachment message]` if attachments exist
3. `[Sticker message]` if sticker items exist
4. otherwise skip

Discord attachments are downloaded locally and also written into `channel_attachments`.

## Clone Task Messages

`scripts/clone_task_worker.rb` writes completion/failure notifications back into the inbox with:
- `platform: 'clone'`
- `channel_id: "origin:<origin_inbox_message_id>"`
- `scope: 'clone_task'`

Clone metadata currently includes:
- `task_id`
- `origin_inbox_message_id`
- `pid`
- `state` (`completed` or `failed`)
- `session_path`
- `log_path`

## Insert Path

All normal inbox inserts go through `Inbox#insert_message`.

That method:
1. generates `timestamp = Time.now.utc.iso8601`
2. normalizes `metadata` to `{}` if nil
3. inserts a `messages` row in `pending` state with `attempt_count = 0`
4. derives attachment rows from metadata by calling `insert_channel_attachments`

`insert_channel_attachments` currently creates `channel_attachments` rows from:
- `metadata[:attachment_files]`
- `metadata[:image_file_paths]`
- `metadata[:photo_file_paths]`

Duplicate paths are skipped within a single insert, and the DB also enforces global uniqueness on `channel_attachments.path`.

## Claiming / Processing Flow

The daemon reads messages through `Inbox#next_pending`.

Current behavior:
1. reclaim stale `processing` rows older than 300 seconds back to `pending`
2. select the first pending row from `Message.priority_query`
3. atomically claim it only if it is still `pending`
4. set:
   - `state = 'processing'`
   - `processing_started_at = Time.now.utc.iso8601`
   - `attempt_count = attempt_count + 1`
5. return a Ruby hash to the daemon

The returned hash currently includes:
- message fields (`id`, `platform`, `channel_id`, `scope`, sender fields, provider ids, `attempt_count`, `message`, `metadata`, `timestamp`)
- `message_attachments`: attachments for that specific message
- `media_table_attachments`: **currently all rows in `channel_attachments`, not just this message**
- `contact`: Telegram contact enrichment if present

That `media_table_attachments` behavior reflects the current code in `Inbox#next_pending`.

## Priority Order

Current SQL priority is:

```sql
ORDER BY
  CASE m.platform
    WHEN 'system' THEN 3
    WHEN 'clone'  THEN 2
    ELSE 1
  END,
  m.timestamp ASC
```

So in practice:
- Telegram and Discord are highest priority (`ELSE 1`)
- Clone is next
- System is lowest
- FIFO within the same priority bucket by `timestamp`

## Daemon Handling

For each claimed row, `DaemonMode#process_next_message`:
1. logs receipt/start events
2. builds a YAML-wrapped prompt containing the whole inbox row
3. loads/creates a session for `channel_id`
4. runs the agent
5. on success, marks the row processed

Important implementation detail: daemon sessions are keyed only by `channel_id`, not by `(platform, channel_id)`.

## Acknowledgement / Failure Semantics

Successful processing:

```sql
UPDATE messages
SET state = 'processed',
    processed_at = ?,
    processing_started_at = NULL,
    last_error = NULL
WHERE id = ?;
```

Failure processing uses `Inbox#mark_failed`:
- if `attempt_count >= 3`, state becomes `failed`
- otherwise state returns to `pending`
- `last_error` is updated
- `processing_started_at` is cleared

Stale leases are reclaimed by `Inbox#reclaim_stale_processing`:
- rows in `processing` older than 300 seconds are returned to `pending`
- `last_error` becomes `Processing lease timed out; returned to pending`

## Rate Limit Behavior

If agent execution raises `LlmGateway::Errors::RateLimitError`:
1. daemon logs the rate limit
2. on the first attempt only (`attempt_count == 1`), it tries to notify the user using the platform sender from `WriterRegistry.for_platform`
3. it then calls `mark_failed`, which usually requeues the message until max attempts are exhausted

Current rate-limit user notice text:

> I hit a temporary rate limit and could not reply just now. Please try again in a bit.

## Cleanup

`Inbox#cleanup_processed(older_than_days: 30)` deletes processed rows older than the cutoff timestamp.

This cleanup is available in code but is not part of the normal daemon loop.
