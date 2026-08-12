import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, test } from "vitest";
import { runConversationalRequest } from "../src/discord/request";
import { LokiDb } from "../src/storage/db";

const createDb = (prefix: string): LokiDb => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  const db = new LokiDb(path.join(tempDir, "test.db"));
  db.init();
  db.upsertGuild({ id: "g1", name: "Guild One" });
  db.upsertChannel({ id: "c1", guildId: "g1", name: "ops", type: "GuildText" });
  db.upsertUser({ id: "u1", username: "alice", bot: false });
  db.upsertUser({ id: "u2", username: "bob", bot: false });
  return db;
};

describe("request workflow", () => {
  test("defaults to recent-by-count and widens from 300 to 1000 when prompt matches require it", async () => {
    const db = createDb("loki-request-count-wide-");

    const now = Date.now();
    for (let i = 0; i < 350; i += 1) {
      const id = `m${i}`;
      const isTarget = i === 320;
      db.upsertMessage(
        {
          id,
          guildId: "g1",
          channelId: "c1",
          authorId: i % 2 === 0 ? "u1" : "u2",
          createdAt: new Date(now - i * 60_000).toISOString(),
          editedAt: null,
          content: isTarget
            ? "deploy incident update with clear evidence"
            : `general chatter line ${i}`,
          contentUnavailable: false,
          replyToId: null,
          rawJson: "{}",
        },
        [],
      );
    }

    const result = await runConversationalRequest(
      {
        db,
        defaultModel: "test-model",
      },
      {
        prompt: "deploy incident evidence",
        scope: "here",
        guildId: "g1",
        channelId: "c1",
        ai: "off",
      },
    );

    expect(result.text).toContain("Evidence strategy: recent-by-count (latest 1000 readable messages).");
    expect(result.text).toContain("https://discord.com/channels/g1/c1/m320");
    expect(result.text).toContain("Sources");

    db.close();
  });

  test("supports explicit recent-count limit override for intentional large scans", async () => {
    const db = createDb("loki-request-count-explicit-limit-");

    const result = await runConversationalRequest(
      {
        db,
        defaultModel: "test-model",
      },
      {
        prompt: "status check",
        scope: "here",
        guildId: "g1",
        channelId: "c1",
        recentReadableLimit: 20000,
        ai: "off",
      },
    );

    expect(result.text).toContain("Evidence strategy: recent-by-count (latest 20000 readable messages).");
    expect(result.text).toContain("- latest 20000 readable: rows=0");

    db.close();
  });

  test("uses time-window retrieval when explicit window is requested", async () => {
    const db = createDb("loki-request-time-explicit-");

    const thirtyHoursAgo = Date.now() - 30 * 60 * 60 * 1000;
    db.upsertMessage(
      {
        id: "m1",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt: new Date(thirtyHoursAgo).toISOString(),
        editedAt: null,
        content: "deploy incident update in window",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );

    const result = await runConversationalRequest(
      {
        db,
        defaultModel: "test-model",
      },
      {
        prompt: "deploy incident",
        scope: "here",
        guildId: "g1",
        channelId: "c1",
        windowHours: 48,
        ai: "off",
      },
    );

    expect(result.text).toContain("Evidence strategy: time-window (last 48h).");
    expect(result.text).toContain("https://discord.com/channels/g1/c1/m1");

    db.close();
  });

  test("uses time-window retrieval when prompt contains time language", async () => {
    const db = createDb("loki-request-time-language-");

    db.upsertMessage(
      {
        id: "m1",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt: new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString(),
        editedAt: null,
        content: "deploy status today is stable",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );

    const result = await runConversationalRequest(
      {
        db,
        defaultModel: "test-model",
      },
      {
        prompt: "what happened today with deploy status?",
        scope: "here",
        guildId: "g1",
        channelId: "c1",
        ai: "off",
      },
    );

    expect(result.text).toContain("Evidence strategy: time-window (last 24h).");
    expect(result.text).toContain("https://discord.com/channels/g1/c1/m1");

    db.close();
  });

  test("filters mention/emoji-only and very short noise from evidence", async () => {
    const db = createDb("loki-request-noise-filter-");

    const now = Date.now();
    db.upsertMessage(
      {
        id: "m-noise-mention",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt: new Date(now - 1_000).toISOString(),
        editedAt: null,
        content: "<@123456789012345678> <:shipit:123456789012345678> 🚀",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );
    db.upsertMessage(
      {
        id: "m-noise-short",
        guildId: "g1",
        channelId: "c1",
        authorId: "u2",
        createdAt: new Date(now - 2_000).toISOString(),
        editedAt: null,
        content: "ok",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );
    db.upsertMessage(
      {
        id: "m-signal",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt: new Date(now - 3_000).toISOString(),
        editedAt: null,
        content: "deploy status: rollback complete and monitoring stable",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );

    const result = await runConversationalRequest(
      {
        db,
        defaultModel: "test-model",
      },
      {
        prompt: "deploy status summary",
        scope: "here",
        guildId: "g1",
        channelId: "c1",
        ai: "off",
      },
    );

    expect(result.text).toContain("https://discord.com/channels/g1/c1/m-signal");
    expect(result.text).not.toContain("https://discord.com/channels/g1/c1/m-noise-mention");
    expect(result.text).not.toContain("https://discord.com/channels/g1/c1/m-noise-short");

    db.close();
  });

  test("chat sources exclude greeting/noise rows, excluded ids, and cap at five lines", async () => {
    const db = createDb("loki-request-chat-source-hygiene-");

    const now = Date.now();
    db.upsertMessage(
      {
        id: "m-trigger",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt: new Date(now).toISOString(),
        editedAt: null,
        content: "what happened with deploy status?",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );
    db.upsertMessage(
      {
        id: "m-greeting",
        guildId: "g1",
        channelId: "c1",
        authorId: "u2",
        createdAt: new Date(now - 1_000).toISOString(),
        editedAt: null,
        content: "hello",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );
    db.upsertMessage(
      {
        id: "m-mention-only",
        guildId: "g1",
        channelId: "c1",
        authorId: "u2",
        createdAt: new Date(now - 2_000).toISOString(),
        editedAt: null,
        content: "<@123456789012345678> <:shipit:123456789012345678> 🚀",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );
    db.upsertMessage(
      {
        id: "m-short-junk",
        guildId: "g1",
        channelId: "c1",
        authorId: "u2",
        createdAt: new Date(now - 3_000).toISOString(),
        editedAt: null,
        content: "ok",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );

    for (let i = 0; i < 6; i += 1) {
      db.upsertMessage(
        {
          id: `m-signal-${i}`,
          guildId: "g1",
          channelId: "c1",
          authorId: i % 2 === 0 ? "u1" : "u2",
          createdAt: new Date(now - 5_000 - i * 1_000).toISOString(),
          editedAt: null,
          content: `deploy status update ${i} includes concrete rollback details`,
          contentUnavailable: false,
          replyToId: null,
          rawJson: "{}",
        },
        [],
      );
    }

    const result = await runConversationalRequest(
      {
        db,
        defaultModel: "test-model",
      },
      {
        prompt: "what happened with deploy status?",
        scope: "here",
        guildId: "g1",
        channelId: "c1",
        excludeMessageIds: ["m-trigger"],
        ai: "off",
        responseStyle: "chat",
      },
    );

    expect(result.text).not.toContain("https://discord.com/channels/g1/c1/m-trigger");
    expect(result.text).not.toContain("https://discord.com/channels/g1/c1/m-greeting");
    expect(result.text).not.toContain("https://discord.com/channels/g1/c1/m-mention-only");
    expect(result.text).not.toContain("https://discord.com/channels/g1/c1/m-short-junk");
    expect((result.text.match(/https:\/\/discord\.com\/channels\/g1\/c1\/m-signal-/g) ?? []).length).toBe(5);
    expect(result.text).not.toContain("https://discord.com/channels/g1/c1/m-signal-5");

    db.close();
  });

  test("returns no-activity guidance when no readable evidence exists", async () => {
    const db = createDb("loki-request-empty-");

    const result = await runConversationalRequest(
      {
        db,
        defaultModel: "test-model",
      },
      {
        prompt: "status check",
        scope: "here",
        guildId: "g1",
        channelId: "c1",
        ai: "off",
      },
    );

    expect(result.text).toContain("No activity found for this request.");
    expect(result.text).toContain("Evidence strategy: recent-by-count (latest 5000 readable messages).");
    expect(result.text).toContain("- latest 300 readable: rows=0");
    expect(result.text).toContain("- latest 1000 readable: rows=0");
    expect(result.text).toContain("- latest 5000 readable: rows=0");

    db.close();
  });
});
