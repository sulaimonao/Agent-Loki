import Database from "better-sqlite3";
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { ensureFts } from "./fts";
import { BASE_SCHEMA_SQL, SCHEMA_VERSION } from "./schema";

export interface DbGuildInput {
  id: string;
  name: string;
  discoveredAt?: string;
}

export interface DbChannelInput {
  id: string;
  guildId?: string | null;
  name: string;
  type: string;
  parentId?: string | null;
  lastSeenAt?: string;
}

export interface DbUserInput {
  id: string;
  username: string;
  globalName?: string | null;
  bot: boolean;
}

export interface DbAttachmentInput {
  id?: string;
  url: string;
  filename?: string | null;
  contentType?: string | null;
  size?: number | null;
}

export interface DbMessageInput {
  id: string;
  guildId?: string | null;
  channelId: string;
  authorId: string;
  createdAt: string;
  editedAt?: string | null;
  content?: string | null;
  contentUnavailable: boolean;
  replyToId?: string | null;
  rawJson: string;
}

export interface SearchFilters {
  query: string;
  guildId?: string;
  channelId?: string;
  userId?: string;
  since?: string;
  until?: string;
  limit?: number;
}

export interface SearchRow {
  id: string;
  guild_id: string | null;
  channel_id: string;
  author_id: string;
  created_at: string;
  edited_at: string | null;
  content: string | null;
  content_unavailable: number;
}

export interface ExportMessageRow {
  id: string;
  created_at: string;
  channel_id: string;
  author_id: string;
  content: string | null;
  content_unavailable: number;
}

export interface ChannelAccessInput {
  channelId: string;
  canView: boolean;
  canReadHistory: boolean;
  hasMessageContent: boolean;
  lastBackfillAt?: string | null;
  lastError?: string | null;
}

export interface PendingApprovalInput {
  id: string;
  ts: string;
  guildId?: string | null;
  channelId?: string | null;
  targetUserId?: string | null;
  action: string;
  reason?: string | null;
  payloadJson: string;
  requestedBy?: string | null;
  status: "pending" | "approved" | "executed" | "rejected";
}

export interface PendingApprovalRecord extends PendingApprovalInput {
  approvedBy?: string | null;
  executedAt?: string | null;
}

export interface ModActionInput {
  id: string;
  ts: string;
  guildId?: string | null;
  channelId?: string | null;
  targetUserId?: string | null;
  action: string;
  reason?: string | null;
  approvedBy?: string | null;
  evidenceJson: string;
}

export interface MessageWindowRow {
  id: string;
  guild_id: string | null;
  channel_id: string;
  author_id: string;
  created_at: string;
  content: string | null;
  content_unavailable: number;
}

export interface MessageCoverageScope {
  sinceIso: string;
  untilIso: string;
  guildId?: string;
  channelId?: string;
  userId?: string;
}

export interface MessageCoverageStats {
  totalMessages: number;
  availableMessages: number;
  unavailableMessages: number;
  coverageRatio: number;
}

export interface AttachmentLookupRow {
  id: string;
  message_id: string;
  url: string;
  filename: string | null;
  content_type: string | null;
  size: number | null;
}

export interface UserLookupRow {
  id: string;
  username: string;
  global_name: string | null;
  bot: number;
}

export interface ChannelLookupRow {
  id: string;
  guild_id: string | null;
  name: string;
  type: string;
  parent_id: string | null;
}

export interface CoverageReport {
  readable: number;
  unreadable: number;
  skipped: Array<{ channelId: string; reason: string }>;
}

export type ChatMode = "mention" | "prefix" | "channel" | "off";
export type ChatThreadMode = "auto" | "ask" | "off";

export interface ChatThreadRoute {
  threadId: string;
  updatedAt: string;
}

export interface IndexStatus {
  lastIndexRunAt?: string;
  lastIndexOkAt?: string;
  lastIndexError?: string;
  indexVersion?: string;
}

export interface IndexDuplicateStats {
  messageIdDuplicates: number;
  attachmentIdDuplicates: number;
  attachmentMessageUrlDuplicates: number;
}

export interface FtsConsistencyStats {
  ftsReady: boolean;
  messagesCount: number;
  ftsRows: number;
  missingFtsRows: number;
  orphanFtsRows: number;
  duplicateFtsMessageIds: number;
  consistent: boolean;
}

export interface EvidenceAvailabilityStats {
  totalMessages: number;
  unavailableMessages: number;
  unavailableRatio: number;
}

const sanitizeFtsQuery = (query: string): string => {
  const tokens = query
    .split(/\s+/)
    .map((token) => token.replace(/[^\p{L}\p{N}_-]/gu, "").trim())
    .filter(Boolean);
  return tokens.join(" ");
};

const CHAT_MODE_VALUES = new Set<ChatMode>(["mention", "prefix", "channel", "off"]);
const CHAT_THREAD_MODE_VALUES = new Set<ChatThreadMode>(["auto", "ask", "off"]);
const chatModeKey = (guildId: string): string => `chat_mode:${guildId}`;
const chatThreadModeKey = (guildId: string): string => `chat_thread_mode:${guildId}`;
const chatDebugKey = "chat_debug";
const TRUTHY_INTERNAL_META_VALUES = new Set(["1", "true", "on", "yes"]);
const LAST_INDEX_RUN_AT_KEY = "last_index_run_at";
const LAST_INDEX_OK_AT_KEY = "last_index_ok_at";
const LAST_INDEX_ERROR_KEY = "last_index_error";
const INDEX_VERSION_KEY = "index_version";
const EVIDENCE_MESSAGE_FILTER_SQL = `
COALESCE(u.bot, 0) = 0
AND LOWER(LTRIM(COALESCE(m.content, ''))) NOT LIKE '/loki%'
AND LOWER(LTRIM(COALESCE(m.content, ''))) NOT LIKE '# loki report%'
`;
const READABLE_EVIDENCE_MESSAGE_SQL = `
m.content_unavailable = 0
AND m.content IS NOT NULL
AND TRIM(m.content) <> ''
`;

const buildAttachmentDeterministicId = (
  messageId: string,
  attachment: Omit<DbAttachmentInput, "id">,
): string => {
  const key = `${messageId}|${attachment.url}|${attachment.filename ?? ""}|${attachment.size ?? 0}`;
  return createHash("sha1").update(key).digest("hex");
};

export class LokiDb {
  private readonly db: Database.Database;

  constructor(dbPath: string) {
    fs.mkdirSync(path.dirname(dbPath), { recursive: true });
    this.db = new Database(dbPath);
    this.db.pragma("foreign_keys = ON");
  }

  init(): void {
    this.db.exec(BASE_SCHEMA_SQL);
    ensureFts(this.db);

    const row = this.db
      .prepare("SELECT value FROM internal_meta WHERE key = 'schema_version'")
      .get() as { value: string } | undefined;

    if (!row) {
      this.db
        .prepare("INSERT INTO internal_meta(key, value) VALUES ('schema_version', ?)")
        .run(String(SCHEMA_VERSION));
      return;
    }

    const version = Number(row.value);
    if (Number.isNaN(version) || version !== SCHEMA_VERSION) {
      throw new Error(
        `Schema version mismatch: db=${row.value}, expected=${SCHEMA_VERSION}. Run migration before start.`,
      );
    }
  }

  close(): void {
    this.db.close();
  }

  upsertGuild(input: DbGuildInput): void {
    this.db
      .prepare(
        `
        INSERT INTO guilds(id, name, discovered_at)
        VALUES (@id, @name, @discoveredAt)
        ON CONFLICT(id) DO UPDATE SET
          name = excluded.name,
          discovered_at = excluded.discovered_at
      `,
      )
      .run({
        ...input,
        discoveredAt: input.discoveredAt ?? new Date().toISOString(),
      });
  }

  upsertChannel(input: DbChannelInput): void {
    this.db
      .prepare(
        `
        INSERT INTO channels(id, guild_id, name, type, parent_id, last_seen_at)
        VALUES (@id, @guildId, @name, @type, @parentId, @lastSeenAt)
        ON CONFLICT(id) DO UPDATE SET
          guild_id = excluded.guild_id,
          name = excluded.name,
          type = excluded.type,
          parent_id = excluded.parent_id,
          last_seen_at = excluded.last_seen_at
      `,
      )
      .run({
        ...input,
        guildId: input.guildId ?? null,
        parentId: input.parentId ?? null,
        lastSeenAt: input.lastSeenAt ?? new Date().toISOString(),
      });
  }

  upsertUser(input: DbUserInput): void {
    this.db
      .prepare(
        `
        INSERT INTO users(id, username, global_name, bot)
        VALUES (@id, @username, @globalName, @bot)
        ON CONFLICT(id) DO UPDATE SET
          username = excluded.username,
          global_name = excluded.global_name,
          bot = excluded.bot
      `,
      )
      .run({
        ...input,
        globalName: input.globalName ?? null,
        bot: input.bot ? 1 : 0,
      });
  }

  upsertMessage(input: DbMessageInput, attachments: DbAttachmentInput[]): void {
    const tx = this.db.transaction(() => {
      this.db
        .prepare(
          `
          INSERT INTO messages(
            id,
            guild_id,
            channel_id,
            author_id,
            created_at,
            edited_at,
            content,
            content_unavailable,
            reply_to_id,
            raw_json
          )
          VALUES (
            @id,
            @guildId,
            @channelId,
            @authorId,
            @createdAt,
            @editedAt,
            @content,
            @contentUnavailable,
            @replyToId,
            @rawJson
          )
          ON CONFLICT(id) DO UPDATE SET
            edited_at = excluded.edited_at,
            content = excluded.content,
            content_unavailable = excluded.content_unavailable,
            raw_json = excluded.raw_json
        `,
        )
        .run({
          ...input,
          guildId: input.guildId ?? null,
          editedAt: input.editedAt ?? null,
          content: input.content ?? null,
          replyToId: input.replyToId ?? null,
          contentUnavailable: input.contentUnavailable ? 1 : 0,
        });
      const normalizedAttachments = attachments.map((attachment) => ({
        ...attachment,
        id:
          attachment.id && attachment.id.trim().length > 0
            ? attachment.id
            : buildAttachmentDeterministicId(input.id, {
                url: attachment.url,
                filename: attachment.filename ?? null,
                contentType: attachment.contentType ?? null,
                size: attachment.size ?? null,
              }),
      }));

      if (normalizedAttachments.length === 0) {
        this.db.prepare("DELETE FROM attachments WHERE message_id = ?").run(input.id);
      } else {
        const keepIds = normalizedAttachments.map((attachment) => attachment.id);
        const placeholders = keepIds.map(() => "?").join(", ");
        this.db
          .prepare(
            `
            DELETE FROM attachments
            WHERE message_id = ? AND id NOT IN (${placeholders})
          `,
          )
          .run(input.id, ...keepIds);
      }

      const attachmentStmt = this.db.prepare(
        `
        INSERT INTO attachments(id, message_id, url, filename, content_type, size)
        VALUES (@id, @messageId, @url, @filename, @contentType, @size)
        ON CONFLICT(message_id, url) DO UPDATE SET
          id = excluded.id,
          filename = excluded.filename,
          content_type = excluded.content_type,
          size = excluded.size
      `,
      );

      for (const attachment of normalizedAttachments) {
        attachmentStmt.run({
          ...attachment,
          messageId: input.id,
        });
      }
    });

    tx();
  }

  recordChannelAccess(input: ChannelAccessInput): void {
    this.db
      .prepare(
        `
        INSERT INTO channel_access(
          channel_id,
          can_view,
          can_read_history,
          has_message_content,
          last_backfill_at,
          last_error
        )
        VALUES (@channelId, @canView, @canReadHistory, @hasMessageContent, @lastBackfillAt, @lastError)
        ON CONFLICT(channel_id) DO UPDATE SET
          can_view = excluded.can_view,
          can_read_history = excluded.can_read_history,
          has_message_content = excluded.has_message_content,
          last_backfill_at = excluded.last_backfill_at,
          last_error = excluded.last_error
      `,
      )
      .run({
        ...input,
        canView: input.canView ? 1 : 0,
        canReadHistory: input.canReadHistory ? 1 : 0,
        hasMessageContent: input.hasMessageContent ? 1 : 0,
        lastBackfillAt: input.lastBackfillAt ?? null,
        lastError: input.lastError ?? null,
      });
  }

  private getInternalMetaValue(key: string): string | undefined {
    const row = this.db
      .prepare("SELECT value FROM internal_meta WHERE key = ?")
      .get(key) as { value: string } | undefined;
    return row?.value;
  }

  private setInternalMetaValue(key: string, value: string): void {
    this.db
      .prepare(
        `
        INSERT INTO internal_meta(key, value)
        VALUES(?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
      `,
      )
      .run(key, value);
  }

  private deleteInternalMetaValue(key: string): void {
    this.db
      .prepare("DELETE FROM internal_meta WHERE key = ?")
      .run(key);
  }

  getChatMode(guildId: string): ChatMode | undefined {
    const value = this.getInternalMetaValue(chatModeKey(guildId));
    if (!value || !CHAT_MODE_VALUES.has(value as ChatMode)) {
      return undefined;
    }
    return value as ChatMode;
  }

  setChatMode(guildId: string, mode: ChatMode): void {
    this.setInternalMetaValue(chatModeKey(guildId), mode);
  }

  getChatThreadMode(guildId: string): ChatThreadMode {
    const value = this.getInternalMetaValue(chatThreadModeKey(guildId));
    if (!value || !CHAT_THREAD_MODE_VALUES.has(value as ChatThreadMode)) {
      return "auto";
    }
    return value as ChatThreadMode;
  }

  setChatThreadMode(guildId: string, mode: ChatThreadMode): void {
    this.setInternalMetaValue(chatThreadModeKey(guildId), mode);
  }

  isChatDebugEnabled(): boolean {
    const value = this.getInternalMetaValue(chatDebugKey);
    return value ? TRUTHY_INTERNAL_META_VALUES.has(value.trim().toLowerCase()) : false;
  }

  setChatDebugEnabled(enabled: boolean): void {
    this.setInternalMetaValue(chatDebugKey, enabled ? "1" : "0");
  }

  enableChatChannel(guildId: string, channelId: string): void {
    this.db
      .prepare(
        `
        INSERT INTO chat_channels(guild_id, channel_id, enabled, updated_at)
        VALUES(?, ?, 1, ?)
        ON CONFLICT(guild_id, channel_id) DO UPDATE SET
          enabled = 1,
          updated_at = excluded.updated_at
      `,
      )
      .run(guildId, channelId, new Date().toISOString());
  }

  disableChatChannel(guildId: string, channelId: string): void {
    this.db
      .prepare("DELETE FROM chat_channels WHERE guild_id = ? AND channel_id = ?")
      .run(guildId, channelId);
  }

  isChatChannelEnabled(guildId: string, channelId: string): boolean {
    const row = this.db
      .prepare(
        `
        SELECT 1 AS enabled
        FROM chat_channels
        WHERE guild_id = ? AND channel_id = ? AND enabled = 1
      `,
      )
      .get(guildId, channelId) as { enabled: number } | undefined;
    return Boolean(row?.enabled);
  }

  listChatEnabledChannels(guildId: string, limit = 20): string[] {
    const safeLimit = Math.max(1, Math.min(limit, 500));
    const rows = this.db
      .prepare(
        `
        SELECT channel_id
        FROM chat_channels
        WHERE guild_id = ? AND enabled = 1
        ORDER BY channel_id ASC
        LIMIT ?
      `,
      )
      .all(guildId, safeLimit) as Array<{ channel_id: string }>;
    return rows.map((row) => row.channel_id);
  }

  getChatThreadRoute(
    guildId: string,
    channelId: string,
    userId: string,
  ): ChatThreadRoute | undefined {
    const row = this.db
      .prepare(
        `
        SELECT thread_id, updated_at
        FROM chat_thread_routes
        WHERE guild_id = ? AND channel_id = ? AND user_id = ?
      `,
      )
      .get(guildId, channelId, userId) as
      | { thread_id: string; updated_at: string }
      | undefined;

    if (!row) {
      return undefined;
    }

    return {
      threadId: row.thread_id,
      updatedAt: row.updated_at,
    };
  }

  setChatThreadRoute(
    guildId: string,
    channelId: string,
    userId: string,
    threadId: string,
    updatedAt = new Date().toISOString(),
  ): void {
    this.db
      .prepare(
        `
        INSERT INTO chat_thread_routes(guild_id, channel_id, user_id, thread_id, updated_at)
        VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(guild_id, channel_id, user_id) DO UPDATE SET
          thread_id = excluded.thread_id,
          updated_at = excluded.updated_at
      `,
      )
      .run(guildId, channelId, userId, threadId, updatedAt);
  }

  countChatThreadRoutes(guildId: string): number {
    return (
      this.db
        .prepare("SELECT COUNT(*) AS c FROM chat_thread_routes WHERE guild_id = ?")
        .get(guildId) as { c: number }
    ).c;
  }

  insertModAction(input: ModActionInput): void {
    this.db
      .prepare(
        `
        INSERT INTO mod_actions(
          id,
          ts,
          guild_id,
          channel_id,
          target_user_id,
          action,
          reason,
          approved_by,
          evidence_json
        )
        VALUES (
          @id,
          @ts,
          @guildId,
          @channelId,
          @targetUserId,
          @action,
          @reason,
          @approvedBy,
          @evidenceJson
        )
      `,
      )
      .run({
        ...input,
        guildId: input.guildId ?? null,
        channelId: input.channelId ?? null,
        targetUserId: input.targetUserId ?? null,
        reason: input.reason ?? null,
        approvedBy: input.approvedBy ?? null,
      });
  }

  queueApproval(input: PendingApprovalInput): void {
    this.db
      .prepare(
        `
        INSERT INTO pending_approvals(
          id,
          ts,
          guild_id,
          channel_id,
          target_user_id,
          action,
          reason,
          payload_json,
          requested_by,
          status,
          approved_by,
          executed_at
        )
        VALUES (
          @id,
          @ts,
          @guildId,
          @channelId,
          @targetUserId,
          @action,
          @reason,
          @payloadJson,
          @requestedBy,
          @status,
          NULL,
          NULL
        )
      `,
      )
      .run({
        ...input,
        guildId: input.guildId ?? null,
        channelId: input.channelId ?? null,
        targetUserId: input.targetUserId ?? null,
        reason: input.reason ?? null,
        requestedBy: input.requestedBy ?? null,
      });
  }

  getPendingApproval(id: string): PendingApprovalRecord | undefined {
    return this.db
      .prepare("SELECT * FROM pending_approvals WHERE id = ?")
      .get(id) as PendingApprovalRecord | undefined;
  }

  markApprovalApproved(id: string, approvedBy: string): void {
    this.db
      .prepare(
        "UPDATE pending_approvals SET status = 'approved', approved_by = ? WHERE id = ? AND status = 'pending'",
      )
      .run(approvedBy, id);
  }

  markApprovalExecuted(id: string, approvedBy: string): void {
    this.db
      .prepare(
        `
        UPDATE pending_approvals
        SET status = 'executed', approved_by = ?, executed_at = ?
        WHERE id = ?
      `,
      )
      .run(approvedBy, new Date().toISOString(), id);
  }

  getDbStats(): {
    messages: number;
    attachments: number;
    users: number;
    channels: number;
    ftsRows: number;
    ftsReady: boolean;
  } {
    const getCount = (table: string): number =>
      (this.db.prepare(`SELECT COUNT(*) AS c FROM ${table}`).get() as { c: number }).c;

    const ftsReady =
      (
        this.db
          .prepare(
            "SELECT COUNT(*) AS c FROM sqlite_master WHERE type = 'table' AND name = 'messages_fts'",
          )
          .get() as { c: number }
      ).c > 0;

    return {
      messages: getCount("messages"),
      attachments: getCount("attachments"),
      users: getCount("users"),
      channels: getCount("channels"),
      ftsRows: ftsReady ? getCount("messages_fts") : 0,
      ftsReady,
    };
  }

  getBackfillSummary(): {
    totalTrackedChannels: number;
    readableChannels: number;
    nonReadableChannels: number;
    completedBackfills: number;
    lastBackfillAt?: string;
  } {
    const totalTrackedChannels =
      (this.db.prepare("SELECT COUNT(*) AS c FROM channel_access").get() as { c: number }).c ?? 0;

    const readableChannels =
      (
        this.db
          .prepare("SELECT COUNT(*) AS c FROM channel_access WHERE can_view = 1 AND can_read_history = 1")
          .get() as { c: number }
      ).c ?? 0;

    const nonReadableChannels = totalTrackedChannels - readableChannels;

    const completedBackfills =
      (
        this.db
          .prepare("SELECT COUNT(*) AS c FROM channel_access WHERE last_backfill_at IS NOT NULL")
          .get() as { c: number }
      ).c ?? 0;

    const lastBackfillAt =
      (
        this.db
          .prepare(
            "SELECT last_backfill_at FROM channel_access WHERE last_backfill_at IS NOT NULL ORDER BY last_backfill_at DESC LIMIT 1",
          )
          .get() as { last_backfill_at?: string } | undefined
      )?.last_backfill_at;

    return {
      totalTrackedChannels,
      readableChannels,
      nonReadableChannels,
      completedBackfills,
      lastBackfillAt,
    };
  }

  getChannelLastBackfillAt(channelId: string): string | undefined {
    const row = this.db
      .prepare(
        `
        SELECT last_backfill_at
        FROM channel_access
        WHERE channel_id = ?
      `,
      )
      .get(channelId) as { last_backfill_at: string | null } | undefined;
    return row?.last_backfill_at ?? undefined;
  }

  markIndexRunStarted(runAtIso = new Date().toISOString(), indexVersion?: string): void {
    this.setInternalMetaValue(LAST_INDEX_RUN_AT_KEY, runAtIso);
    if (indexVersion) {
      this.setInternalMetaValue(INDEX_VERSION_KEY, indexVersion);
    }
  }

  markIndexRunSuccess(okAtIso = new Date().toISOString(), indexVersion?: string): void {
    this.setInternalMetaValue(LAST_INDEX_RUN_AT_KEY, okAtIso);
    this.setInternalMetaValue(LAST_INDEX_OK_AT_KEY, okAtIso);
    this.deleteInternalMetaValue(LAST_INDEX_ERROR_KEY);
    if (indexVersion) {
      this.setInternalMetaValue(INDEX_VERSION_KEY, indexVersion);
    }
  }

  markIndexRunError(errorMessage: string, runAtIso = new Date().toISOString(), indexVersion?: string): void {
    this.setInternalMetaValue(LAST_INDEX_RUN_AT_KEY, runAtIso);
    this.setInternalMetaValue(LAST_INDEX_ERROR_KEY, errorMessage);
    if (indexVersion) {
      this.setInternalMetaValue(INDEX_VERSION_KEY, indexVersion);
    }
  }

  getIndexStatus(): IndexStatus {
    return {
      lastIndexRunAt: this.getInternalMetaValue(LAST_INDEX_RUN_AT_KEY),
      lastIndexOkAt: this.getInternalMetaValue(LAST_INDEX_OK_AT_KEY),
      lastIndexError: this.getInternalMetaValue(LAST_INDEX_ERROR_KEY),
      indexVersion: this.getInternalMetaValue(INDEX_VERSION_KEY),
    };
  }

  getIndexDuplicateStats(): IndexDuplicateStats {
    const countDuplicateRows = (sql: string): number => {
      const row = this.db.prepare(sql).get() as { duplicate_rows: number | null } | undefined;
      return row?.duplicate_rows ?? 0;
    };

    return {
      messageIdDuplicates: countDuplicateRows(`
        SELECT COALESCE(SUM(c - 1), 0) AS duplicate_rows
        FROM (SELECT COUNT(*) AS c FROM messages GROUP BY id HAVING COUNT(*) > 1)
      `),
      attachmentIdDuplicates: countDuplicateRows(`
        SELECT COALESCE(SUM(c - 1), 0) AS duplicate_rows
        FROM (SELECT COUNT(*) AS c FROM attachments GROUP BY id HAVING COUNT(*) > 1)
      `),
      attachmentMessageUrlDuplicates: countDuplicateRows(`
        SELECT COALESCE(SUM(c - 1), 0) AS duplicate_rows
        FROM (
          SELECT COUNT(*) AS c
          FROM attachments
          GROUP BY message_id, url
          HAVING COUNT(*) > 1
        )
      `),
    };
  }

  getFtsConsistencyStats(): FtsConsistencyStats {
    const messagesCount =
      (this.db.prepare("SELECT COUNT(*) AS c FROM messages").get() as { c: number }).c ?? 0;

    const ftsReady =
      (
        this.db
          .prepare(
            "SELECT COUNT(*) AS c FROM sqlite_master WHERE type = 'table' AND name = 'messages_fts'",
          )
          .get() as { c: number }
      ).c > 0;

    if (!ftsReady) {
      return {
        ftsReady: false,
        messagesCount,
        ftsRows: 0,
        missingFtsRows: messagesCount,
        orphanFtsRows: 0,
        duplicateFtsMessageIds: 0,
        consistent: false,
      };
    }

    const ftsRows =
      (this.db.prepare("SELECT COUNT(*) AS c FROM messages_fts").get() as { c: number }).c ?? 0;
    const missingFtsRows =
      (
        this.db
          .prepare(
            `
            SELECT COUNT(*) AS c
            FROM messages m
            LEFT JOIN messages_fts f ON f.message_id = m.id
            WHERE f.message_id IS NULL
          `,
          )
          .get() as { c: number }
      ).c ?? 0;
    const orphanFtsRows =
      (
        this.db
          .prepare(
            `
            SELECT COUNT(*) AS c
            FROM messages_fts f
            LEFT JOIN messages m ON m.id = f.message_id
            WHERE m.id IS NULL
          `,
          )
          .get() as { c: number }
      ).c ?? 0;
    const duplicateFtsMessageIds =
      (
        this.db
          .prepare(
            `
            SELECT COALESCE(SUM(c - 1), 0) AS duplicate_rows
            FROM (SELECT COUNT(*) AS c FROM messages_fts GROUP BY message_id HAVING COUNT(*) > 1)
          `,
          )
          .get() as { duplicate_rows: number | null }
      ).duplicate_rows ?? 0;

    return {
      ftsReady: true,
      messagesCount,
      ftsRows,
      missingFtsRows,
      orphanFtsRows,
      duplicateFtsMessageIds,
      consistent:
        messagesCount === ftsRows &&
        missingFtsRows === 0 &&
        orphanFtsRows === 0 &&
        duplicateFtsMessageIds === 0,
    };
  }

  getEvidenceAvailabilityStats(): EvidenceAvailabilityStats {
    const row = this.db
      .prepare(
        `
        SELECT
          COUNT(*) AS total_messages,
          SUM(CASE WHEN m.content_unavailable = 1 THEN 1 ELSE 0 END) AS unavailable_messages
        FROM messages m
        LEFT JOIN users u ON u.id = m.author_id
        WHERE ${EVIDENCE_MESSAGE_FILTER_SQL}
      `,
      )
      .get() as { total_messages: number; unavailable_messages: number | null };

    const totalMessages = row.total_messages ?? 0;
    const unavailableMessages = row.unavailable_messages ?? 0;
    const unavailableRatio = totalMessages > 0 ? unavailableMessages / totalMessages : 0;

    return {
      totalMessages,
      unavailableMessages,
      unavailableRatio,
    };
  }

  getCoverageReport(limit = 20): CoverageReport {
    const readable =
      (
        this.db
          .prepare("SELECT COUNT(*) AS c FROM channel_access WHERE can_view = 1 AND can_read_history = 1")
          .get() as { c: number }
      ).c ?? 0;

    const unreadable =
      (
        this.db
          .prepare(
            "SELECT COUNT(*) AS c FROM channel_access WHERE can_view = 0 OR can_read_history = 0 OR last_error IS NOT NULL",
          )
          .get() as { c: number }
      ).c ?? 0;

    const skippedRows = this.db
      .prepare(
        `\n        SELECT channel_id, last_error\n        FROM channel_access\n        WHERE last_error IS NOT NULL\n        ORDER BY channel_id ASC\n        LIMIT ?\n      `,
      )
      .all(limit) as Array<{ channel_id: string; last_error: string }>;

    return {
      readable,
      unreadable,
      skipped: skippedRows.map((row) => ({ channelId: row.channel_id, reason: row.last_error })),
    };
  }

  searchMessages(filters: SearchFilters): SearchRow[] {
    const cleaned = sanitizeFtsQuery(filters.query);
    if (!cleaned) {
      return [];
    }

    const where: string[] = ["f.content MATCH ?", EVIDENCE_MESSAGE_FILTER_SQL];
    const params: Array<string | number> = [cleaned];

    if (filters.guildId) {
      where.push("m.guild_id = ?");
      params.push(filters.guildId);
    }
    if (filters.channelId) {
      where.push("m.channel_id = ?");
      params.push(filters.channelId);
    }
    if (filters.userId) {
      where.push("m.author_id = ?");
      params.push(filters.userId);
    }
    if (filters.since) {
      where.push("m.created_at >= ?");
      params.push(filters.since);
    }
    if (filters.until) {
      where.push("m.created_at <= ?");
      params.push(filters.until);
    }

    const limit = Math.min(Math.max(filters.limit ?? 10, 1), 50);

    const sql = `
      SELECT
        m.id,
        m.guild_id,
        m.channel_id,
        m.author_id,
        m.created_at,
        m.edited_at,
        m.content,
        m.content_unavailable
      FROM messages_fts f
      JOIN messages m ON m.id = f.message_id
      LEFT JOIN users u ON u.id = m.author_id
      WHERE ${where.join(" AND ")}
      ORDER BY m.created_at DESC
      LIMIT ?
    `;

    params.push(limit);
    return this.db.prepare(sql).all(...params) as SearchRow[];
  }

  getRecentMessagesByAuthorInChannel(
    authorId: string,
    channelId: string,
    sinceIso: string,
    maxRows: number,
  ): MessageWindowRow[] {
    return this.db
      .prepare(
        `
        SELECT id, guild_id, channel_id, author_id, created_at, content, content_unavailable
        FROM messages
        WHERE author_id = ? AND channel_id = ? AND created_at >= ?
        ORDER BY created_at DESC
        LIMIT ?
      `,
      )
      .all(authorId, channelId, sinceIso, maxRows) as MessageWindowRow[];
  }

  getChannelWindowMessages(
    channelId: string,
    sinceIso: string,
    untilIso: string,
    limit: number,
  ): MessageWindowRow[] {
    const safeLimit = Math.max(1, Math.min(limit, 5000));
    return this.db
      .prepare(
        `
        SELECT
          m.id,
          m.guild_id,
          m.channel_id,
          m.author_id,
          m.created_at,
          m.content,
          m.content_unavailable
        FROM messages m
        LEFT JOIN users u ON u.id = m.author_id
        WHERE
          m.channel_id = ?
          AND m.created_at >= ?
          AND m.created_at <= ?
          AND ${EVIDENCE_MESSAGE_FILTER_SQL}
        ORDER BY m.created_at DESC
        LIMIT ?
      `,
      )
      .all(channelId, sinceIso, untilIso, safeLimit) as MessageWindowRow[];
  }

  getGuildWindowMessages(
    guildId: string,
    sinceIso: string,
    untilIso: string,
    limit: number,
  ): MessageWindowRow[] {
    const safeLimit = Math.max(1, Math.min(limit, 5000));
    return this.db
      .prepare(
        `
        SELECT
          m.id,
          m.guild_id,
          m.channel_id,
          m.author_id,
          m.created_at,
          m.content,
          m.content_unavailable
        FROM messages m
        LEFT JOIN users u ON u.id = m.author_id
        WHERE
          m.guild_id = ?
          AND m.created_at >= ?
          AND m.created_at <= ?
          AND ${EVIDENCE_MESSAGE_FILTER_SQL}
        ORDER BY m.created_at DESC
        LIMIT ?
      `,
      )
      .all(guildId, sinceIso, untilIso, safeLimit) as MessageWindowRow[];
  }

  getRecentReadableMessagesByChannel(channelId: string, limit: number): MessageWindowRow[] {
    const safeLimit = Math.max(1, Math.min(limit, 20000));
    return this.db
      .prepare(
        `
        SELECT
          m.id,
          m.guild_id,
          m.channel_id,
          m.author_id,
          m.created_at,
          m.content,
          m.content_unavailable
        FROM messages m
        LEFT JOIN users u ON u.id = m.author_id
        WHERE
          m.channel_id = ?
          AND ${EVIDENCE_MESSAGE_FILTER_SQL}
          AND ${READABLE_EVIDENCE_MESSAGE_SQL}
        ORDER BY m.created_at DESC
        LIMIT ?
      `,
      )
      .all(channelId, safeLimit) as MessageWindowRow[];
  }

  getRecentReadableMessagesByGuild(guildId: string, limit: number): MessageWindowRow[] {
    const safeLimit = Math.max(1, Math.min(limit, 20000));
    return this.db
      .prepare(
        `
        SELECT
          m.id,
          m.guild_id,
          m.channel_id,
          m.author_id,
          m.created_at,
          m.content,
          m.content_unavailable
        FROM messages m
        LEFT JOIN users u ON u.id = m.author_id
        WHERE
          m.guild_id = ?
          AND ${EVIDENCE_MESSAGE_FILTER_SQL}
          AND ${READABLE_EVIDENCE_MESSAGE_SQL}
        ORDER BY m.created_at DESC
        LIMIT ?
      `,
      )
      .all(guildId, safeLimit) as MessageWindowRow[];
  }

  getMessagesForChannelWindow(
    channelId: string,
    sinceIso: string,
    limit: number,
  ): MessageWindowRow[] {
    return this.getChannelWindowMessages(channelId, sinceIso, "9999-12-31T23:59:59.999Z", limit);
  }

  getUserWindowMessages(
    userId: string,
    sinceIso: string,
    untilIso: string,
    limit: number,
  ): MessageWindowRow[] {
    const safeLimit = Math.max(1, Math.min(limit, 5000));
    return this.db
      .prepare(
        `
        SELECT
          m.id,
          m.guild_id,
          m.channel_id,
          m.author_id,
          m.created_at,
          m.content,
          m.content_unavailable
        FROM messages m
        LEFT JOIN users u ON u.id = m.author_id
        WHERE
          m.author_id = ?
          AND m.created_at >= ?
          AND m.created_at <= ?
          AND ${EVIDENCE_MESSAGE_FILTER_SQL}
        ORDER BY m.created_at DESC
        LIMIT ?
      `,
      )
      .all(userId, sinceIso, untilIso, safeLimit) as MessageWindowRow[];
  }

  getMessagesForUserWindow(userId: string, sinceIso: string, limit: number): MessageWindowRow[] {
    return this.getUserWindowMessages(userId, sinceIso, "9999-12-31T23:59:59.999Z", limit);
  }

  getMessageById(messageId: string): MessageWindowRow | undefined {
    return this.db
      .prepare(
        `
        SELECT id, guild_id, channel_id, author_id, created_at, content, content_unavailable
        FROM messages
        WHERE id = ?
      `,
      )
      .get(messageId) as MessageWindowRow | undefined;
  }

  getMessageCoverageStats(scope: MessageCoverageScope): MessageCoverageStats {
    const where: string[] = ["m.created_at >= ?", "m.created_at <= ?", EVIDENCE_MESSAGE_FILTER_SQL];
    const params: Array<string | number> = [scope.sinceIso, scope.untilIso];

    if (scope.guildId) {
      where.push("m.guild_id = ?");
      params.push(scope.guildId);
    }

    if (scope.channelId) {
      where.push("m.channel_id = ?");
      params.push(scope.channelId);
    }

    if (scope.userId) {
      where.push("m.author_id = ?");
      params.push(scope.userId);
    }

    const row = this.db
      .prepare(
        `
        SELECT
          COUNT(*) AS total_messages,
          SUM(CASE
            WHEN m.content_unavailable = 0 AND m.content IS NOT NULL AND TRIM(m.content) <> ''
            THEN 1 ELSE 0 END
          ) AS available_messages
        FROM messages m
        LEFT JOIN users u ON u.id = m.author_id
        WHERE ${where.join(" AND ")}
      `,
      )
      .get(...params) as { total_messages: number; available_messages: number | null };

    const totalMessages = row.total_messages ?? 0;
    const availableMessages = row.available_messages ?? 0;
    const unavailableMessages = Math.max(totalMessages - availableMessages, 0);
    const coverageRatio = totalMessages > 0 ? availableMessages / totalMessages : 0;

    return {
      totalMessages,
      availableMessages,
      unavailableMessages,
      coverageRatio,
    };
  }

  getAttachmentsForMessageIds(messageIds: string[]): AttachmentLookupRow[] {
    if (messageIds.length === 0) {
      return [];
    }

    const placeholders = messageIds.map(() => "?").join(", ");
    return this.db
      .prepare(
        `
        SELECT id, message_id, url, filename, content_type, size
        FROM attachments
        WHERE message_id IN (${placeholders})
        ORDER BY message_id ASC, id ASC
      `,
      )
      .all(...messageIds) as AttachmentLookupRow[];
  }

  getUserMap(ids: string[]): Map<string, UserLookupRow> {
    if (ids.length === 0) {
      return new Map<string, UserLookupRow>();
    }

    const placeholders = ids.map(() => "?").join(", ");
    const rows = this.db
      .prepare(
        `
        SELECT id, username, global_name, bot
        FROM users
        WHERE id IN (${placeholders})
      `,
      )
      .all(...ids) as UserLookupRow[];

    return new Map(rows.map((row) => [row.id, row]));
  }

  getChannelMap(ids: string[]): Map<string, ChannelLookupRow> {
    if (ids.length === 0) {
      return new Map<string, ChannelLookupRow>();
    }

    const placeholders = ids.map(() => "?").join(", ");
    const rows = this.db
      .prepare(
        `
        SELECT id, guild_id, name, type, parent_id
        FROM channels
        WHERE id IN (${placeholders})
      `,
      )
      .all(...ids) as ChannelLookupRow[];

    return new Map(rows.map((row) => [row.id, row]));
  }

  getMessagesForExport(guildId: string, channelId?: string): ExportMessageRow[] {
    if (channelId) {
      return this.db
        .prepare(
          `
          SELECT id, created_at, channel_id, author_id, content, content_unavailable
          FROM messages
          WHERE guild_id = ? AND channel_id = ?
          ORDER BY created_at ASC
        `,
        )
        .all(guildId, channelId) as ExportMessageRow[];
    }

    return this.db
      .prepare(
        `
        SELECT id, created_at, channel_id, author_id, content, content_unavailable
        FROM messages
        WHERE guild_id = ?
        ORDER BY created_at ASC
      `,
      )
      .all(guildId) as ExportMessageRow[];
  }
}
