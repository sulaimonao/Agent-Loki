export const SCHEMA_VERSION = 1;

export const BASE_SCHEMA_SQL = `
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS internal_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS guilds (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  discovered_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS channels (
  id TEXT PRIMARY KEY,
  guild_id TEXT,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  parent_id TEXT,
  last_seen_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL,
  global_name TEXT,
  bot INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  guild_id TEXT,
  channel_id TEXT NOT NULL,
  author_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  edited_at TEXT,
  content TEXT,
  content_unavailable INTEGER NOT NULL DEFAULT 0,
  reply_to_id TEXT,
  raw_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS attachments (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL,
  url TEXT NOT NULL,
  filename TEXT,
  content_type TEXT,
  size INTEGER,
  FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS channel_access (
  channel_id TEXT PRIMARY KEY,
  can_view INTEGER NOT NULL,
  can_read_history INTEGER NOT NULL,
  has_message_content INTEGER NOT NULL,
  last_backfill_at TEXT,
  last_error TEXT
);

CREATE TABLE IF NOT EXISTS chat_channels (
  guild_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (guild_id, channel_id)
);

CREATE TABLE IF NOT EXISTS chat_thread_routes (
  guild_id TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  thread_id TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (guild_id, channel_id, user_id)
);

CREATE TABLE IF NOT EXISTS mod_actions (
  id TEXT PRIMARY KEY,
  ts TEXT NOT NULL,
  guild_id TEXT,
  channel_id TEXT,
  target_user_id TEXT,
  action TEXT NOT NULL,
  reason TEXT,
  approved_by TEXT,
  evidence_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS pending_approvals (
  id TEXT PRIMARY KEY,
  ts TEXT NOT NULL,
  guild_id TEXT,
  channel_id TEXT,
  target_user_id TEXT,
  action TEXT NOT NULL,
  reason TEXT,
  payload_json TEXT NOT NULL,
  requested_by TEXT,
  status TEXT NOT NULL,
  approved_by TEXT,
  executed_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_messages_channel_created ON messages(channel_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_author_created ON messages(author_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_guild_created ON messages(guild_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_attachments_message ON attachments(message_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_attachments_message_url ON attachments(message_id, url);
CREATE INDEX IF NOT EXISTS idx_chat_channels_guild ON chat_channels(guild_id, enabled);
CREATE INDEX IF NOT EXISTS idx_chat_thread_routes_guild ON chat_thread_routes(guild_id, channel_id);
CREATE INDEX IF NOT EXISTS idx_pending_approvals_status ON pending_approvals(status, ts DESC);
`;
