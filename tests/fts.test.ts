import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, test } from "vitest";
import { LokiDb } from "../src/storage/db";

describe("fts triggers", () => {
  test("fts updates on message upsert", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-fts-"));
    const dbPath = path.join(tempDir, "test.db");

    const db = new LokiDb(dbPath);
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild" });
    db.upsertChannel({ id: "c1", guildId: "g1", name: "general", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });

    db.upsertMessage(
      {
        id: "m1",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt: new Date().toISOString(),
        editedAt: null,
        content: "alpha beta",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );

    const initial = db.searchMessages({ query: "alpha", limit: 10 });
    expect(initial.length).toBe(1);

    db.upsertMessage(
      {
        id: "m1",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt: new Date().toISOString(),
        editedAt: null,
        content: "gamma delta",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );

    const oldSearch = db.searchMessages({ query: "alpha", limit: 10 });
    const newSearch = db.searchMessages({ query: "gamma", limit: 10 });

    expect(oldSearch.length).toBe(0);
    expect(newSearch.length).toBe(1);
    expect(db.getDbStats().ftsRows).toBe(1);

    db.close();
  });

  test("search excludes bot-authored, /loki, and # Loki Report messages", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-fts-filter-"));
    const dbPath = path.join(tempDir, "test.db");
    const db = new LokiDb(dbPath);
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild" });
    db.upsertChannel({ id: "c1", guildId: "g1", name: "general", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });
    db.upsertUser({ id: "bot1", username: "agent-loki", bot: true });

    const now = Date.now();
    db.upsertMessage(
      {
        id: "m1",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt: new Date(now).toISOString(),
        editedAt: null,
        content: "alpha release status is stable",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );
    db.upsertMessage(
      {
        id: "m2",
        guildId: "g1",
        channelId: "c1",
        authorId: "bot1",
        createdAt: new Date(now - 60_000).toISOString(),
        editedAt: null,
        content: "alpha automated Loki output",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );
    db.upsertMessage(
      {
        id: "m3",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt: new Date(now - 120_000).toISOString(),
        editedAt: null,
        content: "/loki request prompt: alpha",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );
    db.upsertMessage(
      {
        id: "m4",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt: new Date(now - 180_000).toISOString(),
        editedAt: null,
        content: "# Loki Report\n\nalpha summary",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{}",
      },
      [],
    );

    const rows = db.searchMessages({ query: "alpha", limit: 10 });
    expect(rows.map((row) => row.id)).toEqual(["m1"]);

    db.close();
  });
});
