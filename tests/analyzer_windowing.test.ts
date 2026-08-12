import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, test } from "vitest";
import { Analyzer } from "../src/ai/analyzer";
import { OllamaClient } from "../src/ai/ollama";
import { LokiDb } from "../src/storage/db";

describe("analyzer window expansion", () => {
  test("expands summarize window from 24h to 168h when recent window is empty", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-window-expand-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c1", guildId: "g1", name: "general", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });

    const thirtyHoursAgo = Date.now() - 30 * 60 * 60 * 1000;
    for (let i = 0; i < 9; i += 1) {
      db.upsertMessage(
        {
          id: `m${i + 1}`,
          guildId: "g1",
          channelId: "c1",
          authorId: "u1",
          createdAt: new Date(thirtyHoursAgo - i * 60_000).toISOString(),
          editedAt: null,
          content: `release blocker detail ${i}`,
          contentUnavailable: false,
          replyToId: null,
          rawJson: "{}",
        },
        [],
      );
    }

    const analyzer = new Analyzer(db, new OllamaClient("http://127.0.0.1:11434"), "test-model");
    const result = await analyzer.summarizeChannelWindow({
      channelId: "c1",
      windowHours: 24,
      ai: "off",
    });

    expect(result.aiUsed).toBe(false);
    expect(result.text).toContain("Window analyzed: last 168h");
    expect(result.text).not.toContain("No activity in the last");

    db.close();
  });

  test("returns helpful no-activity response after checking up to 336h", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-window-empty-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c1", guildId: "g1", name: "general", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });

    const analyzer = new Analyzer(db, new OllamaClient("http://127.0.0.1:11434"), "test-model");
    const result = await analyzer.summarizeChannelWindow({
      channelId: "c1",
      windowHours: 24,
      ai: "off",
    });

    expect(result.aiUsed).toBe(false);
    expect(result.text).toContain("No activity in the last 336 hour(s)");
    expect(result.text).toContain("Suggested next actions:");

    db.close();
  });
});
