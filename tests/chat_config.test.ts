import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, test } from "vitest";
import { LokiDb } from "../src/storage/db";

describe("chat config persistence", () => {
  test("persists chat channel enable/disable and mode", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-chat-config-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    expect(db.isChatChannelEnabled("g1", "c1")).toBe(false);
    expect(db.listChatEnabledChannels("g1")).toEqual([]);

    db.enableChatChannel("g1", "c1");
    db.enableChatChannel("g1", "c2");

    expect(db.isChatChannelEnabled("g1", "c1")).toBe(true);
    expect(db.listChatEnabledChannels("g1")).toEqual(["c1", "c2"]);

    db.disableChatChannel("g1", "c1");

    expect(db.isChatChannelEnabled("g1", "c1")).toBe(false);
    expect(db.listChatEnabledChannels("g1")).toEqual(["c2"]);

    expect(db.getChatMode("g1")).toBeUndefined();
    db.setChatMode("g1", "prefix");
    expect(db.getChatMode("g1")).toBe("prefix");

    expect(db.getChatThreadMode("g1")).toBe("auto");
    db.setChatThreadMode("g1", "ask");
    expect(db.getChatThreadMode("g1")).toBe("ask");

    db.setChatThreadRoute("g1", "c2", "u1", "t1");
    expect(db.getChatThreadRoute("g1", "c2", "u1")?.threadId).toBe("t1");
    expect(db.countChatThreadRoutes("g1")).toBe(1);

    db.close();
  });
});
