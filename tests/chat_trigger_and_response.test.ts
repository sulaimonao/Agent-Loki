import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, test, vi } from "vitest";
import { type Message } from "discord.js";
import {
  CHAT_COOLDOWN_MS,
  detectChatTrigger,
  handleConversationalMessage,
} from "../src/discord/chat";
import { LokiDb } from "../src/storage/db";
import { NdjsonLogger } from "../src/storage/ndjson";

const buildMessage = (input: {
  id?: string;
  channelId: string;
  content: string;
  mentionsBot?: boolean;
  botUserId?: string;
  authorId?: string;
  authorUsername?: string;
  guildChannelsFetch?: (channelId: string) => Promise<unknown>;
  startThread?: (options: { name: string; autoArchiveDuration: number }) => Promise<unknown>;
  isThread?: boolean;
  replyFn?: (payload: unknown) => Promise<unknown>;
}) => {
  const botUserId = input.botUserId ?? "bot1";
  const reply = input.replyFn ? vi.fn(input.replyFn) : vi.fn(async () => undefined);
  const hasPermission = vi.fn(() => true);
  const guildChannelsFetch = input.guildChannelsFetch ?? vi.fn(async () => null);

  const message = {
    id: input.id ?? "m-trigger-runtime",
    inGuild: () => true,
    author: {
      id: input.authorId ?? "u1",
      username: input.authorUsername ?? "alice",
      bot: false,
    },
    client: { user: { id: botUserId } },
    guildId: "g1",
    guild: { channels: { fetch: guildChannelsFetch } },
    channelId: input.channelId,
    content: input.content,
    mentions: { users: { has: (id: string) => Boolean(input.mentionsBot && id === botUserId) } },
    channel: { permissionsFor: () => ({ has: hasPermission }), isThread: () => Boolean(input.isThread) },
    startThread: input.startThread,
    reply,
  } as unknown as Message;

  return { message, reply, guildChannelsFetch };
};

const buildContext = (db: LokiDb, dataDir: string) => ({
  db,
  logger: new NdjsonLogger(path.join(dataDir, "logs")),
  dataDir,
  defaultModel: "test-model",
});

describe("chat trigger parsing", () => {
  test("parses mention and prefix triggers", () => {
    const mention = detectChatTrigger({
      content: "<@12345> summarize what changed",
      botUserId: "12345",
      mentionsBot: true,
      channelEnabled: false,
    });

    expect(mention).toEqual({
      trigger: "mention",
      prompt: "summarize what changed",
    });

    const prefix = detectChatTrigger({
      content: "loki: summarize what changed",
      botUserId: "12345",
      mentionsBot: false,
      channelEnabled: false,
    });

    expect(prefix).toEqual({
      trigger: "prefix",
      prompt: "summarize what changed",
    });
  });
});

describe("chat response rendering", () => {
  test("hello returns a conversational greeting without report text or attachment", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-chat-response-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c-greet", guildId: "g1", name: "ops", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });

    const { message, reply } = buildMessage({
      channelId: "c-greet",
      content: "loki: hello",
    });

    await handleConversationalMessage(
      message,
      buildContext(db, tempDir),
      "bot1",
    );

    expect(reply).toHaveBeenCalledTimes(1);
    const payload = reply.mock.calls[0]?.[0] as {
      content?: string;
      files?: unknown[];
    };

    expect(payload.content ?? "").toContain("Hey. I am here.");
    expect(payload.content ?? "").not.toContain("Here is what I found");
    expect(payload.content ?? "").not.toContain("# Loki Report");
    expect(payload.files?.length ?? 0).toBe(0);
    db.close();
  });

  test("task response excludes bot-authored messages from evidence", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-chat-bot-filter-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c-bot", guildId: "g1", name: "ops", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });
    db.upsertUser({ id: "loki", username: "agent-loki", bot: true });

    const now = Date.now();
    db.upsertMessage(
      {
        id: "mh1",
        guildId: "g1",
        channelId: "c-bot",
        authorId: "u1",
        createdAt: new Date(now - 60_000).toISOString(),
        content: "deploy status: outage still active in production",
        contentUnavailable: false,
        rawJson: "{}",
      },
      [],
    );
    db.upsertMessage(
      {
        id: "mb1",
        guildId: "g1",
        channelId: "c-bot",
        authorId: "loki",
        createdAt: new Date(now).toISOString(),
        content: "deploy status: auto-generated Loki summary",
        contentUnavailable: false,
        rawJson: "{}",
      },
      [],
    );

    const { message, reply } = buildMessage({
      channelId: "c-bot",
      content: "loki: what is the deploy status?",
    });

    await handleConversationalMessage(message, buildContext(db, tempDir), "bot1");

    expect(reply).toHaveBeenCalledTimes(1);
    const payload = reply.mock.calls[0]?.[0] as { content?: string };
    const content = payload.content ?? "";
    expect(content).toContain("Sources");
    expect(content).toContain("https://discord.com/channels/g1/c-bot/mh1");
    expect(content).not.toContain("https://discord.com/channels/g1/c-bot/mb1");
    db.close();
  });

  test("task response excludes /loki commands and Loki reports from evidence", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-chat-command-filter-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c-slash", guildId: "g1", name: "ops", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });

    const now = Date.now();
    db.upsertMessage(
      {
        id: "mreal",
        guildId: "g1",
        channelId: "c-slash",
        authorId: "u1",
        createdAt: new Date(now).toISOString(),
        content: "deploy status: rollback started after canary failure",
        contentUnavailable: false,
        rawJson: "{}",
      },
      [],
    );
    db.upsertMessage(
      {
        id: "mslash",
        guildId: "g1",
        channelId: "c-slash",
        authorId: "u1",
        createdAt: new Date(now - 60_000).toISOString(),
        content: "/loki request prompt: deploy status",
        contentUnavailable: false,
        rawJson: "{}",
      },
      [],
    );
    db.upsertMessage(
      {
        id: "mreport",
        guildId: "g1",
        channelId: "c-slash",
        authorId: "u1",
        createdAt: new Date(now - 120_000).toISOString(),
        content: "# Loki Report\n\nAnswer\n- deploy summary",
        contentUnavailable: false,
        rawJson: "{}",
      },
      [],
    );

    const { message, reply } = buildMessage({
      channelId: "c-slash",
      content: "loki: what happened with deploy status?",
    });

    await handleConversationalMessage(message, buildContext(db, tempDir), "bot1");

    const payload = reply.mock.calls[0]?.[0] as { content?: string };
    const content = payload.content ?? "";
    expect(content).toContain("https://discord.com/channels/g1/c-slash/mreal");
    expect(content).not.toContain("https://discord.com/channels/g1/c-slash/mslash");
    expect(content).not.toContain("https://discord.com/channels/g1/c-slash/mreport");
    db.close();
  });

  test("task response excludes the triggering message from chat sources", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-chat-trigger-filter-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c-self", guildId: "g1", name: "ops", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });

    const now = Date.now();
    db.upsertMessage(
      {
        id: "m-signal",
        guildId: "g1",
        channelId: "c-self",
        authorId: "u1",
        createdAt: new Date(now - 60_000).toISOString(),
        content: "deploy status: rollback complete and stable",
        contentUnavailable: false,
        rawJson: "{}",
      },
      [],
    );
    db.upsertMessage(
      {
        id: "m-trigger",
        guildId: "g1",
        channelId: "c-self",
        authorId: "u1",
        createdAt: new Date(now).toISOString(),
        content: "loki: what happened with deploy status?",
        contentUnavailable: false,
        rawJson: "{}",
      },
      [],
    );

    const { message, reply } = buildMessage({
      id: "m-trigger",
      channelId: "c-self",
      content: "loki: what happened with deploy status?",
    });

    await handleConversationalMessage(message, buildContext(db, tempDir), "bot1");

    const payload = reply.mock.calls[0]?.[0] as { content?: string };
    const content = payload.content ?? "";
    expect(content).toContain("https://discord.com/channels/g1/c-self/m-signal");
    expect(content).not.toContain("https://discord.com/channels/g1/c-self/m-trigger");

    db.close();
  });

  test("task question is answer-first and includes source jump links", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-chat-task-answer-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c-task", guildId: "g1", name: "ops", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });

    db.upsertMessage(
      {
        id: "mt1",
        guildId: "g1",
        channelId: "c-task",
        authorId: "u1",
        createdAt: new Date(Date.now() - 60_000).toISOString(),
        content: "deploy incident update: rollback complete and monitoring stable",
        contentUnavailable: false,
        rawJson: "{}",
      },
      [],
    );

    const { message, reply } = buildMessage({
      channelId: "c-task",
      content: "<@bot1> summarize deploy incident",
      mentionsBot: true,
    });

    await handleConversationalMessage(message, buildContext(db, tempDir), "bot1");

    const payload = reply.mock.calls[0]?.[0] as { content?: string; files?: unknown[] };
    const content = payload.content ?? "";
    expect(content.startsWith("Answer\n")).toBe(false);
    expect(content).toContain("\nSources\n");
    expect(content).toContain("https://discord.com/channels/g1/c-task/mt1");
    expect(content).not.toContain("Here is what I found");
    expect(payload.files?.length ?? 0).toBe(0);

    db.close();
  });

  test("routes task replies into a per-user thread when thread mode is auto", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-chat-thread-auto-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c-thread", guildId: "g1", name: "ops", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });
    db.upsertUser({ id: "u2", username: "bob", bot: false });
    db.setChatThreadMode("g1", "auto");

    db.upsertMessage(
      {
        id: "m1",
        guildId: "g1",
        channelId: "c-thread",
        authorId: "u2",
        createdAt: new Date(Date.now() - 60_000).toISOString(),
        content: "deploy incident summary from team",
        contentUnavailable: false,
        rawJson: "{}",
      },
      [],
    );

    const threadSend = vi.fn(async () => undefined);
    const thread = {
      id: "t1",
      send: threadSend,
      archived: false,
      isThread: () => true,
    };
    const startThread = vi.fn(async () => thread);
    const nowSpy = vi.spyOn(Date, "now");
    nowSpy.mockReturnValue(1_000_000);

    const { message, reply } = buildMessage({
      channelId: "c-thread",
      content: "loki: summarize deploy incident",
      startThread,
    });

    await handleConversationalMessage(message, buildContext(db, tempDir), "bot1");

    expect(startThread).toHaveBeenCalledTimes(1);
    expect(reply).toHaveBeenCalledTimes(1);
    expect((reply.mock.calls[0]?.[0] as { content?: string }).content ?? "").toContain("<#t1>");
    expect(threadSend).toHaveBeenCalledTimes(1);
    expect((threadSend.mock.calls[0]?.[0] as { content?: string }).content ?? "").toContain("Sources");

    const route = db.getChatThreadRoute("g1", "c-thread", "u1");
    expect(route?.threadId).toBe("t1");

    nowSpy.mockReturnValue(1_000_000 + CHAT_COOLDOWN_MS + 10);
    const secondReply = vi.fn(async () => undefined);
    const { message: secondMessage, guildChannelsFetch } = buildMessage({
      channelId: "c-thread",
      content: "loki: summarize deploy incident again",
      guildChannelsFetch: vi.fn(async () => thread),
      replyFn: secondReply,
    });

    await handleConversationalMessage(secondMessage, buildContext(db, tempDir), "bot1");

    expect(guildChannelsFetch).toHaveBeenCalledTimes(1);
    expect(secondReply).toHaveBeenCalledTimes(0);
    expect(threadSend).toHaveBeenCalledTimes(2);

    nowSpy.mockRestore();
    db.close();
  });

  test("enabled channel trigger routes full answer to thread and keeps parent as pointer-only", async () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-chat-channel-thread-only-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    db.upsertGuild({ id: "g1", name: "Guild One" });
    db.upsertChannel({ id: "c-channel-thread", guildId: "g1", name: "ops", type: "GuildText" });
    db.upsertUser({ id: "u1", username: "alice", bot: false });
    db.upsertUser({ id: "u2", username: "bob", bot: false });
    db.setChatThreadMode("g1", "auto");
    db.enableChatChannel("g1", "c-channel-thread");

    db.upsertMessage(
      {
        id: "m-evidence",
        guildId: "g1",
        channelId: "c-channel-thread",
        authorId: "u2",
        createdAt: new Date(Date.now() - 60_000).toISOString(),
        content: "deploy incident summary from team with rollback timeline",
        contentUnavailable: false,
        rawJson: "{}",
      },
      [],
    );

    const threadSend = vi.fn(async () => undefined);
    const thread = {
      id: "t-channel",
      send: threadSend,
      archived: false,
      isThread: () => true,
    };
    const startThread = vi.fn(async () => thread);

    const { message, reply } = buildMessage({
      channelId: "c-channel-thread",
      content: "summarize deploy incident",
      startThread,
    });

    await handleConversationalMessage(message, buildContext(db, tempDir), "bot1");

    expect(startThread).toHaveBeenCalledTimes(1);
    expect(reply).toHaveBeenCalledTimes(1);
    const parentPayload = reply.mock.calls[0]?.[0] as { content?: string };
    expect(parentPayload.content ?? "").toContain("<#t-channel>");
    expect(parentPayload.content ?? "").not.toContain("Sources");

    expect(threadSend).toHaveBeenCalledTimes(1);
    const threadPayload = threadSend.mock.calls[0]?.[0] as { content?: string };
    expect(threadPayload.content ?? "").toContain("Sources");
    expect(threadPayload.content ?? "").toContain("https://discord.com/channels/g1/c-channel-thread/m-evidence");

    db.close();
  });
});
