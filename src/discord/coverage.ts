import {
  ChannelType,
  type Guild,
  type GuildBasedChannel,
  PermissionsBitField,
} from "discord.js";

export interface CoverageEntry {
  channelId: string;
  channelName: string;
  kind: "channel" | "thread";
  canView: boolean;
  canReadHistory: boolean;
  skippedReason?: string;
}

export interface BackfillTarget {
  channelId: string;
  channelName: string;
  kind: "channel" | "thread";
}

export interface CoverageResult {
  entries: CoverageEntry[];
  targets: BackfillTarget[];
}

const SUPPORTED_TYPES = new Set<number>([
  ChannelType.GuildText,
  ChannelType.GuildAnnouncement,
  ChannelType.PublicThread,
  ChannelType.PrivateThread,
  ChannelType.AnnouncementThread,
]);

const isSupported = (channel: GuildBasedChannel): boolean => {
  if (!channel.isTextBased()) {
    return false;
  }
  return SUPPORTED_TYPES.has(channel.type);
};

const isThreadKind = (channel: GuildBasedChannel): boolean => {
  return (
    channel.type === ChannelType.PublicThread ||
    channel.type === ChannelType.PrivateThread ||
    channel.type === ChannelType.AnnouncementThread
  );
};

const channelName = (channel: GuildBasedChannel): string => {
  if ("name" in channel && typeof channel.name === "string") {
    return channel.name;
  }
  return channel.id;
};

export const discoverCoverage = async (guild: Guild): Promise<CoverageResult> => {
  await guild.channels.fetch();
  const activeThreads = await guild.channels.fetchActiveThreads().catch(() => null);

  const channelMap = new Map<string, GuildBasedChannel>();
  for (const channel of guild.channels.cache.values()) {
    channelMap.set(channel.id, channel);
  }
  if (activeThreads) {
    for (const thread of activeThreads.threads.values()) {
      channelMap.set(thread.id, thread);
    }
  }

  const me = guild.members.me ?? (await guild.members.fetchMe());

  const entries: CoverageEntry[] = [];
  const targets: BackfillTarget[] = [];

  for (const channel of channelMap.values()) {
    const kind: "channel" | "thread" = isThreadKind(channel) ? "thread" : "channel";

    if (!isSupported(channel)) {
      entries.push({
        channelId: channel.id,
        channelName: channelName(channel),
        kind,
        canView: false,
        canReadHistory: false,
        skippedReason: "unsupported channel type",
      });
      continue;
    }

    const permissions = channel.permissionsFor(me);
    const canView = permissions?.has(PermissionsBitField.Flags.ViewChannel) ?? false;
    const canReadHistory = permissions?.has(PermissionsBitField.Flags.ReadMessageHistory) ?? false;

    let skippedReason: string | undefined;
    if (!canView) {
      skippedReason = "missing ViewChannel permission";
    } else if (!canReadHistory) {
      skippedReason = "missing ReadMessageHistory permission";
    }

    entries.push({
      channelId: channel.id,
      channelName: channelName(channel),
      kind,
      canView,
      canReadHistory,
      skippedReason,
    });

    if (!skippedReason) {
      targets.push({
        channelId: channel.id,
        channelName: channelName(channel),
        kind,
      });
    }
  }

  return { entries, targets };
};
