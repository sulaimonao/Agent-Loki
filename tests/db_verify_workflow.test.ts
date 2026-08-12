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
    hasMessageContent: true,
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

describe("/loki db verify workflow", () => {
  test("prints short db health report with duplicate and FTS checks", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-db-verify-"));
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
        content: "deploy status normal",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [
        {
          id: "a1",
          url: "https://example.com/a1.png",
          filename: "a1.png",
          contentType: "image/png",
          size: 123,
        },
      ],
    );

    const deferReply = vi.fn(async () => undefined);
    const editReply = vi.fn(async () => undefined);
    const interaction = {
      deferReply,
      editReply,
      guildId: "g1",
      guild: null,
      options: {
        getSubcommandGroup: vi.fn(() => "db"),
        getSubcommand: vi.fn(() => "verify"),
      },
    };

    await handleLokiCommand(
      interaction as unknown as Parameters<typeof handleLokiCommand>[0],
      buildContext(db, tempDir),
    );

    const payload = editReply.mock.calls[0]?.[0];
    const content = extractReplyContent(payload);
    expect(content).toContain("Loki db verify");
    expect(content).toContain("Health: ok");
    expect(content).toContain("Attachment duplicates: id=0, message_url=0");
    expect(content).toContain("FTS consistency: ok");
    expect(content).toContain("Warnings: none");

    db.close();
  });
});
