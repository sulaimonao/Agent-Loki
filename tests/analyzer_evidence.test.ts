import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, test } from "vitest";
import { Analyzer } from "../src/ai/analyzer";
import { OllamaClient } from "../src/ai/ollama";
import { LokiDb } from "../src/storage/db";

describe("analyzer evidence", () => {
  test("grounded summary includes jump-link citations", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-analyzer-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c1", guildId: "g1", name: "general", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });
    db.upsertUser({ id: "u2", username: "bob", bot: false });

    for (let i = 0; i < 10; i += 1) {
      const id = `m${i + 1}`;
      const authorId = i % 2 === 0 ? "u1" : "u2";
      const createdAt = new Date(Date.now() - i * 60_000).toISOString();

      db.upsertMessage(
        {
          id,
          guildId: "g1",
          channelId: "c1",
          authorId,
          createdAt,
          editedAt: null,
          content: `incident deploy error repeated token ${i}`,
          contentUnavailable: false,
          replyToId: null,
          rawJson: "{}",
        },
        i === 0
          ? [
              {
                id: "a1",
                url: "https://cdn.example.com/file1.png",
                filename: "file1.png",
                contentType: "image/png",
                size: 1024,
              },
            ]
          : [],
      );
    }

    const analyzer = new Analyzer(db, new OllamaClient("http://127.0.0.1:11434"), "test-model");
    const result = await analyzer.summarizeChannelWindow({
      channelId: "c1",
      windowHours: 24,
      ai: "off",
    });

    expect(result.aiUsed).toBe(false);
    expect(result.text).toContain("Header");
    expect(result.text).toContain("Evidence");
    expect(result.text).toContain("Summary");
    expect(result.text).toContain("Suggested next actions");

    const jumpLinks = result.text.match(/https:\/\/discord\.com\/channels\/g1\/c1\/m\d+/g) ?? [];
    expect(jumpLinks.length).toBeGreaterThanOrEqual(5);
    expect(result.text).toContain("https://cdn.example.com/file1.png");

    db.close();
  });

  test("answerFromSearchEvidence returns citations with jump links", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-analyzer-answer-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c1", guildId: "g1", name: "ops", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });

    for (let i = 0; i < 5; i += 1) {
      db.upsertMessage(
        {
          id: `q${i + 1}`,
          guildId: "g1",
          channelId: "c1",
          authorId: "u1",
          createdAt: new Date(Date.now() - i * 60_000).toISOString(),
          editedAt: null,
          content: `deploy incident update ${i}`,
          contentUnavailable: false,
          replyToId: null,
          rawJson: "{}",
        },
        [],
      );
    }

    const analyzer = new Analyzer(db, new OllamaClient("http://127.0.0.1:11434"), "test-model");
    const result = await analyzer.answerFromSearchEvidence({
      prompt: "deploy incident",
      scope: "channel",
      channelId: "c1",
      windowHours: 24,
    });

    expect(result.aiUsed).toBe(false);
    expect(result.text).toContain("Answer (grounded in local evidence)");
    expect(result.text).toContain("Citations");
    expect(result.text).toContain("https://discord.com/channels/g1/c1/q1");

    db.close();
  });
});
