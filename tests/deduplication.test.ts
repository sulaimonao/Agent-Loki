import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, test } from "vitest";
import { LokiDb } from "../src/storage/db";

describe("deduplication invariants", () => {
  test("message upsert is idempotent by message id", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-dedup-message-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild" });
    db.upsertChannel({ id: "c1", guildId: "g1", name: "general", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });

    const createdAt = new Date().toISOString();
    db.upsertMessage(
      {
        id: "m1",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt,
        editedAt: null,
        content: "first content",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{\"v\":1}",
      },
      [],
    );

    db.upsertMessage(
      {
        id: "m1",
        guildId: "g1",
        channelId: "c1",
        authorId: "u1",
        createdAt,
        editedAt: new Date().toISOString(),
        content: "updated content",
        contentUnavailable: false,
        replyToId: null,
        rawJson: "{\"v\":2}",
      },
      [],
    );

    expect(db.getDbStats().messages).toBe(1);
    expect(db.getMessageById("m1")?.content).toBe("updated content");

    db.close();
  });

  test("attachments without id get deterministic fallback and do not duplicate on rerun", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-dedup-attachment-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild" });
    db.upsertChannel({ id: "c1", guildId: "g1", name: "general", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });

    const baseMessage = {
      id: "m1",
      guildId: "g1",
      channelId: "c1",
      authorId: "u1",
      createdAt: new Date().toISOString(),
      editedAt: null,
      content: "message with attachment",
      contentUnavailable: false,
      replyToId: null,
      rawJson: "{}",
    } as const;

    const attachment = {
      url: "https://cdn.example.com/file.txt",
      filename: "file.txt",
      contentType: "text/plain",
      size: 123,
    };

    db.upsertMessage(baseMessage, [attachment]);
    const first = db.getAttachmentsForMessageIds(["m1"]);
    expect(first).toHaveLength(1);
    const firstId = first[0]?.id;

    db.upsertMessage(baseMessage, [attachment]);
    const second = db.getAttachmentsForMessageIds(["m1"]);
    expect(second).toHaveLength(1);
    expect(second[0]?.id).toBe(firstId);

    db.close();
  });

  test("re-index with changed attachment metadata replaces attachment row instead of duplicating", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-dedup-attachment-change-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild" });
    db.upsertChannel({ id: "c1", guildId: "g1", name: "general", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });

    const baseMessage = {
      id: "m1",
      guildId: "g1",
      channelId: "c1",
      authorId: "u1",
      createdAt: new Date().toISOString(),
      editedAt: null,
      content: "message with attachment",
      contentUnavailable: false,
      replyToId: null,
      rawJson: "{}",
    } as const;

    db.upsertMessage(baseMessage, [
      {
        url: "https://cdn.example.com/file.txt",
        filename: "old.txt",
        contentType: "text/plain",
        size: 100,
      },
    ]);

    db.upsertMessage(baseMessage, [
      {
        url: "https://cdn.example.com/file.txt",
        filename: "new.txt",
        contentType: "text/plain",
        size: 200,
      },
    ]);

    const attachments = db.getAttachmentsForMessageIds(["m1"]);
    expect(attachments).toHaveLength(1);
    expect(attachments[0]?.filename).toBe("new.txt");
    expect(attachments[0]?.size).toBe(200);

    db.close();
  });
});
