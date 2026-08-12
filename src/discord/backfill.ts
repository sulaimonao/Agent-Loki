import fs from "node:fs";
import path from "node:path";
import type { Guild, GuildBasedChannel, Message } from "discord.js";
import { discoverCoverage, type BackfillTarget, type CoverageEntry } from "./coverage";
import { persistMessage } from "./ingest";
import { LokiDb } from "../storage/db";
import { NdjsonLogger } from "../storage/ndjson";

export type BackfillScope = "all" | "channel" | "threads";

export interface ChannelCheckpoint {
  channelId: string;
  beforeMessageId?: string;
  lastMessageId?: string;
  fetchedCount: number;
  completed: boolean;
  lastRunAt: string;
}

export interface BackfillDeps {
  db: LokiDb;
  logger: NdjsonLogger;
  checkpointDir: string;
  hasMessageContent: boolean;
}

export interface BackfillOptions {
  scope: BackfillScope;
  channelId?: string;
  since?: string;
  max?: number;
  onProgress?: (update: BackfillProgressUpdate) => Promise<void> | void;
}

export interface BackfillProgressUpdate {
  channelId: string;
  channelName: string;
  kind: "channel" | "thread";
  messagesIngested: number;
  totalIngested: number;
}

export interface BackfillSummary {
  targetsConsidered: number;
  targetsProcessed: number;
  targetsSkipped: number;
  messagesIngested: number;
  skipped: Array<{ channelId: string; reason: string }>;
}

export interface IncrementalBackfillOptions {
  max?: number;
  onProgress?: (update: BackfillProgressUpdate) => Promise<void> | void;
}

const INCREMENTAL_OVERLAP_MS = 2 * 60 * 1000;
const DISCORD_EPOCH_MS = 1420070400000;

const sleep = async (ms: number): Promise<void> => {
  await new Promise((resolve) => setTimeout(resolve, ms));
};

const isMessageFetchable = (
  channel: GuildBasedChannel,
): channel is GuildBasedChannel & {
  messages: {
    fetch: (options: { limit: number; before?: string }) => Promise<Map<string, Message>>;
  };
} => {
  return channel.isTextBased() && "messages" in channel;
};

export const checkpointPathFor = (checkpointDir: string, channelId: string): string => {
  return path.join(checkpointDir, `${channelId}.json`);
};

export const loadCheckpoint = (
  checkpointDir: string,
  channelId: string,
): ChannelCheckpoint | undefined => {
  const filePath = checkpointPathFor(checkpointDir, channelId);
  if (!fs.existsSync(filePath)) {
    return undefined;
  }

  const parsed = JSON.parse(fs.readFileSync(filePath, "utf8")) as ChannelCheckpoint;
  return parsed;
};

export const saveCheckpoint = (
  checkpointDir: string,
  checkpoint: ChannelCheckpoint,
): void => {
  fs.mkdirSync(checkpointDir, { recursive: true });
  const filePath = checkpointPathFor(checkpointDir, checkpoint.channelId);
  fs.writeFileSync(filePath, `${JSON.stringify(checkpoint, null, 2)}\n`, "utf8");
};

export const getInitialBeforeCursor = (checkpoint: ChannelCheckpoint | undefined): string | undefined => {
  return checkpoint?.beforeMessageId;
};

export const snowflakeIdToTimestampMs = (snowflakeId: string): number | undefined => {
  if (!snowflakeId) {
    return undefined;
  }

  try {
    const ms = Number((BigInt(snowflakeId) >> 22n) + BigInt(DISCORD_EPOCH_MS));
    if (!Number.isFinite(ms) || ms <= 0) {
      return undefined;
    }
    return ms;
  } catch {
    return undefined;
  }
};

export const resolveIncrementalSinceIso = (
  deps: Pick<BackfillDeps, "db" | "checkpointDir">,
  channelId: string,
): string | undefined => {
  const checkpoint = loadCheckpoint(deps.checkpointDir, channelId);
  const checkpointMs = checkpoint?.lastMessageId
    ? snowflakeIdToTimestampMs(checkpoint.lastMessageId)
    : undefined;
  if (checkpointMs !== undefined) {
    return new Date(Math.max(0, checkpointMs - INCREMENTAL_OVERLAP_MS)).toISOString();
  }

  const lastBackfillAt = deps.db.getChannelLastBackfillAt(channelId);
  if (!lastBackfillAt) {
    return undefined;
  }

  const parsedMs = Date.parse(lastBackfillAt);
  if (!Number.isFinite(parsedMs)) {
    return undefined;
  }

  return new Date(Math.max(0, parsedMs - INCREMENTAL_OVERLAP_MS)).toISOString();
};

const maxSnowflake = (left: string | undefined, right: string): string => {
  if (!left) {
    return right;
  }

  try {
    return BigInt(left) >= BigInt(right) ? left : right;
  } catch {
    return right;
  }
};

const filterTargets = (
  targets: BackfillTarget[],
  scope: BackfillScope,
  selectedChannelId?: string,
): BackfillTarget[] => {
  if (scope === "channel") {
    if (!selectedChannelId) {
      return [];
    }
    return targets.filter((target) => target.channelId === selectedChannelId);
  }

  if (scope === "threads") {
    return targets.filter((target) => target.kind === "thread");
  }

  return targets;
};

const upsertCoverageToDb = (
  deps: BackfillDeps,
  entries: CoverageEntry[],
): Array<{ channelId: string; reason: string }> => {
  const skipped: Array<{ channelId: string; reason: string }> = [];

  for (const entry of entries) {
    const reason = entry.skippedReason ?? null;
    deps.db.recordChannelAccess({
      channelId: entry.channelId,
      canView: entry.canView,
      canReadHistory: entry.canReadHistory,
      hasMessageContent: deps.hasMessageContent,
      lastError: reason,
      lastBackfillAt: null,
    });

    if (reason) {
      skipped.push({
        channelId: entry.channelId,
        reason,
      });
    }
  }

  return skipped;
};

const fetchPage = async (
  channel: GuildBasedChannel & {
    messages: {
      fetch: (options: { limit: number; before?: string }) => Promise<Map<string, Message>>;
    };
  },
  limit: number,
  before?: string,
): Promise<Message[]> => {
  const maxAttempts = 5;
  let attempt = 0;

  while (attempt < maxAttempts) {
    try {
      const page = await channel.messages.fetch({ limit, before });
      return [...page.values()];
    } catch (error) {
      attempt += 1;
      if (attempt >= maxAttempts) {
        throw error;
      }
      const waitMs = Math.min(30000, 500 * 2 ** attempt);
      await sleep(waitMs);
    }
  }

  return [];
};

interface ProcessTargetsOptions {
  since?: string;
  max?: number;
  onProgress?: (update: BackfillProgressUpdate) => Promise<void> | void;
  sinceResolver?: (target: BackfillTarget) => string | undefined;
}

const processTargets = async (
  guild: Guild,
  deps: BackfillDeps,
  targets: BackfillTarget[],
  options: ProcessTargetsOptions,
): Promise<{
  targetsProcessed: number;
  messagesIngested: number;
  skipped: Array<{ channelId: string; reason: string }>;
}> => {
  let globalIngested = 0;
  let targetsProcessed = 0;
  const skipped: Array<{ channelId: string; reason: string }> = [];

  for (const target of targets) {
    const channel = guild.channels.cache.get(target.channelId);
    if (!channel || !isMessageFetchable(channel)) {
      skipped.push({
        channelId: target.channelId,
        reason: "channel missing or not message-fetchable",
      });
      continue;
    }

    const targetSince = options.sinceResolver?.(target) ?? options.since;
    const sinceMs = targetSince ? Date.parse(targetSince) : NaN;
    const sinceTimestamp = Number.isFinite(sinceMs) ? sinceMs : undefined;

    const existing = loadCheckpoint(deps.checkpointDir, target.channelId);
    if (existing?.completed && !targetSince && !options.max) {
      skipped.push({
        channelId: target.channelId,
        reason: "already completed",
      });
      continue;
    }

    deps.logger.logEvent("backfill.channel.start", {
      channelId: target.channelId,
      channelName: target.channelName,
      kind: target.kind,
      since: targetSince,
      max: options.max,
    });

    let localIngested = 0;
    let before = targetSince ? undefined : getInitialBeforeCursor(existing);
    let stopBecauseSince = false;
    let stopBecauseMax = false;
    let newestSeenAt: string | undefined;
    let newestSeenMessageId = existing?.lastMessageId;

    try {
      while (true) {
        const remaining =
          options.max && options.max > 0 ? Math.max(options.max - localIngested, 0) : undefined;

        if (remaining === 0) {
          stopBecauseMax = true;
          break;
        }

        const pageLimit = Math.min(100, remaining ?? 100);
        const page = await fetchPage(channel, pageLimit, before);

        if (page.length === 0) {
          break;
        }

        page.sort((a, b) => b.createdTimestamp - a.createdTimestamp);

        for (const message of page) {
          if (sinceTimestamp && message.createdTimestamp < sinceTimestamp) {
            stopBecauseSince = true;
            break;
          }

          await persistMessage(message, {
            db: deps.db,
            logger: deps.logger,
            hasMessageContent: deps.hasMessageContent,
          });

          localIngested += 1;
          globalIngested += 1;
          const createdAtIso = message.createdAt.toISOString();
          if (!newestSeenAt || createdAtIso > newestSeenAt) {
            newestSeenAt = createdAtIso;
          }
          newestSeenMessageId = maxSnowflake(newestSeenMessageId, message.id);

          if (options.onProgress) {
            await options.onProgress({
              channelId: target.channelId,
              channelName: target.channelName,
              kind: target.kind,
              messagesIngested: localIngested,
              totalIngested: globalIngested,
            });
          }

          if (options.max && localIngested >= options.max) {
            stopBecauseMax = true;
            break;
          }
        }

        const oldest = page[page.length - 1];
        before = oldest.id;
        saveCheckpoint(deps.checkpointDir, {
          channelId: target.channelId,
          beforeMessageId: before,
          lastMessageId: newestSeenMessageId,
          fetchedCount: (existing?.fetchedCount ?? 0) + localIngested,
          completed: false,
          lastRunAt: new Date().toISOString(),
        });

        if (stopBecauseSince || stopBecauseMax) {
          break;
        }
      }

      const completed = stopBecauseSince || !stopBecauseMax;
      const checkpoint: ChannelCheckpoint = {
        channelId: target.channelId,
        beforeMessageId: before,
        lastMessageId: newestSeenMessageId,
        fetchedCount: (existing?.fetchedCount ?? 0) + localIngested,
        completed,
        lastRunAt: new Date().toISOString(),
      };
      saveCheckpoint(deps.checkpointDir, checkpoint);

      deps.db.recordChannelAccess({
        channelId: target.channelId,
        canView: true,
        canReadHistory: true,
        hasMessageContent: deps.hasMessageContent,
        lastBackfillAt: newestSeenAt ?? new Date().toISOString(),
        lastError: null,
      });

      deps.logger.logEvent("backfill.channel.done", {
        channelId: target.channelId,
        messagesIngested: localIngested,
        completed,
      });

      targetsProcessed += 1;
    } catch (error) {
      const reason = error instanceof Error ? error.message : "unknown backfill error";
      skipped.push({
        channelId: target.channelId,
        reason,
      });

      deps.db.recordChannelAccess({
        channelId: target.channelId,
        canView: true,
        canReadHistory: true,
        hasMessageContent: deps.hasMessageContent,
        lastBackfillAt: null,
        lastError: reason,
      });

      deps.logger.logEvent("backfill.channel.error", {
        channelId: target.channelId,
        error: reason,
      });
    }
  }

  return {
    targetsProcessed,
    messagesIngested: globalIngested,
    skipped,
  };
};

export const runBackfill = async (
  guild: Guild,
  deps: BackfillDeps,
  options: BackfillOptions,
): Promise<BackfillSummary> => {
  const coverage = await discoverCoverage(guild);
  const baselineSkipped = upsertCoverageToDb(deps, coverage.entries);

  const targets = filterTargets(coverage.targets, options.scope, options.channelId);
  const processed = await processTargets(guild, deps, targets, {
    since: options.since,
    max: options.max,
    onProgress: options.onProgress,
  });
  const skipped = [...baselineSkipped, ...processed.skipped];

  return {
    targetsConsidered: targets.length,
    targetsProcessed: processed.targetsProcessed,
    targetsSkipped: skipped.length,
    messagesIngested: processed.messagesIngested,
    skipped,
  };
};

export const runIncrementalBackfill = async (
  guild: Guild,
  deps: BackfillDeps,
  options: IncrementalBackfillOptions = {},
): Promise<BackfillSummary> => {
  const coverage = await discoverCoverage(guild);
  const baselineSkipped = upsertCoverageToDb(deps, coverage.entries);

  const processed = await processTargets(guild, deps, coverage.targets, {
    max: options.max,
    onProgress: options.onProgress,
    sinceResolver: (target) => resolveIncrementalSinceIso(deps, target.channelId),
  });
  const skipped = [...baselineSkipped, ...processed.skipped];

  return {
    targetsConsidered: coverage.targets.length,
    targetsProcessed: processed.targetsProcessed,
    targetsSkipped: skipped.length,
    messagesIngested: processed.messagesIngested,
    skipped,
  };
};
