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
      discordGuildId: undefined,
      guildAllowlist: ["g1", "g2"],
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
    isGuildAllowed: (guildId) => guildId === "g1",
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

describe("/loki isolation status workflow", () => {
  test("reports allowlist and db mode at runtime", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-isolation-status-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    const deferReply = vi.fn(async () => undefined);
    const editReply = vi.fn(async () => undefined);
    const interaction = {
      deferReply,
      editReply,
      guildId: "g1",
      options: {
        getSubcommandGroup: vi.fn(() => "isolation"),
        getSubcommand: vi.fn(() => "status"),
      },
    };

    await handleLokiCommand(
      interaction as unknown as Parameters<typeof handleLokiCommand>[0],
      buildContext(db, tempDir),
    );

    const payload = editReply.mock.calls[0]?.[0];
    const content = extractReplyContent(payload);
    expect(content).toContain("Loki isolation status");
    expect(content).toContain("DB mode: shared");
    expect(content).toContain("Allowlist: g1, g2");
    expect(content).toContain("Current guild allowed: yes");

    db.close();
  });

  test("isolation status still works in unapproved guild for diagnostics", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-isolation-status-denied-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    const deferReply = vi.fn(async () => undefined);
    const editReply = vi.fn(async () => undefined);
    const interaction = {
      deferReply,
      editReply,
      guildId: "g9",
      options: {
        getSubcommandGroup: vi.fn(() => "isolation"),
        getSubcommand: vi.fn(() => "status"),
      },
    };

    await handleLokiCommand(
      interaction as unknown as Parameters<typeof handleLokiCommand>[0],
      buildContext(db, tempDir),
    );

    const payload = editReply.mock.calls[0]?.[0];
    const content = extractReplyContent(payload);
    expect(content).toContain("Loki isolation status");
    expect(content).toContain("Current guild: g9");
    expect(content).toContain("Current guild allowed: no");

    db.close();
  });
});
