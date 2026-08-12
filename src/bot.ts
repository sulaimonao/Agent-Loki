import { Events, type ChatInputCommandInteraction } from "discord.js";
import {
  assertDiscordEnv,
  ensureRuntimeDirs,
  isGuildAllowed,
  loadConfig,
  type LokiConfig,
} from "./config";
import { Analyzer } from "./ai/analyzer";
import { OllamaClient } from "./ai/ollama";
import { ApprovalService } from "./moderation/approvals";
import { PolicyManager } from "./moderation/policy";
import {
  createDiscordClient,
  detectMessageContentAvailability,
  wireDiscordHandlers,
} from "./discord/client";
import {
  handleLokiCommand,
  handleLokiUiInteraction,
  type LokiCommandContext,
} from "./discord/commands/loki";
import { LokiDb } from "./storage/db";
import { NdjsonLogger } from "./storage/ndjson";
import { readPhaseStatus, writeDerivedPhaseStatus } from "./status/phase";
import {
  ephemeralReply,
  isUnknownInteractionError,
  respondSafely,
} from "./discord/ui/interaction";
import { handleConversationalMessage } from "./discord/chat";
import { startDailyIndexScheduler } from "./discord/indexing";

const bootstrap = async (): Promise<void> => {
  const config: LokiConfig = loadConfig();
  assertDiscordEnv(config);
  ensureRuntimeDirs(config);

  const db = new LokiDb(config.dbPath);
  db.init();

  const logger = new NdjsonLogger(config.logDir);
  const policyManager = new PolicyManager(config.policyPath);
  const ollama = new OllamaClient(config.ollamaUrl);
  const analyzer = new Analyzer(db, ollama, config.ollamaModel);
  const approvals = new ApprovalService(db, logger, config.enableEnforcement);

  const phase = readPhaseStatus(process.cwd());
  writeDerivedPhaseStatus(`${config.dataDir}/status.json`, {
    phase: phase.phase,
    status: phase.status,
    lastUpdated: phase.lastUpdated,
  });

  const client = createDiscordClient();
  let hasMessageContent = false;
  let indexScheduler: ReturnType<typeof startDailyIndexScheduler> | undefined;

  wireDiscordHandlers(client, {
    db,
    logger,
    policyManager,
    approvals,
    getHasMessageContent: () => hasMessageContent,
    isGuildAllowed: (guildId) => isGuildAllowed(config, guildId),
  });

  client.once(Events.ClientReady, async (readyClient) => {
    hasMessageContent = await detectMessageContentAvailability(readyClient);

    logger.logEvent("bot.ready", {
      botUserId: readyClient.user.id,
      hasMessageContent,
      enableEnforcement: config.enableEnforcement,
      guildCount: readyClient.guilds.cache.size,
    });

    console.log(`Loki ready as ${readyClient.user.tag}`);
    console.log(`Message content intent available: ${hasMessageContent ? "yes" : "no"}`);
    if (config.guildAllowlist.length > 0) {
      console.log(`Guild allowlist active: ${config.guildAllowlist.join(", ")}`);
    }
    if (config.dbMode === "per_guild") {
      console.log(`DB mode: per_guild (${config.dbPath})`);
    }

    indexScheduler = startDailyIndexScheduler(readyClient, {
      db,
      logger,
      checkpointDir: config.checkpointDir,
      getHasMessageContent: () => hasMessageContent,
      isGuildAllowed: (guildId) => isGuildAllowed(config, guildId),
    });
    commandCtx.runDailyIndexNow = () => {
      if (!indexScheduler) {
        throw new Error("Daily index scheduler is not initialized.");
      }
      return indexScheduler.triggerNow();
    };
  });

  client.on("error", (error) => {
    const message = error instanceof Error ? error.message : String(error);
    logger.logEvent("discord.client.error", { message });
    console.error(`Discord client error: ${message}`);
  });

  const commandCtx: LokiCommandContext = {
    config,
    db,
    logger,
    policyManager,
    analyzer,
    approvals,
    ollama,
    hasMessageContent,
    isGuildAllowed: (guildId) => isGuildAllowed(config, guildId),
    runDailyIndexNow: undefined,
  };

  client.on(Events.MessageCreate, (message) => {
    const botUserId = client.user?.id;
    if (!botUserId) {
      return;
    }
    if (!isGuildAllowed(config, message.guildId ?? undefined)) {
      logger.logEvent("discord.chat.skipped_unapproved_guild", {
        guildId: message.guildId ?? null,
        channelId: message.channelId,
        authorId: message.author.id,
      });
      return;
    }

    handleConversationalMessage(
      message,
      {
        db,
        logger,
        dataDir: config.dataDir,
        defaultModel: config.ollamaModel,
      },
      botUserId,
    ).catch((error: unknown) => {
      const messageText = error instanceof Error ? error.message : "unknown conversational chat error";
      logger.logEvent("discord.chat.error", {
        channelId: message.channelId,
        guildId: message.guildId ?? null,
        error: messageText,
      });
    });
  });

  client.on(Events.InteractionCreate, async (interaction) => {
    commandCtx.hasMessageContent = hasMessageContent;
    const interactionGuildId = "guildId" in interaction ? interaction.guildId : null;
    if (interactionGuildId && !isGuildAllowed(config, interactionGuildId)) {
      logger.logEvent("discord.interaction.skipped_unapproved_guild", {
        guildId: interactionGuildId,
        type: interaction.type,
      });
      if (interaction.isRepliable()) {
        await respondSafely(
          interaction,
          ephemeralReply("This guild is not approved for Loki operations."),
          "replyOrFollowUp",
          () => {
            logger.logEvent("discord.interaction.skipped_unapproved_guild.response_expired", {
              guildId: interactionGuildId,
            });
          },
        );
      }
      return;
    }

    if (interaction.isButton() || interaction.isStringSelectMenu() || interaction.isModalSubmit()) {
      try {
        const handled = await handleLokiUiInteraction(interaction, commandCtx);
        if (handled) {
          return;
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown UI interaction error";
        logger.logEvent("ui.error", {
          customId: interaction.customId,
          error: message,
        });
        if (!isUnknownInteractionError(error)) {
          await respondSafely(
            interaction,
            ephemeralReply(`Loki UI action failed: ${message}`),
            "replyOrFollowUp",
            () => {
              logger.logEvent("ui.error.response_expired", {
                customId: interaction.customId,
              });
            },
          );
        }
        return;
      }
    }

    if (!interaction.isChatInputCommand()) {
      return;
    }

    if (interaction.commandName !== "loki") {
      return;
    }

    try {
      await handleLokiCommand(interaction as ChatInputCommandInteraction, commandCtx);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown command error";
      logger.logEvent("command.error", {
        command: interaction.commandName,
        subcommand: interaction.options.getSubcommand(false),
        error: message,
      });

      await respondSafely(
        interaction,
        ephemeralReply(`Command failed: ${message}`),
        "editOrReply",
        () => {
          logger.logEvent("command.error.response_expired", {
            command: interaction.commandName,
          });
        },
      );
    }
  });

  const cleanup = async (): Promise<void> => {
    logger.logEvent("bot.shutdown", {
      ts: new Date().toISOString(),
    });
    indexScheduler?.stop();
    await client.destroy();
    db.close();
  };

  process.on("SIGINT", () => {
    cleanup().finally(() => process.exit(0));
  });
  process.on("SIGTERM", () => {
    cleanup().finally(() => process.exit(0));
  });
  process.on("unhandledRejection", (reason) => {
    const message = reason instanceof Error ? reason.message : String(reason);
    logger.logEvent("process.unhandled_rejection", { message });
    console.error(`Unhandled rejection: ${message}`);
  });
  process.on("uncaughtException", (error) => {
    const message = error instanceof Error ? error.message : String(error);
    logger.logEvent("process.uncaught_exception", { message });
    if (isUnknownInteractionError(error)) {
      console.warn(`Ignoring unknown interaction exception: ${message}`);
      return;
    }
    console.error(`Uncaught exception: ${message}`);
  });

  await client.login(config.discordToken);
};

bootstrap().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : "Unknown bootstrap error";
  console.error(`Failed to start Loki: ${message}`);
  process.exit(1);
});
