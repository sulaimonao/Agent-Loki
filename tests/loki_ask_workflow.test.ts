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

const buildAskInteraction = (prompt: string) => {
  const deferReply = vi.fn(async () => undefined);
  const editReply = vi.fn(async () => undefined);

  const interaction = {
    guildId: "g1",
    channelId: "c1",
    deferReply,
    editReply,
    options: {
      getSubcommandGroup: vi.fn(() => null),
      getSubcommand: vi.fn(() => "ask"),
      getString: vi.fn((name: string) => {
        if (name === "prompt") {
          return prompt;
        }
        return null;
      }),
      getChannel: vi.fn(() => null),
      getInteger: vi.fn(() => null),
    },
  };

  return {
    interaction,
    deferReply,
    editReply,
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

describe("/loki ask workflow", () => {
  test("uses recent-by-count strategy by default and includes citations", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-ask-count-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c1", guildId: "g1", name: "ops", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });

    const thirtyHoursAgo = Date.now() - 30 * 60 * 60 * 1000;
    db.upsertMessage(
      {
        id: "m1",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt: new Date(thirtyHoursAgo).toISOString(),
        content: "deploy update with grounded evidence",
        contentUnavailable: false,
        rawJson: "{}",
      },
      [],
    );

    const { interaction, editReply } = buildAskInteraction("deploy update");
    await handleLokiCommand(
      interaction as unknown as Parameters<typeof handleLokiCommand>[0],
      buildContext(db, tempDir),
    );

    const payload = editReply.mock.calls[0]?.[0];
    const content = extractReplyContent(payload);
    expect(content).toContain("Evidence strategy: recent-by-count (latest 300 readable messages).");
    expect(content).toContain("https://discord.com/channels/g1/c1/m1");

    db.close();
  });

  test("uses time-window strategy when the prompt is time-scoped", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-ask-time-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c1", guildId: "g1", name: "ops", type: "GuildText" });

    const { interaction, editReply } = buildAskInteraction("what happened today");
    await handleLokiCommand(
      interaction as unknown as Parameters<typeof handleLokiCommand>[0],
      buildContext(db, tempDir),
    );

    const payload = editReply.mock.calls[0]?.[0];
    const content = extractReplyContent(payload);
    expect(content).toContain("No activity found for this request.");
    expect(content).toContain("Evidence strategy: time-window (last 24h).");
    expect(content).toContain("Try `scope:server`");
    expect(content).toContain("Run `/loki backfill scope:all`");

    db.close();
  });
});
