import {
  AttachmentBuilder,
  PermissionFlagsBits,
  ThreadAutoArchiveDuration,
  type Message,
  type MessageCreateOptions,
} from "discord.js";
import type { ChatMode, ChatThreadMode, LokiDb } from "../storage/db";
import type { NdjsonLogger } from "../storage/ndjson";
import { runConversationalRequest } from "./request";
import { writeMarkdownReport } from "./ui/report";
import { isUnknownInteractionError } from "./ui/interaction";

export const CHAT_COOLDOWN_MS = 15_000;
const CHAT_ATTACHMENT_THRESHOLD = 2500;

const PREFIX_PATTERN = /^loki(?::|\s+)/i;
const GREETING_ONLY_PATTERN =
  /^(hi|hello|hey|yo|howdy|hiya|sup|gm|gn|good (morning|afternoon|evening))(?:[!?.\s]+)?$/i;
const THANKS_ONLY_PATTERN = /^(thanks|thank you|thx|ty|good bot)(?:[!?.\s]+)?$/i;
const META_ONLY_PATTERN =
  /^(how are you|who are you|what can you do|what do you do|help|are you there|ping|test)(?:[!?.\s]+)?$/i;
const META_QUESTION_PATTERN =
  /^(how are you|who are you|what can you do|what do you do|what model are you|are you online)\??$/i;
const TASK_HINT_PATTERN =
  /\b(summarize|summary|recap|find|search|show|list|compare|explain|status|update|updates|incident|issue|investigate|analyze|what happened|why|when|where|which|who|how many|how much)\b/i;

export type ChatTrigger = "mention" | "prefix" | "channel";
export type ChatIntent = "greeting_meta" | "task_question";

export interface ChatTriggerInput {
  content: string;
  botUserId: string;
  mentionsBot: boolean;
  channelEnabled: boolean;
  mode?: ChatMode;
}

export interface ChatTriggerMatch {
  trigger: ChatTrigger;
  prompt: string;
}

export interface ConversationalChatContext {
  db: LokiDb;
  logger: NdjsonLogger;
  dataDir: string;
  defaultModel: string;
}

const lastChatReplyAtByChannel = new Map<string, number>();

const normalize = (value: string): string => value.trim();

const stripBotMentions = (content: string, botUserId: string): string => {
  const escaped = botUserId.replace(/[-/\\^$*+?.()|[\]{}]/g, "\\$&");
  return normalize(content.replace(new RegExp(`<@!?${escaped}>`, "g"), " "));
};

const parsePrefixPrompt = (content: string): string | undefined => {
  const trimmedStart = content.trimStart();
  const match = trimmedStart.match(PREFIX_PATTERN);
  if (!match) {
    return undefined;
  }
  const prompt = normalize(trimmedStart.slice(match[0].length));
  return prompt || undefined;
};

const normalizeIntentText = (value: string): string => normalize(value).toLowerCase().replace(/\s+/g, " ");

const isTruthyFlag = (value: string | undefined): boolean => {
  if (!value) {
    return false;
  }
  const normalized = value.trim().toLowerCase();
  return normalized === "1" || normalized === "true" || normalized === "on";
};

export const classifyChatIntent = (prompt: string): ChatIntent => {
  const normalized = normalizeIntentText(prompt);
  if (!normalized) {
    return "greeting_meta";
  }

  if (
    GREETING_ONLY_PATTERN.test(normalized) ||
    THANKS_ONLY_PATTERN.test(normalized) ||
    META_ONLY_PATTERN.test(normalized)
  ) {
    return "greeting_meta";
  }

  const tokenCount = normalized.match(/[a-z0-9']+/g)?.length ?? 0;
  const hasTaskHint = TASK_HINT_PATTERN.test(normalized) || normalized.endsWith("?");

  if (hasTaskHint) {
    return META_QUESTION_PATTERN.test(normalized) ? "greeting_meta" : "task_question";
  }

  return tokenCount <= 4 ? "greeting_meta" : "task_question";
};

const buildGreetingReply = (prompt: string): string => {
  const normalized = normalizeIntentText(prompt);

  if (THANKS_ONLY_PATTERN.test(normalized)) {
    return "Anytime. Ask me what changed in this channel and I will cite sources.";
  }

  if (META_ONLY_PATTERN.test(normalized) || META_QUESTION_PATTERN.test(normalized)) {
    return [
      "I can answer questions using indexed server history.",
      "Ask a concrete task or question and I will include sources.",
    ].join("\n");
  }

  return [
    "Hey. I am here.",
    "Ask a question about this channel, and I will answer with sources.",
  ].join("\n");
};

const buildChatReplyOptions = (
  dataDir: string,
  channelId: string,
  responseText: string,
): MessageCreateOptions => {
  const options: MessageCreateOptions = {
    allowedMentions: { repliedUser: false },
  };

  if (responseText.length <= CHAT_ATTACHMENT_THRESHOLD) {
    options.content = responseText;
    return options;
  }

  const written = writeMarkdownReport(dataDir, `loki_chat_channel_${channelId}`, responseText);
  const preview = `${responseText.slice(0, CHAT_ATTACHMENT_THRESHOLD)}\n...`;
  options.content = [preview, "", "Attached full report.", `Attached report: ${written.filePath}`].join(
    "\n",
  );
  options.files = [new AttachmentBuilder(written.filePath, { name: written.fileName })];
  return options;
};

const isDebugChatEnabled = (db: LokiDb): boolean => {
  return isTruthyFlag(process.env.LOKI_DEBUG_CHAT) || db.isChatDebugEnabled();
};

const allowsTrigger = (mode: ChatMode | undefined, trigger: ChatTrigger): boolean => {
  if (mode === "off") {
    return false;
  }
  if (!mode) {
    return trigger === "mention" || trigger === "prefix" || trigger === "channel";
  }
  return mode === trigger;
};

export const detectChatTrigger = (input: ChatTriggerInput): ChatTriggerMatch | undefined => {
  const content = normalize(input.content);
  if (!content) {
    return undefined;
  }

  if (input.mentionsBot && allowsTrigger(input.mode, "mention")) {
    const mentionPrompt = stripBotMentions(content, input.botUserId);
    if (mentionPrompt) {
      return { trigger: "mention", prompt: mentionPrompt };
    }
  }

  const prefixPrompt = parsePrefixPrompt(content);
  if (prefixPrompt && allowsTrigger(input.mode, "prefix")) {
    return { trigger: "prefix", prompt: prefixPrompt };
  }

  if (input.channelEnabled && allowsTrigger(input.mode, "channel")) {
    return { trigger: "channel", prompt: content };
  }

  return undefined;
};

const canRespondInChannel = (message: Message): boolean => {
  if (!message.inGuild()) {
    return false;
  }

  const botUserId = message.client.user?.id;
  if (!botUserId) {
    return false;
  }

  const permissions = message.channel.permissionsFor(botUserId);
  if (!permissions) {
    return false;
  }

  const canView = permissions.has(PermissionFlagsBits.ViewChannel);
  const canReadHistory = permissions.has(PermissionFlagsBits.ReadMessageHistory);
  const canSend =
    permissions.has(PermissionFlagsBits.SendMessages) ||
    permissions.has(PermissionFlagsBits.SendMessagesInThreads);

  return canView && canReadHistory && canSend;
};

const isThreadChannel = (channel: unknown): boolean => {
  if (!channel || typeof channel !== "object") {
    return false;
  }

  const candidate = channel as { isThread?: () => boolean };
  return typeof candidate.isThread === "function" && candidate.isThread();
};

const shouldRouteToThread = (
  mode: ChatThreadMode,
  intent: ChatIntent,
  message: Message,
): boolean => {
  if (mode === "off") {
    return false;
  }

  if (isThreadChannel(message.channel)) {
    return false;
  }

  if (mode === "ask") {
    return intent === "task_question";
  }

  return true;
};

const buildThreadName = (authorName: string, channelId: string): string => {
  const clean = authorName
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  const base = clean || "user";
  return `loki-${base}-${channelId}`.slice(0, 100);
};

type SendableThreadLike = {
  id: string;
  send: (options: MessageCreateOptions) => Promise<unknown>;
  archived?: boolean;
  setArchived?: (archived: boolean, reason?: string) => Promise<unknown>;
};

const isSendableThreadLike = (value: unknown): value is SendableThreadLike => {
  if (!value || typeof value !== "object") {
    return false;
  }

  const candidate = value as { id?: unknown; send?: unknown };
  return typeof candidate.id === "string" && typeof candidate.send === "function";
};

const resolveThreadDestination = async (
  message: Message,
  db: LokiDb,
): Promise<{ thread?: SendableThreadLike; pointerText?: string }> => {
  const guildId = message.guildId;
  if (!guildId) {
    return {};
  }

  const route = db.getChatThreadRoute(guildId, message.channelId, message.author.id);

  if (route && message.guild) {
    const existing = await message.guild.channels.fetch(route.threadId).catch(() => null);
    if (existing && isSendableThreadLike(existing) && isThreadChannel(existing)) {
      if (existing.archived && typeof existing.setArchived === "function") {
        await existing.setArchived(false).catch(() => {
          // If unarchive fails, send() may still succeed depending on thread state/permissions.
        });
      }

      db.setChatThreadRoute(guildId, message.channelId, message.author.id, existing.id);
      return { thread: existing };
    }
  }

  if (typeof message.startThread !== "function") {
    return {};
  }

  const created = await message.startThread({
    name: buildThreadName(message.author.username, message.channelId),
    autoArchiveDuration: ThreadAutoArchiveDuration.OneDay,
  });

  if (!isSendableThreadLike(created)) {
    return {};
  }

  db.setChatThreadRoute(guildId, message.channelId, message.author.id, created.id);
  return {
    thread: created,
    pointerText: `Created thread: <#${created.id}>`,
  };
};

export const handleConversationalMessage = async (
  message: Message,
  ctx: ConversationalChatContext,
  botUserId: string,
): Promise<void> => {
  if (!message.inGuild()) {
    return;
  }

  if (message.author.bot) {
    return;
  }

  if (!canRespondInChannel(message)) {
    return;
  }

  const mode = ctx.db.getChatMode(message.guildId);
  const channelEnabled = ctx.db.isChatChannelEnabled(message.guildId, message.channelId);
  const trigger = detectChatTrigger({
    content: message.content,
    botUserId,
    mentionsBot: message.mentions.users.has(botUserId),
    channelEnabled,
    mode,
  });

  if (!trigger) {
    return;
  }

  const nowMs = Date.now();
  const lastReplyAt = lastChatReplyAtByChannel.get(message.channelId) ?? 0;
  if (nowMs - lastReplyAt < CHAT_COOLDOWN_MS) {
    return;
  }

  const intent = classifyChatIntent(trigger.prompt);
  let responseText: string | undefined;
  let replyOptions: MessageCreateOptions;
  let destinationThread: SendableThreadLike | undefined;
  let pointerText: string | undefined;

  if (intent === "greeting_meta") {
    replyOptions = {
      allowedMentions: { repliedUser: false },
      content: buildGreetingReply(trigger.prompt),
    };
  } else {
    const result = await runConversationalRequest(
      {
        db: ctx.db,
        defaultModel: ctx.defaultModel,
      },
      {
        prompt: trigger.prompt,
        scope: "here",
        guildId: message.guildId,
        channelId: message.channelId,
        excludeMessageIds: [message.id],
        ai: "on",
        responseStyle: "chat",
        includeDiagnostics: isDebugChatEnabled(ctx.db),
      },
    );

    responseText = result.text;
    replyOptions = buildChatReplyOptions(ctx.dataDir, message.channelId, responseText);
  }

  if (shouldRouteToThread(ctx.db.getChatThreadMode(message.guildId), intent, message)) {
    try {
      const route = await resolveThreadDestination(message, ctx.db);
      destinationThread = route.thread;
      pointerText = route.pointerText;
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : "unknown thread routing failure";
      ctx.logger.logEvent("discord.chat.thread.error", {
        guildId: message.guildId,
        channelId: message.channelId,
        authorId: message.author.id,
        error: errorMessage,
      });
      destinationThread = undefined;
      pointerText = undefined;
    }
  }

  if (responseText) {
    const reportChannelId = destinationThread?.id ?? message.channelId;
    replyOptions = buildChatReplyOptions(ctx.dataDir, reportChannelId, responseText);
  }

  try {
    if (destinationThread) {
      if (pointerText) {
        await message.reply({
          allowedMentions: { repliedUser: false },
          content: pointerText,
        });
      }
      await destinationThread.send(replyOptions);
    } else {
      await message.reply(replyOptions);
    }
    lastChatReplyAtByChannel.set(message.channelId, nowMs);
  } catch (error) {
    if (isUnknownInteractionError(error)) {
      return;
    }

    const errorMessage = error instanceof Error ? error.message : "unknown chat reply failure";
    ctx.logger.logEvent("discord.chat.reply.error", {
      guildId: message.guildId,
      channelId: message.channelId,
      trigger: trigger.trigger,
      error: errorMessage,
    });
  }
};
