import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, test } from "vitest";
import {
  resolveIncrementalSinceIso,
  saveCheckpoint,
  snowflakeIdToTimestampMs,
  type ChannelCheckpoint,
} from "../src/discord/backfill";
import { LokiDb } from "../src/storage/db";

const DISCORD_EPOCH_MS = 1420070400000;
const INCREMENTAL_OVERLAP_MS = 2 * 60 * 1000;

const makeSnowflake = (timestampMs: number): string => {
  const part = BigInt(Math.max(0, timestampMs - DISCORD_EPOCH_MS));
  return ((part << 22n) + 1n).toString();
};

describe("incremental checkpoint cursor", () => {
  test("derives incremental since from checkpoint last message id", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-incremental-since-checkpoint-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    const timestampMs = Date.parse("2026-02-10T10:00:00.000Z");
    const checkpoint: ChannelCheckpoint = {
      channelId: "c1",
      beforeMessageId: undefined,
      lastMessageId: makeSnowflake(timestampMs),
      fetchedCount: 123,
      completed: false,
      lastRunAt: "2026-02-10T10:01:00.000Z",
    };
    saveCheckpoint(tempDir, checkpoint);

    const sinceIso = resolveIncrementalSinceIso({ db, checkpointDir: tempDir }, "c1");
    expect(sinceIso).toBe(new Date(timestampMs - INCREMENTAL_OVERLAP_MS).toISOString());

    db.close();
  });

  test("falls back to channel_access last_backfill_at when checkpoint is missing", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-incremental-since-last-backfill-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    const lastBackfillAt = "2026-02-10T12:00:00.000Z";
    db.recordChannelAccess({
      channelId: "c1",
      canView: true,
      canReadHistory: true,
      hasMessageContent: true,
      lastBackfillAt,
      lastError: null,
    });

    const sinceIso = resolveIncrementalSinceIso({ db, checkpointDir: tempDir }, "c1");
    expect(sinceIso).toBe(
      new Date(Date.parse(lastBackfillAt) - INCREMENTAL_OVERLAP_MS).toISOString(),
    );

    db.close();
  });

  test("snowflake timestamp conversion returns undefined for invalid ids", () => {
    expect(snowflakeIdToTimestampMs("not-a-snowflake")).toBeUndefined();
  });
});
