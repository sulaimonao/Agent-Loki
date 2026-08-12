import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, test } from "vitest";
import {
  checkpointPathFor,
  getInitialBeforeCursor,
  loadCheckpoint,
  saveCheckpoint,
  type ChannelCheckpoint,
} from "../src/discord/backfill";

describe("backfill checkpoints", () => {
  test("saves and loads checkpoint for resume cursor", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-checkpoint-"));

    const checkpoint: ChannelCheckpoint = {
      channelId: "123",
      beforeMessageId: "900",
      lastMessageId: "999",
      fetchedCount: 100,
      completed: false,
      lastRunAt: new Date().toISOString(),
    };

    saveCheckpoint(tempDir, checkpoint);
    const filePath = checkpointPathFor(tempDir, checkpoint.channelId);

    expect(fs.existsSync(filePath)).toBe(true);

    const loaded = loadCheckpoint(tempDir, checkpoint.channelId);
    expect(loaded?.channelId).toBe(checkpoint.channelId);
    expect(getInitialBeforeCursor(loaded)).toBe("900");
  });
});
