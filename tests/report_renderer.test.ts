import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, test } from "vitest";
import { renderBudgetedReport } from "../src/discord/ui/report";

describe("report renderer", () => {
  test("returns inline content when under budget", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-report-inline-"));
    const payload = renderBudgetedReport(tempDir, "short", "hello world");

    expect(typeof payload.content).toBe("string");
    expect(payload.files).toBeUndefined();
  });

  test("writes markdown attachment when over budget", () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-report-file-"));
    const longText = "x".repeat(2500);
    const payload = renderBudgetedReport(tempDir, "long", longText);

    expect(typeof payload.content).toBe("string");
    expect(Array.isArray(payload.files)).toBe(true);
    expect(payload.files?.length).toBe(1);

    const exportsDir = path.join(tempDir, "exports");
    const files = fs.readdirSync(exportsDir).filter((file) => file.endsWith(".md"));
    expect(files.length).toBe(1);
  });
});
