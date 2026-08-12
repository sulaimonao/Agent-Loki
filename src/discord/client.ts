import {
  ApplicationFlagsBitField,
  Client,
  GatewayIntentBits,
  type Message,
  type PartialMessage,
} from "discord.js";
import { evaluateMessage } from "../moderation/engine";
import { ApprovalService } from "../moderation/approvals";
import { PolicyManager } from "../moderation/policy";
import { LokiDb } from "../storage/db";
import { NdjsonLogger } from "../storage/ndjson";
import { persistMessage } from "./ingest";

export interface DiscordRuntimeDeps {
  db: LokiDb;
  logger: NdjsonLogger;
  policyManager: PolicyManager;
  approvals: ApprovalService;
  getHasMessageContent: () => boolean;
  isGuildAllowed?: (guildId: string | undefined) => boolean;
}

export const createDiscordClient = (): Client => {
  return new Client({
    intents: [
      GatewayIntentBits.Guilds,
      GatewayIntentBits.GuildMessages,
      GatewayIntentBits.MessageContent,
    ],
  });
};

export const detectMessageContentAvailability = async (client: Client): Promise<boolean> => {
  const requested = client.options.intents.has(GatewayIntentBits.MessageContent);

  try {
    const app = client.application;
    const flags = app?.flags;

    if (!flags) {
      return requested;
    }

    const allFlags = ApplicationFlagsBitField.Flags as unknown as Record<string, number>;
    const fullFlag = allFlags.GatewayMessageContent;
    const limitedFlag = allFlags.GatewayMessageContentLimited;

    if (fullFlag && flags.has(fullFlag)) {
      return true;
    }
    if (limitedFlag && flags.has(limitedFlag)) {
      return true;
    }

    return false;
  } catch {
    return requested;
  }
};

const handleMessageForModeration = async (
  message: Message,
  deps: DiscordRuntimeDeps,
): Promise<void> => {
  if (!message.inGuild()) {
    return;
  }

  if (message.author.bot) {
    return;
  }

  const policy = deps.policyManager.getPolicy();
  const windowSeconds = policy.moderation.spam.window_seconds;
  const since = new Date(Date.now() - windowSeconds * 1000).toISOString();

  const recent = deps.db.getRecentMessagesByAuthorInChannel(
    message.author.id,
    message.channelId,
    since,
    policy.moderation.spam.repeated_messages_threshold + 20,
  );

  const suggestions = evaluateMessage(
    {
      messageId: message.id,
      guildId: message.guildId,
      channelId: message.channelId,
      authorId: message.author.id,
      content: message.content,
      mentionCount: message.mentions.users.size,
      createdAtIso: message.createdAt.toISOString(),
    },
    policy,
    recent,
  );

  for (const suggestion of suggestions) {
    const execution: Record<string, unknown> = {};
    if (suggestion.action === "timeout") {
      execution.minutes = 10;
    }

    const pendingId = deps.approvals.createPendingApproval({
      guildId: suggestion.guildId,
      channelId: suggestion.channelId,
      targetUserId: suggestion.targetUserId,
      action: suggestion.action,
      reason: suggestion.reason,
      evidence: suggestion.evidence,
      execution,
      requestedBy: "system",
    });

    deps.logger.logEvent("moderation.suggested", {
      pendingId,
      suggestion,
    });
  }
};

const ingestAndModerate = async (
  incoming: Message | PartialMessage,
  deps: DiscordRuntimeDeps,
): Promise<void> => {
  const guildId = incoming.guildId ?? undefined;
  if (deps.isGuildAllowed && !deps.isGuildAllowed(guildId)) {
    deps.logger.logEvent("discord.ingest.skipped_unapproved_guild", {
      guildId: guildId ?? null,
      messageId: incoming.id,
      channelId: incoming.channelId,
    });
    return;
  }

  await persistMessage(incoming, {
    db: deps.db,
    logger: deps.logger,
    hasMessageContent: deps.getHasMessageContent(),
  });

  if (incoming.partial) {
    return;
  }

  if (!deps.getHasMessageContent()) {
    return;
  }

  await handleMessageForModeration(incoming, deps);
};

export const wireDiscordHandlers = (client: Client, deps: DiscordRuntimeDeps): void => {
  client.on("messageCreate", (message) => {
    ingestAndModerate(message, deps).catch((error: unknown) => {
      const messageText = error instanceof Error ? error.message : "unknown messageCreate failure";
      deps.logger.logEvent("discord.messageCreate.error", { error: messageText });
    });
  });

  client.on("messageUpdate", (_oldMessage, newMessage) => {
    ingestAndModerate(newMessage, deps).catch((error: unknown) => {
      const messageText = error instanceof Error ? error.message : "unknown messageUpdate failure";
      deps.logger.logEvent("discord.messageUpdate.error", { error: messageText });
    });
  });
};
