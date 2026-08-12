import {
  type Attachment,
  type GuildBasedChannel,
  type Message,
  type PartialMessage,
  ChannelType,
} from "discord.js";
import {
  LokiDb,
  type DbAttachmentInput,
  type DbChannelInput,
  type DbGuildInput,
  type DbMessageInput,
  type DbUserInput,
} from "../storage/db";
import { NdjsonLogger } from "../storage/ndjson";

export interface IngestDeps {
  db: LokiDb;
  logger: NdjsonLogger;
  hasMessageContent: boolean;
}

const mapAttachment = (attachment: Attachment): DbAttachmentInput => {
  return {
    id: attachment.id,
    url: attachment.url,
    filename: attachment.name,
    contentType: attachment.contentType,
    size: attachment.size,
  };
};

const getChannelInput = (channel: GuildBasedChannel): DbChannelInput => {
  const parent = "parentId" in channel ? channel.parentId : null;
  const typeName = ChannelType[channel.type] ?? String(channel.type);
  return {
    id: channel.id,
    guildId: channel.guild?.id,
    name: "name" in channel && channel.name ? channel.name : channel.id,
    type: typeName,
    parentId: parent,
    lastSeenAt: new Date().toISOString(),
  };
};

const getGuildInput = (message: Message): DbGuildInput | null => {
  if (!message.guild) {
    return null;
  }

  return {
    id: message.guild.id,
    name: message.guild.name,
    discoveredAt: new Date().toISOString(),
  };
};

const getUserInput = (message: Message): DbUserInput => {
  return {
    id: message.author.id,
    username: message.author.username,
    globalName: message.author.globalName,
    bot: message.author.bot,
  };
};

const asRawJson = (message: Message): string => {
  try {
    return JSON.stringify(message.toJSON());
  } catch {
    return JSON.stringify({ id: message.id, channelId: message.channelId });
  }
};

export const toDbMessageInput = (message: Message, hasMessageContent: boolean): DbMessageInput => {
  return {
    id: message.id,
    guildId: message.guildId,
    channelId: message.channelId,
    authorId: message.author.id,
    createdAt: message.createdAt.toISOString(),
    editedAt: message.editedAt?.toISOString() ?? null,
    content: hasMessageContent ? message.content ?? "" : null,
    contentUnavailable: !hasMessageContent,
    replyToId: message.reference?.messageId ?? null,
    rawJson: asRawJson(message),
  };
};

export const persistMessage = async (
  incoming: Message | PartialMessage,
  deps: IngestDeps,
): Promise<void> => {
  const message = incoming.partial ? await incoming.fetch() : incoming;

  if (!message.inGuild()) {
    return;
  }

  if (!message.channel || !message.channel.isTextBased()) {
    return;
  }

  const guildInput = getGuildInput(message);
  if (guildInput) {
    deps.db.upsertGuild(guildInput);
  }

  const channel = message.channel as GuildBasedChannel;
  deps.db.upsertChannel(getChannelInput(channel));
  deps.db.upsertUser(getUserInput(message));

  const dbMessage = toDbMessageInput(message, deps.hasMessageContent);
  const attachments = [...message.attachments.values()].map(mapAttachment);
  deps.db.upsertMessage(dbMessage, attachments);

  deps.logger.logMessage({
    ts: new Date().toISOString(),
    source: "discord",
    guildId: message.guildId,
    channelId: message.channelId,
    messageId: message.id,
    authorId: message.author.id,
    contentUnavailable: dbMessage.contentUnavailable,
    payload: JSON.parse(dbMessage.rawJson),
  });
};
