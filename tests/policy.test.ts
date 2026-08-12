import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, expect, test } from "vitest";
import { loadPolicyFile } from "../src/moderation/policy";

describe("policy", () => {
  test("loads and validates default policy", () => {
    const policy = loadPolicyFile(path.join(process.cwd(), "config/loki.yaml"));
    expect(policy.schemaVersion).toBe(1);
    expect(policy.moderation.spam.repeated_messages_threshold).toBeGreaterThan(1);
  });

  test("rejects invalid policy shape", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-policy-"));
    const badPath = path.join(dir, "bad.yaml");
    fs.writeFileSync(
      badPath,
      [
        "schemaVersion: 2",
        "moderation:",
        "  scam_domains: []",
        "  spam:",
        "    repeated_messages_threshold: 1",
        "    window_seconds: 0",
        "  mass_mentions:",
        "    threshold: 0",
        "  forbidden_phrases: []",
      ].join("\n"),
      "utf8",
    );

    expect(() => loadPolicyFile(badPath)).toThrow();
  });
});
