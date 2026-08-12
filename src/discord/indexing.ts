import type { Client } from "discord.js";
import { runIncrementalBackfill } from "./backfill";
import type { LokiDb } from "../storage/db";
import type { NdjsonLogger } from "../storage/ndjson";

export const DAILY_INDEX_INTERVAL_MS = 24 * 60 * 60 * 1000;
export const INDEX_VERSION = "1";

export interface DailyIndexRunSummary {
  runAt: string;
  finishedAt: string;
  guildsProcessed: number;
  targetsConsidered: number;
  targetsProcessed: number;
  targetsSkipped: number;
  messagesIngested: number;
}

export interface IndexScheduler {
  stop: () => void;
  triggerNow: () => Promise<DailyIndexRunSummary>;
}

interface IndexSchedulerDeps {
  db: LokiDb;
  logger: NdjsonLogger;
  checkpointDir: string;
  getHasMessageContent: () => boolean;
  isGuildAllowed?: (guildId: string | undefined) => boolean;
  intervalMs?: number;
  maxPerTarget?: number;
  runOnStart?: boolean;
}

type IndexTrigger = "startup" | "interval" | "manual";

const runIndexOnce = async (
  client: Client,
  deps: IndexSchedulerDeps,
  trigger: IndexTrigger,
): Promise<DailyIndexRunSummary> => {
  const runAt = new Date().toISOString();
  deps.db.markIndexRunStarted(runAt, INDEX_VERSION);

  try {
    let guildsProcessed = 0;
    let targetsConsidered = 0;
    let targetsProcessed = 0;
    let targetsSkipped = 0;
    let messagesIngested = 0;

    for (const guildRef of client.guilds.cache.values()) {
      if (deps.isGuildAllowed && !deps.isGuildAllowed(guildRef.id)) {
        deps.logger.logEvent("index.daily.guild.skipped_unapproved", {
          trigger,
          guildId: guildRef.id,
        });
        continue;
      }

      const guild = await client.guilds.fetch(guildRef.id);
      const summary = await runIncrementalBackfill(
        guild,
        {
          db: deps.db,
          logger: deps.logger,
          checkpointDir: deps.checkpointDir,
          hasMessageContent: deps.getHasMessageContent(),
        },
        {
          max: deps.maxPerTarget,
        },
      );

      guildsProcessed += 1;
      targetsConsidered += summary.targetsConsidered;
      targetsProcessed += summary.targetsProcessed;
      targetsSkipped += summary.targetsSkipped;
      messagesIngested += summary.messagesIngested;
    }

    const finishedAt = new Date().toISOString();
    deps.db.markIndexRunSuccess(finishedAt, INDEX_VERSION);

    deps.logger.logEvent("index.daily.ok", {
      trigger,
      runAt,
      finishedAt,
      guildsProcessed,
      targetsConsidered,
      targetsProcessed,
      targetsSkipped,
      messagesIngested,
    });

    return {
      runAt,
      finishedAt,
      guildsProcessed,
      targetsConsidered,
      targetsProcessed,
      targetsSkipped,
      messagesIngested,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown daily index error";
    deps.db.markIndexRunError(message, new Date().toISOString(), INDEX_VERSION);
    deps.logger.logEvent("index.daily.error", {
      trigger,
      runAt,
      error: message,
    });
    throw error;
  }
};

export const startDailyIndexScheduler = (
  client: Client,
  deps: IndexSchedulerDeps,
): IndexScheduler => {
  const intervalMs = deps.intervalMs ?? DAILY_INDEX_INTERVAL_MS;
  let timer: NodeJS.Timeout | undefined;
  let inFlight: Promise<DailyIndexRunSummary> | undefined;

  const trigger = (source: IndexTrigger): Promise<DailyIndexRunSummary> => {
    if (inFlight) {
      return inFlight;
    }

    inFlight = runIndexOnce(client, deps, source).finally(() => {
      inFlight = undefined;
    });
    return inFlight;
  };

  timer = setInterval(() => {
    void trigger("interval").catch(() => {
      // Errors are recorded to DB/internal logs by runIndexOnce.
    });
  }, intervalMs);

  if (deps.runOnStart ?? true) {
    void trigger("startup").catch(() => {
      // Errors are recorded to DB/internal logs by runIndexOnce.
    });
  }

  return {
    stop: () => {
      if (timer) {
        clearInterval(timer);
        timer = undefined;
      }
    },
    triggerNow: () => trigger("manual"),
  };
};
