import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, test, vi } from "vitest";
import { handleLokiCommand, type LokiCommandContext } from "../src/discord/commands/loki";
import { LokiDb } from "../src/storage/db";

const buildContext = (db: LokiDb, dataDir: string): LokiCommandContext => {
  return {
    config: {
      discordToken: "test",
      discordClientId: "test",
      guildAllowlist: [],
      dbMode: "shared",
      dataDir,
      dbPath: path.join(dataDir, "test.db"),
      logDir: path.join(dataDir, "logs"),
      checkpointDir: path.join(dataDir, "checkpoints"),
      policyPath: path.join(dataDir, "policy.yaml"),
      enableEnforcement: false,
      ollamaUrl: "http://127.0.0.1:11434",
      ollamaModel: "test-model",
    },
    db,
    logger: { logEvent: () => undefined } as unknown as LokiCommandContext["logger"],
    policyManager: { show: () => "{}", reload: () => undefined } as unknown as LokiCommandContext["policyManager"],
    analyzer: {} as LokiCommandContext["analyzer"],
    approvals: {} as LokiCommandContext["approvals"],
    ollama: {} as LokiCommandContext["ollama"],
    hasMessageContent: false,
  };
};

const extractReplyContent = (payload: unknown): string => {
  if (typeof payload === "string") {
    return payload;
  }

  if (payload && typeof payload === "object" && "content" in payload) {
    const value = (payload as { content?: unknown }).content;
    return typeof value === "string" ? value : "";
  }

  return "";
};

describe("/loki index verify workflow", () => {
  test("reports duplicate checks and warnings", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-index-verify-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c1", guildId: "g1", name: "ops", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });
    db.upsertMessage(
      {
        id: "m1",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt: new Date().toISOString(),
        editedAt: null,
        content: null,
        contentUnavailable: true,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );

    const deferReply = vi.fn(async () => undefined);
    const editReply = vi.fn(async () => undefined);
    const interaction = {
      deferReply,
      editReply,
      guildId: "g1",
      guild: null,
      options: {
        getSubcommandGroup: vi.fn(() => "index"),
        getSubcommand: vi.fn(() => "verify"),
      },
    };

    await handleLokiCommand(
      interaction as unknown as Parameters<typeof handleLokiCommand>[0],
      buildContext(db, tempDir),
    );

    const payload = editReply.mock.calls[0]?.[0];
    const content = extractReplyContent(payload);
    expect(content).toContain("Loki index verify");
    expect(content).toContain("messages.id duplicates: 0");
    expect(content).toContain("attachments.id duplicates: 0");
    expect(content).toContain("attachments(message_id,url) duplicates: 0");
    expect(content).toContain("Content unavailable ratio:");
    expect(content).toContain("Message Content intent is unavailable");

    db.close();
  });

  test("refuses commands in unapproved guilds", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-index-verify-deny-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    const deferReply = vi.fn(async () => undefined);
    const editReply = vi.fn(async () => undefined);
    const interaction = {
      deferReply,
      editReply,
      guildId: "g9",
      guild: null,
      options: {
        getSubcommandGroup: vi.fn(() => "index"),
        getSubcommand: vi.fn(() => "verify"),
      },
    };

    await handleLokiCommand(
      interaction as unknown as Parameters<typeof handleLokiCommand>[0],
      {
        ...buildContext(db, tempDir),
        isGuildAllowed: (guildId) => guildId === "g1",
      },
    );

    const payload = editReply.mock.calls[0]?.[0];
    const content = extractReplyContent(payload);
    expect(content).toContain("not approved");

    db.close();
  });
});
