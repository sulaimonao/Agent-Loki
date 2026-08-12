import { Events } from "discord.js";
import {
  assertDiscordEnv,
  ensureRuntimeDirs,
  isGuildAllowed,
  loadConfig,
} from "../config";
import { runBackfill, type BackfillScope } from "../discord/backfill";
import { createDiscordClient, detectMessageContentAvailability } from "../discord/client";
import { LokiDb } from "../storage/db";
import { NdjsonLogger } from "../storage/ndjson";

interface CliArgs {
  scope: BackfillScope;
  channelId?: string;
  since?: string;
  max?: number;
  guildId?: string;
}

const parseArgs = (argv: string[]): CliArgs => {
  const args: CliArgs = { scope: "all" };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    const next = argv[i + 1];

    if (token === "--scope" && next) {
      if (next === "all" || next === "channel" || next === "threads") {
        args.scope = next;
      }
      i += 1;
      continue;
    }

    if (token === "--channel" && next) {
      args.channelId = next;
      i += 1;
      continue;
    }

    if (token === "--since" && next) {
      args.since = next;
      i += 1;
      continue;
    }

    if (token === "--max" && next) {
      const parsed = Number(next);
      if (Number.isFinite(parsed) && parsed > 0) {
        args.max = parsed;
      }
      i += 1;
      continue;
    }

    if (token === "--guild" && next) {
      args.guildId = next;
      i += 1;
    }
  }

  return args;
};

const run = async (): Promise<void> => {
  const cli = parseArgs(process.argv.slice(2));
  const config = loadConfig();
  assertDiscordEnv(config);
  ensureRuntimeDirs(config);

  const db = new LokiDb(config.dbPath);
  db.init();

  const logger = new NdjsonLogger(config.logDir);
  const client = createDiscordClient();

  client.once(Events.ClientReady, async (readyClient) => {
    const guildId = cli.guildId ?? config.discordGuildId ?? readyClient.guilds.cache.first()?.id;
    if (!guildId) {
      console.error("No guild available for backfill.");
      await client.destroy();
      db.close();
      process.exit(1);
      return;
    }
    if (!isGuildAllowed(config, guildId)) {
      console.error(`Guild ${guildId} is not approved by GUILD_ALLOWLIST.`);
      await client.destroy();
      db.close();
      process.exit(1);
      return;
    }

    const guild = await readyClient.guilds.fetch(guildId);
    const hasMessageContent = await detectMessageContentAvailability(readyClient);

    const summary = await runBackfill(
      guild,
      {
        db,
        logger,
        checkpointDir: config.checkpointDir,
        hasMessageContent,
      },
      {
        scope: cli.scope,
        channelId: cli.channelId,
        since: cli.since,
        max: cli.max,
        onProgress: (update) => {
          console.log(
            `progress channel=${update.channelName} id=${update.channelId} local=${update.messagesIngested} total=${update.totalIngested}`,
          );
        },
      },
    );

    console.log("Backfill finished:");
    console.log(JSON.stringify(summary, null, 2));

    await client.destroy();
    db.close();
    process.exit(0);
  });

  await client.login(config.discordToken);
};

run().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : "unknown backfill error";
  console.error(`Backfill script failed: ${message}`);
  process.exit(1);
});
