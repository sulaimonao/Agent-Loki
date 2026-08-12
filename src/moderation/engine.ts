import type { MessageWindowRow } from "../storage/db";
import type { LokiPolicy } from "./policy";

export type SuggestedActionType =
  | "warn"
  | "delete"
  | "timeout"
  | "kick"
  | "ban"
  | "lock"
  | "slowmode"
  | "purge";

export interface SuggestedAction {
  id: string;
  ts: string;
  guildId?: string | null;
  channelId?: string | null;
  targetUserId?: string | null;
  action: SuggestedActionType;
  reason: string;
  confidence: number;
  evidence: Record<string, unknown>;
}

export interface ModerationMessageInput {
  messageId: string;
  guildId?: string | null;
  channelId: string;
  authorId: string;
  content: string;
  mentionCount: number;
  createdAtIso: string;
}

const nowId = (): string => {
  const rand = Math.random().toString(36).slice(2, 8);
  return `sug_${Date.now()}_${rand}`;
};

export const evaluateMessage = (
  message: ModerationMessageInput,
  policy: LokiPolicy,
  recentMessages: MessageWindowRow[],
): SuggestedAction[] => {
  const suggestions: SuggestedAction[] = [];
  const normalized = message.content.toLowerCase();

  for (const domain of policy.moderation.scam_domains) {
    if (normalized.includes(domain.toLowerCase())) {
      suggestions.push({
        id: nowId(),
        ts: new Date().toISOString(),
        guildId: message.guildId,
        channelId: message.channelId,
        targetUserId: message.authorId,
        action: "warn",
        reason: `Potential scam domain detected: ${domain}`,
        confidence: 0.75,
        evidence: {
          messageId: message.messageId,
          domain,
        },
      });
      break;
    }
  }

  for (const phrase of policy.moderation.forbidden_phrases) {
    if (phrase.trim() && normalized.includes(phrase.toLowerCase())) {
      suggestions.push({
        id: nowId(),
        ts: new Date().toISOString(),
        guildId: message.guildId,
        channelId: message.channelId,
        targetUserId: message.authorId,
        action: "warn",
        reason: "Forbidden phrase match",
        confidence: 0.7,
        evidence: {
          messageId: message.messageId,
          phrase,
        },
      });
      break;
    }
  }

  if (message.mentionCount >= policy.moderation.mass_mentions.threshold) {
    suggestions.push({
      id: nowId(),
      ts: new Date().toISOString(),
      guildId: message.guildId,
      channelId: message.channelId,
      targetUserId: message.authorId,
      action: "timeout",
      reason: `Mass mentions detected (${message.mentionCount})`,
      confidence: 0.8,
      evidence: {
        messageId: message.messageId,
        mentionCount: message.mentionCount,
      },
    });
  }

  const repeatedCount = recentMessages.filter(
    (row) =>
      row.content &&
      row.content.trim().length > 0 &&
      row.content.toLowerCase() === normalized &&
      row.id !== message.messageId,
  ).length;

  if (repeatedCount + 1 >= policy.moderation.spam.repeated_messages_threshold) {
    suggestions.push({
      id: nowId(),
      ts: new Date().toISOString(),
      guildId: message.guildId,
      channelId: message.channelId,
      targetUserId: message.authorId,
      action: "timeout",
      reason: `Repeated-message spam threshold reached (${repeatedCount + 1})`,
      confidence: 0.85,
      evidence: {
        messageId: message.messageId,
        repeatedCount: repeatedCount + 1,
        threshold: policy.moderation.spam.repeated_messages_threshold,
      },
    });
  }

  return suggestions;
};
