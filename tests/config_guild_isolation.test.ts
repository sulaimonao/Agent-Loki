import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import { isGuildAllowed, loadConfig } from "../src/config";

const ORIGINAL_ENV = { ...process.env };

const resetEnv = (): void => {
  for (const key of Object.keys(process.env)) {
    if (!(key in ORIGINAL_ENV)) {
      delete process.env[key];
    }
  }
  for (const [key, value] of Object.entries(ORIGINAL_ENV)) {
    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
};

describe("config guild isolation", () => {
  afterEach(() => {
    resetEnv();
  });

  test("parses guild allowlist and enforces allow checks", () => {
    resetEnv();
    process.env.GUILD_ALLOWLIST = "g1, g2, g1";
    process.env.DB_MODE = "shared";

    const config = loadConfig();
    expect(config.guildAllowlist).toEqual(["g1", "g2"]);
    expect(isGuildAllowed(config, "g1")).toBe(true);
    expect(isGuildAllowed(config, "g3")).toBe(false);
  });

  test("fails closed for direct messages and an empty allowlist", () => {
    resetEnv();
    delete process.env.GUILD_ALLOWLIST;
    process.env.DB_MODE = "shared";

    const config = loadConfig();
    expect(isGuildAllowed(config, undefined)).toBe(false);
    expect(isGuildAllowed(config, "g1")).toBe(false);
  });

  test("per_guild mode resolves guild-specific storage paths", () => {
    resetEnv();
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "loki-config-per-guild-"));
    process.env.DATA_DIR = tempDir;
    process.env.DB_MODE = "per_guild";
    process.env.DISCORD_GUILD_ID = "g99";
    delete process.env.DB_PATH;
    delete process.env.CHECKPOINT_DIR;
    delete process.env.LOG_DIR;
    delete process.env.GUILD_ALLOWLIST;

    const config = loadConfig();
    expect(config.dbMode).toBe("per_guild");
    expect(config.guildAllowlist).toEqual(["g99"]);
    expect(config.dbPath).toBe(path.join(tempDir, "guilds", "g99", "loki.db"));
    expect(config.checkpointDir).toBe(path.join(tempDir, "checkpoints", "g99"));
    expect(config.logDir).toBe(path.join(tempDir, "logs", "g99"));
  });
});
