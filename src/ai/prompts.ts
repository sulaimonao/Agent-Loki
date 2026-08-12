import type { MessageWindowRow } from "../storage/db";

export const SAFETY_SUFFIX = "Do not take actions; output text only.";

const renderMessages = (messages: MessageWindowRow[]): string => {
  const trimmed = messages.slice(0, 200);
  return trimmed
    .map((row) => {
      const content = row.content?.replace(/\s+/g, " ").trim() || "[no-content]";
      return `${row.created_at} | channel=${row.channel_id} | user=${row.author_id} | ${content}`;
    })
    .join("\n");
};

export const buildChannelSummaryPrompt = (
  channelId: string,
  windowHours: number,
  messages: MessageWindowRow[],
): string => {
  return [
    `Summarize conversation activity for Discord channel ${channelId} over the last ${windowHours} hour(s).`,
    "Highlight topics, sentiment, and unresolved items.",
    "Message data:",
    renderMessages(messages),
    SAFETY_SUFFIX,
  ].join("\n\n");
};

export const buildUserCasePrompt = (
  userId: string,
  windowHours: number,
  messages: MessageWindowRow[],
): string => {
  return [
    `Create a factual case summary for user ${userId} over the last ${windowHours} hour(s).`,
    "Include behavior patterns and notable context, but avoid judgments beyond evidence.",
    "Message data:",
    renderMessages(messages),
    SAFETY_SUFFIX,
  ].join("\n\n");
};

export const buildDraftReplyPrompt = (
  sourceMessage: MessageWindowRow,
  contextMessages: MessageWindowRow[],
): string => {
  const sourceContent = sourceMessage.content?.trim() || "[no-content]";
  return [
    "Draft a concise, neutral reply for the target Discord message.",
    `Target message: ${sourceMessage.created_at} | user=${sourceMessage.author_id} | ${sourceContent}`,
    "Relevant context:",
    renderMessages(contextMessages),
    SAFETY_SUFFIX,
  ].join("\n\n");
};
