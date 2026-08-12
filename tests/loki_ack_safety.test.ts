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

describe("/loki slash ACK safety", () => {
  test("defers before reading slash options", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-ack-order-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    const callOrder: string[] = [];
    const interaction = {
      deferred: false,
      replied: false,
      guildId: "g1",
      guild: null,
      deferReply: vi.fn(async () => {
        callOrder.push("defer");
        interaction.deferred = true;
      }),
      editReply: vi.fn(async () => {
        callOrder.push("edit");
        interaction.replied = true;
      }),
      options: {
        getSubcommandGroup: vi.fn(() => {
          callOrder.push("group");
          return "index";
        }),
        getSubcommand: vi.fn(() => {
          callOrder.push("sub");
          return "verify";
        }),
      },
    };

    await handleLokiCommand(
      interaction as unknown as Parameters<typeof handleLokiCommand>[0],
      buildContext(db, tempDir),
    );

    expect(callOrder[0]).toBe("defer");
    expect(interaction.deferReply).toHaveBeenCalledTimes(1);
    expect(interaction.editReply).toHaveBeenCalledTimes(1);

    db.close();
  });

  test("edits deferred reply in finally when command throws before response", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-ack-finally-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    const interaction = {
      deferred: false,
      replied: false,
      guildId: "g1",
      guild: null,
      deferReply: vi.fn(async () => {
        interaction.deferred = true;
      }),
      editReply: vi.fn(async () => {
        interaction.replied = true;
      }),
      options: {
        getSubcommandGroup: vi.fn(() => {
          throw new Error("subcommand parse failed");
        }),
        getSubcommand: vi.fn(() => "status"),
      },
    };

    await expect(
      handleLokiCommand(
        interaction as unknown as Parameters<typeof handleLokiCommand>[0],
        buildContext(db, tempDir),
      ),
    ).rejects.toThrow("subcommand parse failed");

    expect(interaction.deferReply).toHaveBeenCalledTimes(1);
    expect(interaction.editReply).toHaveBeenCalledTimes(1);
    expect(interaction.editReply.mock.calls[0]?.[0]).toBe(
      "Loki could not complete that command. Please retry.",
    );

    db.close();
  });
});
