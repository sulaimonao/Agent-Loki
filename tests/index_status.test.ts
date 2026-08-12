import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, test } from "vitest";
import { LokiDb } from "../src/storage/db";

describe("index status persistence", () => {
  test("tracks daily index metadata fields in internal_meta", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-index-status-"));
    const db = new LokiDb(path.join(tempDir, "test.db"));
    db.init();

    expect(db.getIndexStatus()).toEqual({
      lastIndexRunAt: undefined,
      lastIndexOkAt: undefined,
      lastIndexError: undefined,
      indexVersion: undefined,
    });

    db.markIndexRunStarted("2026-02-10T08:00:00.000Z", "v1");
    expect(db.getIndexStatus()).toEqual({
      lastIndexRunAt: "2026-02-10T08:00:00.000Z",
      lastIndexOkAt: undefined,
      lastIndexError: undefined,
      indexVersion: "v1",
    });

    db.markIndexRunError("boom", "2026-02-10T08:01:00.000Z", "v1");
    expect(db.getIndexStatus()).toEqual({
      lastIndexRunAt: "2026-02-10T08:01:00.000Z",
      lastIndexOkAt: undefined,
      lastIndexError: "boom",
      indexVersion: "v1",
    });

    db.markIndexRunSuccess("2026-02-10T08:02:00.000Z", "v2");
    expect(db.getIndexStatus()).toEqual({
      lastIndexRunAt: "2026-02-10T08:02:00.000Z",
      lastIndexOkAt: "2026-02-10T08:02:00.000Z",
      lastIndexError: undefined,
      indexVersion: "v2",
    });

    db.close();
  });
});
