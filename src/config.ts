import dotenv from "dotenv";
import fs from "node:fs";
import path from "node:path";

dotenv.config();

const toBoolean = (value: string | undefined, fallback: boolean): boolean => {
  if (value === undefined) {
    return fallback;
  }
  const normalized = value.trim().toLowerCase();
  return normalized === "1" || normalized === "true" || normalized === "yes";
};

export interface LokiConfig {
  discordToken: string;
  discordClientId: string;
  discordGuildId?: string;
  guildAllowlist: string[];
  dbMode: "shared" | "per_guild";
  dataDir: string;
  dbPath: string;
  logDir: string;
  checkpointDir: string;
  policyPath: string;
  enableEnforcement: boolean;
  ollamaUrl: string;
  ollamaModel: string;
}

const parseCsvList = (value: string | undefined): string[] => {
  if (!value) {
    return [];
  }

  const unique = new Set(
    value
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean),
  );
  return [...unique];
};

const resolveDbMode = (value: string | undefined): "shared" | "per_guild" => {
  const normalized = (value ?? "shared").trim().toLowerCase();
  if (normalized === "shared" || normalized === "per_guild") {
    return normalized;
  }
  throw new Error(`Unsupported DB_MODE: ${value}. Use 'shared' or 'per_guild'.`);
};

const resolvePerGuildId = (discordGuildId: string | undefined, allowlist: string[]): string => {
  const explicit = process.env.DB_GUILD_ID?.trim();
  if (explicit) {
    return explicit;
  }
  if (discordGuildId) {
    return discordGuildId;
  }
  if (allowlist.length === 1) {
    return allowlist[0] as string;
  }
  throw new Error(
    "DB_MODE=per_guild requires one guild. Set DB_GUILD_ID, DISCORD_GUILD_ID, or a single-entry GUILD_ALLOWLIST.",
  );
};

export const loadConfig = (): LokiConfig => {
  const root = process.cwd();
  const dbMode = resolveDbMode(process.env.DB_MODE);
  const guildAllowlistInput = parseCsvList(process.env.GUILD_ALLOWLIST);
  const perGuildId =
    dbMode === "per_guild"
      ? resolvePerGuildId(process.env.DISCORD_GUILD_ID, guildAllowlistInput)
      : undefined;
  const guildAllowlist =
    dbMode === "per_guild" ? [perGuildId as string] : guildAllowlistInput;

  const dataDir = path.resolve(process.env.DATA_DIR ?? "./data");
  const logDir = path.resolve(
    process.env.LOG_DIR ??
      (dbMode === "per_guild"
        ? path.join(dataDir, "logs", perGuildId as string)
        : path.join(dataDir, "logs")),
  );
  const checkpointDir = path.resolve(
    process.env.CHECKPOINT_DIR ??
      (dbMode === "per_guild"
        ? path.join(dataDir, "checkpoints", perGuildId as string)
        : path.join(dataDir, "checkpoints")),
  );
  const dbPath = path.resolve(
    process.env.DB_PATH ??
      (dbMode === "per_guild"
        ? path.join(dataDir, "guilds", perGuildId as string, "loki.db")
        : path.join(dataDir, "loki.db")),
  );

  return {
    discordToken: process.env.DISCORD_TOKEN ?? "",
    discordClientId: process.env.DISCORD_CLIENT_ID ?? "",
    discordGuildId: process.env.DISCORD_GUILD_ID,
    guildAllowlist,
    dbMode,
    dataDir,
    dbPath,
    logDir,
    checkpointDir,
    policyPath: path.resolve(process.env.POLICY_PATH ?? path.join(root, "config/loki.yaml")),
    enableEnforcement: toBoolean(process.env.ENABLE_ENFORCEMENT, false),
    ollamaUrl: process.env.OLLAMA_URL ?? "http://127.0.0.1:11434",
    ollamaModel: process.env.OLLAMA_MODEL ?? "llama3.1",
  };
};

export const ensureRuntimeDirs = (config: LokiConfig): void => {
  fs.mkdirSync(config.dataDir, { recursive: true });
  fs.mkdirSync(config.logDir, { recursive: true });
  fs.mkdirSync(config.checkpointDir, { recursive: true });
};

export const assertDiscordEnv = (config: LokiConfig): void => {
  if (!config.discordToken) {
    throw new Error("DISCORD_TOKEN is required");
  }
  if (!config.discordClientId) {
    throw new Error("DISCORD_CLIENT_ID is required");
  }
  if (config.guildAllowlist.length === 0) {
    throw new Error(
      "GUILD_ALLOWLIST must contain at least one explicit guild ID; an empty allowlist is denied.",
    );
  }
};

export const isGuildAllowed = (config: LokiConfig, guildId: string | undefined): boolean => {
  if (!guildId) {
    return false;
  }

  if (config.guildAllowlist.length === 0) {
    return false;
  }

  return config.guildAllowlist.includes(guildId);
};
