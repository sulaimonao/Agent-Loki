import {
  LokiDb,
  type AttachmentLookupRow,
  type MessageCoverageStats,
  type MessageWindowRow,
  type SearchRow,
} from "../storage/db";
import { OllamaClient } from "./ollama";
import { buildDraftReplyPrompt } from "./prompts";

export interface AnalyzerResult {
  text: string;
  aiUsed: boolean;
  model: string;
}

export const makeJumpLink = (guildId: string, channelId: string, messageId: string): string => {
  return `https://discord.com/channels/${guildId}/${channelId}/${messageId}`;
};

const clampWindowHours = (windowHours?: number): number => {
  if (!windowHours || Number.isNaN(windowHours)) {
    return 24;
  }
  return Math.min(Math.max(windowHours, 1), 336);
};

const sinceIso = (windowHours: number, nowMs: number): string => {
  const ms = windowHours * 60 * 60 * 1000;
  return new Date(nowMs - ms).toISOString();
};

const MIN_AVAILABLE_MESSAGES = 8;
const MIN_COVERAGE_RATIO = 0.55;
const SUMMARY_LIMIT = 1200;
const MIN_REPRESENTATIVE_MESSAGES = 5;
const MAX_REPRESENTATIVE_MESSAGES = 15;
const WINDOW_EXPANSION_STEPS = [24, 168, 336] as const;
const ANSWER_EVIDENCE_LIMIT = 20;

const STOPWORDS = new Set<string>([
  "the",
  "and",
  "that",
  "this",
  "with",
  "from",
  "have",
  "your",
  "you",
  "for",
  "are",
  "was",
  "were",
  "has",
  "had",
  "not",
  "but",
  "all",
  "can",
  "will",
  "just",
  "into",
  "its",
  "our",
  "out",
  "about",
  "there",
  "their",
  "they",
  "them",
  "then",
  "than",
  "also",
  "more",
  "some",
  "any",
  "what",
  "when",
  "where",
  "who",
  "how",
  "why",
  "been",
  "being",
  "over",
  "under",
  "again",
  "after",
  "before",
  "because",
  "could",
  "should",
  "would",
  "like",
  "https",
  "http",
  "www",
  "com",
  "discord",
  "loki",
]);

interface SummaryContext {
  targetType: "channel" | "user" | "server";
  targetId: string;
  targetDisplay: string;
  channelDisplay: string;
  requestedWindowHours: number;
  selectedWindowHours: number;
  since: string;
  until: string;
  model: string;
}

interface WindowData {
  windowHours: number;
  since: string;
  until: string;
  rows: MessageWindowRow[];
  coverage: MessageCoverageStats;
}

interface WindowSearchResult {
  selected?: WindowData;
  attempts: WindowData[];
}

interface TopAuthor {
  authorId: string;
  display: string;
  count: number;
}

const compact = (value: string): string => value.replace(/\s+/g, " ").trim();

const tokenize = (text: string): string[] => {
  const matches = text.toLowerCase().match(/[a-z0-9']+/g) ?? [];
  return matches.filter((token) => {
    if (token.length < 3) {
      return false;
    }
    if (STOPWORDS.has(token)) {
      return false;
    }
    if (/^\d+$/.test(token)) {
      return false;
    }
    return true;
  });
};

const topTerms = (messages: MessageWindowRow[], limit: number): Array<{ term: string; count: number }> => {
  const counts = new Map<string, number>();
  for (const row of messages) {
    if (!row.content || row.content_unavailable === 1) {
      continue;
    }
    for (const token of tokenize(row.content)) {
      counts.set(token, (counts.get(token) ?? 0) + 1);
    }
  }

  return [...counts.entries()]
    .map(([term, count]) => ({ term, count }))
    .sort((a, b) => b.count - a.count || a.term.localeCompare(b.term))
    .slice(0, limit);
};

const topAuthors = (
  rows: MessageWindowRow[],
  userDisplayMap: ReadonlyMap<string, string>,
  limit: number,
): TopAuthor[] => {
  const counts = new Map<string, number>();
  for (const row of rows) {
    counts.set(row.author_id, (counts.get(row.author_id) ?? 0) + 1);
  }

  return [...counts.entries()]
    .map(([authorId, count]) => ({
      authorId,
      display: userDisplayMap.get(authorId) ?? authorId,
      count,
    }))
    .sort((a, b) => b.count - a.count || a.display.localeCompare(b.display))
    .slice(0, limit);
};

const shouldFailClosed = (coverage: MessageCoverageStats): boolean => {
  if (coverage.totalMessages === 0) {
    return true;
  }
  if (coverage.availableMessages < MIN_AVAILABLE_MESSAGES) {
    return true;
  }
  if (coverage.coverageRatio < MIN_COVERAGE_RATIO) {
    return true;
  }
  return false;
};

const formatCoverage = (value: number): string => value.toFixed(3);

const diagnosticBlock = (context: SummaryContext, coverage: MessageCoverageStats): string => {
  return [
    "```txt",
    "Summary withheld (fail-closed)",
    `totalMessages: ${coverage.totalMessages}`,
    `availableMessages: ${coverage.availableMessages}`,
    `unavailableMessages: ${coverage.unavailableMessages}`,
    `coverageRatio: ${formatCoverage(coverage.coverageRatio)}`,
    `timeRange: ${context.since} -> ${context.until}`,
    `channel: ${context.channelDisplay}`,
    "suggestion: Run /loki backfill scope:all and confirm Message Content intent is enabled.",
    "```",
  ].join("\n");
};

const noActivityResponse = (context: SummaryContext, attempts: WindowData[]): string => {
  const widest = attempts.length > 0 ? attempts[attempts.length - 1].windowHours : context.requestedWindowHours;
  const lines = attempts.map(
    (attempt) =>
      `- last ${attempt.windowHours}h: total=${attempt.coverage.totalMessages}, available=${attempt.coverage.availableMessages}, coverage=${formatCoverage(attempt.coverage.coverageRatio)}`,
  );

  return [
    `No activity in the last ${widest} hour(s) for this scope.`,
    `Scope: ${context.targetDisplay}`,
    `Checked windows (requested ${context.requestedWindowHours}h):`,
    ...lines,
    "Suggested next actions:",
    "- Run `/loki backfill scope:all` to refresh the local index.",
    "- If this should be active, verify bot permissions and Message Content intent.",
    "- Try `/loki search` for targeted keywords across older periods.",
  ].join("\n");
};

const buildAttachmentSection = (attachments: AttachmentLookupRow[]): string[] => {
  if (attachments.length === 0) {
    return ["- Count: 0"];
  }

  const preview = attachments.slice(0, 15).map((attachment) => {
    const name = attachment.filename ?? "unnamed";
    const type = attachment.content_type ?? "unknown";
    return `- ${name} | type=${type} | size=${attachment.size ?? 0} | ${attachment.url}`;
  });

  return [`- Count: ${attachments.length}`, ...preview];
};

const buildRepresentativeLines = (
  rows: MessageWindowRow[],
  userDisplayMap: ReadonlyMap<string, string>,
  channelDisplayMap: ReadonlyMap<string, string>,
): string[] => {
  const available = rows.filter(
    (row) => row.content_unavailable === 0 && row.content && compact(row.content).length > 0,
  );

  const desired = Math.min(
    MAX_REPRESENTATIVE_MESSAGES,
    Math.max(MIN_REPRESENTATIVE_MESSAGES, available.length),
  );

  return available.slice(0, desired).map((row) => {
    const author = userDisplayMap.get(row.author_id) ?? row.author_id;
    const channel = channelDisplayMap.get(row.channel_id) ?? row.channel_id;
    const excerpt = compact(row.content ?? "").slice(0, 180);
    const link = row.guild_id ? makeJumpLink(row.guild_id, row.channel_id, row.id) : "n/a";
    return `- ${row.created_at} | ${author} | ${channel} | message=${row.id}\n  snippet: ${excerpt}\n  jump: ${link}`;
  });
};

const buildSummarySection = (
  context: SummaryContext,
  coverage: MessageCoverageStats,
  terms: Array<{ term: string; count: number }>,
  authors: TopAuthor[],
  representativeCount: number,
  attachmentCount: number,
): string[] => {
  const termText =
    terms.length > 0
      ? terms
          .slice(0, 5)
          .map((term) => `${term.term} (${term.count})`)
          .join(", ")
      : "none";

  const authorText =
    authors.length > 0
      ? authors
          .slice(0, 3)
          .map((author) => `${author.display} (${author.count})`)
          .join(", ")
      : "none";

  return [
    `- Window analyzed: last ${context.selectedWindowHours}h (${context.since} -> ${context.until}).`,
    `- Content coverage: ${coverage.availableMessages}/${coverage.totalMessages} available messages (ratio ${formatCoverage(coverage.coverageRatio)}).`,
    `- Highest-frequency terms: ${termText}.`,
    `- Most active authors: ${authorText}.`,
    `- Representative evidence items: ${representativeCount} messages, ${attachmentCount} attachments.`,
  ];
};

const buildSuggestedNextActions = (context: SummaryContext, coverage: MessageCoverageStats): string[] => {
  const actions: string[] = [];

  if (coverage.coverageRatio < 0.8) {
    actions.push("- Improve coverage: enable Message Content intent and run `/loki backfill scope:all`.");
  }

  if (context.targetType === "channel") {
    actions.push("- Export evidence bundle if needed: `/loki export scope:channel format:json channel:<id>`.");
  } else {
    actions.push("- Export evidence bundle if needed: `/loki export scope:server format:json`.");
  }
  return actions;
};

const buildGroundedSummary = (
  context: SummaryContext,
  rows: MessageWindowRow[],
  coverage: MessageCoverageStats,
  userDisplayMap: ReadonlyMap<string, string>,
  channelDisplayMap: ReadonlyMap<string, string>,
  attachments: AttachmentLookupRow[],
): string => {
  const terms = topTerms(rows, 10);
  const authors = topAuthors(rows, userDisplayMap, 10);
  const representative = buildRepresentativeLines(rows, userDisplayMap, channelDisplayMap);
  const attachmentLines = buildAttachmentSection(attachments);

  return [
    "Header",
    `- Scope: ${context.targetDisplay}`,
    `- Time Range: ${context.since} -> ${context.until}`,
    `- Coverage: total=${coverage.totalMessages}, available=${coverage.availableMessages}, unavailable=${coverage.unavailableMessages}, ratio=${formatCoverage(coverage.coverageRatio)}`,
    "",
    "Evidence",
    `- Top terms: ${terms.length > 0 ? terms.map((term) => `${term.term} (${term.count})`).join(", ") : "none"}`,
    `- Top authors: ${authors.length > 0 ? authors.map((author) => `${author.display} (${author.count})`).join(", ") : "none"}`,
    "- Representative messages:",
    ...(representative.length > 0 ? representative : ["- none"]),
    "- Attachments:",
    ...attachmentLines,
    "",
    "Summary",
    ...buildSummarySection(context, coverage, terms, authors, representative.length, attachments.length),
    "",
    "Suggested next actions",
    ...buildSuggestedNextActions(context, coverage),
  ].join("\n");
};

const buildWindowCandidates = (requestedWindowHours: number): number[] => {
  const candidates = [requestedWindowHours];
  for (const step of WINDOW_EXPANSION_STEPS) {
    if (step >= requestedWindowHours) {
      candidates.push(step);
    }
  }
  const seen = new Set<number>();
  const ordered: number[] = [];
  for (const candidate of candidates) {
    if (seen.has(candidate)) {
      continue;
    }
    seen.add(candidate);
    ordered.push(candidate);
  }
  return ordered;
};

const collectChannelData = (
  db: LokiDb,
  channelId: string,
  requestedWindowHours: number,
  nowMs: number,
): WindowSearchResult => {
  const until = new Date(nowMs).toISOString();
  const attempts: WindowData[] = [];

  for (const hours of buildWindowCandidates(requestedWindowHours)) {
    const since = sinceIso(hours, nowMs);
    const rows = db.getChannelWindowMessages(channelId, since, until, SUMMARY_LIMIT);
    const coverage = db.getMessageCoverageStats({
      sinceIso: since,
      untilIso: until,
      channelId,
    });

    const data: WindowData = {
      windowHours: hours,
      since,
      until,
      rows,
      coverage,
    };

    attempts.push(data);
    if (coverage.totalMessages > 0) {
      return {
        selected: data,
        attempts,
      };
    }
  }

  return { attempts };
};

const collectUserData = (
  db: LokiDb,
  userId: string,
  requestedWindowHours: number,
  nowMs: number,
): WindowSearchResult => {
  const until = new Date(nowMs).toISOString();
  const attempts: WindowData[] = [];

  for (const hours of buildWindowCandidates(requestedWindowHours)) {
    const since = sinceIso(hours, nowMs);
    const rows = db.getUserWindowMessages(userId, since, until, SUMMARY_LIMIT);
    const coverage = db.getMessageCoverageStats({
      sinceIso: since,
      untilIso: until,
      userId,
    });

    const data: WindowData = {
      windowHours: hours,
      since,
      until,
      rows,
      coverage,
    };

    attempts.push(data);
    if (coverage.totalMessages > 0) {
      return {
        selected: data,
        attempts,
      };
    }
  }

  return { attempts };
};

const collectGuildData = (
  db: LokiDb,
  guildId: string,
  requestedWindowHours: number,
  nowMs: number,
): WindowSearchResult => {
  const until = new Date(nowMs).toISOString();
  const attempts: WindowData[] = [];

  for (const hours of buildWindowCandidates(requestedWindowHours)) {
    const since = sinceIso(hours, nowMs);
    const rows = db.getGuildWindowMessages(guildId, since, until, SUMMARY_LIMIT);
    const coverage = db.getMessageCoverageStats({
      sinceIso: since,
      untilIso: until,
      guildId,
    });

    const data: WindowData = {
      windowHours: hours,
      since,
      until,
      rows,
      coverage,
    };

    attempts.push(data);
    if (coverage.totalMessages > 0) {
      return {
        selected: data,
        attempts,
      };
    }
  }

  return { attempts };
};

const channelScopeLabel = (channelIds: string[], channelDisplayMap: ReadonlyMap<string, string>): string => {
  if (channelIds.length === 0) {
    return "unknown";
  }

  const labels = channelIds.slice(0, 5).map((id) => channelDisplayMap.get(id) ?? id);
  return labels.join(", ");
};

const summarizeEvidenceTerms = (rows: SearchRow[], prompt: string): string => {
  const promptTokens = new Set(tokenize(prompt));
  const counts = new Map<string, number>();

  for (const row of rows) {
    if (row.content_unavailable === 1 || !row.content) {
      continue;
    }
    for (const token of tokenize(row.content)) {
      if (promptTokens.has(token)) {
        continue;
      }
      counts.set(token, (counts.get(token) ?? 0) + 1);
    }
  }

  const terms = [...counts.entries()]
    .map(([term, count]) => ({ term, count }))
    .sort((a, b) => b.count - a.count || a.term.localeCompare(b.term))
    .slice(0, 5)
    .map((item) => `${item.term} (${item.count})`);

  return terms.length > 0 ? terms.join(", ") : "none";
};

const summarizeEvidenceAuthors = (
  rows: SearchRow[],
  userDisplayMap: ReadonlyMap<string, string>,
): string => {
  const counts = new Map<string, number>();
  for (const row of rows) {
    counts.set(row.author_id, (counts.get(row.author_id) ?? 0) + 1);
  }

  const authors = [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, 3)
    .map(([authorId, count]) => `${userDisplayMap.get(authorId) ?? authorId} (${count})`);

  return authors.length > 0 ? authors.join(", ") : "none";
};

const summarizeEvidenceChannels = (
  rows: SearchRow[],
  channelDisplayMap: ReadonlyMap<string, string>,
): string => {
  const counts = new Map<string, number>();
  for (const row of rows) {
    counts.set(row.channel_id, (counts.get(row.channel_id) ?? 0) + 1);
  }

  const channels = [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, 3)
    .map(([channelId, count]) => `${channelDisplayMap.get(channelId) ?? channelId} (${count})`);

  return channels.length > 0 ? channels.join(", ") : "none";
};

const buildSearchCitationLines = (
  rows: SearchRow[],
  userDisplayMap: ReadonlyMap<string, string>,
  channelDisplayMap: ReadonlyMap<string, string>,
): string[] => {
  return rows.map((row, index) => {
    const author = userDisplayMap.get(row.author_id) ?? row.author_id;
    const channel = channelDisplayMap.get(row.channel_id) ?? row.channel_id;
    const snippet = row.content_unavailable === 1
      ? "[content unavailable]"
      : compact(row.content ?? "").slice(0, 180) || "[no content]";
    const jump = row.guild_id ? makeJumpLink(row.guild_id, row.channel_id, row.id) : "n/a";
    return `[${index + 1}] ${row.created_at} | ${author} | ${channel} | ${snippet}\n  jump: ${jump}`;
  });
};

export class Analyzer {
  constructor(
    private readonly db: LokiDb,
    private readonly ollama: OllamaClient,
    private readonly defaultModel: string,
  ) {}

  async summarizeChannelWindow(input: {
    channelId: string;
    windowHours?: number;
    model?: string;
    ai: "on" | "off";
  }): Promise<AnalyzerResult> {
    const requestedWindowHours = clampWindowHours(input.windowHours);
    const nowMs = Date.now();
    const model = input.model ?? this.defaultModel;

    const channelMap = this.db.getChannelMap([input.channelId]);
    const channelLabel = channelMap.get(input.channelId)
      ? `${channelMap.get(input.channelId)!.name} (${input.channelId})`
      : input.channelId;

    const collected = collectChannelData(this.db, input.channelId, requestedWindowHours, nowMs);
    if (!collected.selected) {
      const context: SummaryContext = {
        targetType: "channel",
        targetId: input.channelId,
        targetDisplay: channelLabel,
        channelDisplay: channelLabel,
        requestedWindowHours,
        selectedWindowHours: requestedWindowHours,
        since: sinceIso(requestedWindowHours, nowMs),
        until: new Date(nowMs).toISOString(),
        model,
      };

      return {
        text: noActivityResponse(context, collected.attempts),
        aiUsed: false,
        model,
      };
    }

    const selected = collected.selected;
    const context: SummaryContext = {
      targetType: "channel",
      targetId: input.channelId,
      targetDisplay: channelLabel,
      channelDisplay: channelLabel,
      requestedWindowHours,
      selectedWindowHours: selected.windowHours,
      since: selected.since,
      until: selected.until,
      model,
    };

    if (shouldFailClosed(selected.coverage)) {
      return {
        text: diagnosticBlock(context, selected.coverage),
        aiUsed: false,
        model,
      };
    }

    const userIds = [...new Set(selected.rows.map((row) => row.author_id))];
    const userMap = this.db.getUserMap(userIds);
    const userDisplayMap = new Map(
      [...userMap.values()].map((row) => [
        row.id,
        `${row.global_name || row.username || row.id} (${row.id})`,
      ]),
    );

    const channelDisplayMap = new Map(
      [...channelMap.values()].map((row) => [row.id, `${row.name} (${row.id})`]),
    );

    const attachments = this.db.getAttachmentsForMessageIds(selected.rows.map((row) => row.id));

    return {
      text: buildGroundedSummary(
        context,
        selected.rows,
        selected.coverage,
        userDisplayMap,
        channelDisplayMap,
        attachments,
      ),
      aiUsed: false,
      model,
    };
  }

  async summarizeUserCase(input: {
    userId: string;
    windowHours?: number;
    model?: string;
    ai: "on" | "off";
  }): Promise<AnalyzerResult> {
    const requestedWindowHours = clampWindowHours(input.windowHours);
    const nowMs = Date.now();
    const model = input.model ?? this.defaultModel;

    const userMap = this.db.getUserMap([input.userId]);
    const userLabel = userMap.get(input.userId)
      ? `${userMap.get(input.userId)!.global_name || userMap.get(input.userId)!.username || input.userId} (${input.userId})`
      : input.userId;

    const collected = collectUserData(this.db, input.userId, requestedWindowHours, nowMs);
    if (!collected.selected) {
      const context: SummaryContext = {
        targetType: "user",
        targetId: input.userId,
        targetDisplay: userLabel,
        channelDisplay: "multiple (user scope)",
        requestedWindowHours,
        selectedWindowHours: requestedWindowHours,
        since: sinceIso(requestedWindowHours, nowMs),
        until: new Date(nowMs).toISOString(),
        model,
      };

      return {
        text: noActivityResponse(context, collected.attempts),
        aiUsed: false,
        model,
      };
    }

    const selected = collected.selected;
    const channelIds = [...new Set(selected.rows.map((row) => row.channel_id))];
    const channelMap = this.db.getChannelMap(channelIds);
    const channelDisplayMap = new Map(
      [...channelMap.values()].map((row) => [row.id, `${row.name} (${row.id})`]),
    );

    const context: SummaryContext = {
      targetType: "user",
      targetId: input.userId,
      targetDisplay: userLabel,
      channelDisplay: channelScopeLabel(channelIds, channelDisplayMap),
      requestedWindowHours,
      selectedWindowHours: selected.windowHours,
      since: selected.since,
      until: selected.until,
      model,
    };

    if (shouldFailClosed(selected.coverage)) {
      return {
        text: diagnosticBlock(context, selected.coverage),
        aiUsed: false,
        model,
      };
    }

    const userDisplayMap = new Map(
      [...userMap.values()].map((row) => [
        row.id,
        `${row.global_name || row.username || row.id} (${row.id})`,
      ]),
    );
    if (!userDisplayMap.has(input.userId)) {
      userDisplayMap.set(input.userId, input.userId);
    }

    const attachments = this.db.getAttachmentsForMessageIds(selected.rows.map((row) => row.id));

    return {
      text: buildGroundedSummary(
        context,
        selected.rows,
        selected.coverage,
        userDisplayMap,
        channelDisplayMap,
        attachments,
      ),
      aiUsed: false,
      model,
    };
  }

  async summarizeGuildWindow(input: {
    guildId: string;
    windowHours?: number;
    model?: string;
    ai: "on" | "off";
  }): Promise<AnalyzerResult> {
    const requestedWindowHours = clampWindowHours(input.windowHours);
    const nowMs = Date.now();
    const model = input.model ?? this.defaultModel;

    const collected = collectGuildData(this.db, input.guildId, requestedWindowHours, nowMs);
    const guildLabel = `guild:${input.guildId}`;
    if (!collected.selected) {
      const context: SummaryContext = {
        targetType: "server",
        targetId: input.guildId,
        targetDisplay: guildLabel,
        channelDisplay: "multiple (server scope)",
        requestedWindowHours,
        selectedWindowHours: requestedWindowHours,
        since: sinceIso(requestedWindowHours, nowMs),
        until: new Date(nowMs).toISOString(),
        model,
      };

      return {
        text: noActivityResponse(context, collected.attempts),
        aiUsed: false,
        model,
      };
    }

    const selected = collected.selected;
    const channelIds = [...new Set(selected.rows.map((row) => row.channel_id))];
    const channelMap = this.db.getChannelMap(channelIds);
    const channelDisplayMap = new Map(
      [...channelMap.values()].map((row) => [row.id, `${row.name} (${row.id})`]),
    );

    const userIds = [...new Set(selected.rows.map((row) => row.author_id))];
    const userMap = this.db.getUserMap(userIds);
    const userDisplayMap = new Map(
      [...userMap.values()].map((row) => [
        row.id,
        `${row.global_name || row.username || row.id} (${row.id})`,
      ]),
    );

    const context: SummaryContext = {
      targetType: "server",
      targetId: input.guildId,
      targetDisplay: guildLabel,
      channelDisplay: channelScopeLabel(channelIds, channelDisplayMap),
      requestedWindowHours,
      selectedWindowHours: selected.windowHours,
      since: selected.since,
      until: selected.until,
      model,
    };

    if (shouldFailClosed(selected.coverage)) {
      return {
        text: diagnosticBlock(context, selected.coverage),
        aiUsed: false,
        model,
      };
    }

    const attachments = this.db.getAttachmentsForMessageIds(selected.rows.map((row) => row.id));

    return {
      text: buildGroundedSummary(
        context,
        selected.rows,
        selected.coverage,
        userDisplayMap,
        channelDisplayMap,
        attachments,
      ),
      aiUsed: false,
      model,
    };
  }

  async answerFromSearchEvidence(input: {
    prompt: string;
    scope: "channel" | "server";
    guildId?: string;
    channelId?: string;
    windowHours?: number;
    model?: string;
  }): Promise<AnalyzerResult> {
    const model = input.model ?? this.defaultModel;
    const requestedWindowHours = clampWindowHours(input.windowHours);
    const nowMs = Date.now();
    const since = sinceIso(requestedWindowHours, nowMs);
    const until = new Date(nowMs).toISOString();

    const rows = this.db.searchMessages({
      query: input.prompt,
      guildId: input.scope === "server" ? input.guildId : undefined,
      channelId: input.scope === "channel" ? input.channelId : undefined,
      since,
      until,
      limit: ANSWER_EVIDENCE_LIMIT,
    });

    const scopeLabel = input.scope === "channel"
      ? `channel:${input.channelId ?? "unknown"}`
      : `guild:${input.guildId ?? "unknown"}`;

    if (rows.length === 0) {
      return {
        text: [
          "No indexed evidence matched this request.",
          `Scope: ${scopeLabel}`,
          `Window: last ${requestedWindowHours}h (${since} -> ${until})`,
          "Try refining keywords, widening the window, or running `/loki backfill scope:all`.",
        ].join("\n"),
        aiUsed: false,
        model,
      };
    }

    const readableRows = rows.filter(
      (row) => row.content_unavailable === 0 && row.content && compact(row.content).length > 0,
    );

    if (readableRows.length === 0) {
      return {
        text: [
          "Answer withheld (fail-closed): matching messages exist, but readable content is unavailable.",
          `Scope: ${scopeLabel}`,
          `Window: last ${requestedWindowHours}h (${since} -> ${until})`,
          `Matches: ${rows.length}, readable: 0`,
          "Suggestion: enable Message Content intent, run `/loki backfill scope:all`, then retry.",
        ].join("\n"),
        aiUsed: false,
        model,
      };
    }

    const userIds = [...new Set(rows.map((row) => row.author_id))];
    const channelIds = [...new Set(rows.map((row) => row.channel_id))];
    const userMap = this.db.getUserMap(userIds);
    const channelMap = this.db.getChannelMap(channelIds);

    const userDisplayMap = new Map(
      [...userMap.values()].map((row) => [
        row.id,
        `${row.global_name || row.username || row.id} (${row.id})`,
      ]),
    );

    const channelDisplayMap = new Map(
      [...channelMap.values()].map((row) => [row.id, `${row.name} (${row.id})`]),
    );

    const topTermsText = summarizeEvidenceTerms(readableRows, input.prompt);
    const topAuthorsText = summarizeEvidenceAuthors(readableRows, userDisplayMap);
    const topChannelsText = summarizeEvidenceChannels(readableRows, channelDisplayMap);
    const citations = buildSearchCitationLines(
      rows.slice(0, Math.min(12, rows.length)),
      userDisplayMap,
      channelDisplayMap,
    );

    return {
      text: [
        "Answer (grounded in local evidence)",
        `- Request: ${input.prompt}`,
        `- Scope: ${scopeLabel}`,
        `- Window: last ${requestedWindowHours}h (${since} -> ${until})`,
        `- Evidence: ${rows.length} matching messages, ${readableRows.length} with readable content.`,
        `- Dominant themes in matching evidence: ${topTermsText}.`,
        `- Most active authors in matching evidence: ${topAuthorsText}.`,
        `- Channels most represented in evidence: ${topChannelsText}.`,
        "",
        "Citations",
        ...citations,
      ].join("\n"),
      aiUsed: false,
      model,
    };
  }

  async draftReplyToMessage(input: {
    messageId: string;
    model?: string;
    ai: "on" | "off";
  }): Promise<AnalyzerResult> {
    const source = this.db.getMessageById(input.messageId);
    const model = input.model ?? this.defaultModel;

    if (!source) {
      return {
        text: `Message ${input.messageId} not found in local index.`,
        aiUsed: false,
        model,
      };
    }

    const context = this.db
      .getMessagesForChannelWindow(source.channel_id, new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString(), 40)
      .filter((row) => row.id !== source.id)
      .slice(0, 15);

    if (input.ai === "off") {
      const draft = `Thanks for the context. I reviewed your message and will follow up with details shortly.`;
      return {
        text: `${draft}\n\n[AI disabled: deterministic draft generated locally.]`,
        aiUsed: false,
        model,
      };
    }

    try {
      const prompt = buildDraftReplyPrompt(source, context);
      const text = await this.ollama.chat({
        model,
        messages: [{ role: "user", content: prompt }],
      });
      return { text, aiUsed: true, model };
    } catch (error) {
      const reason = error instanceof Error ? error.message : "unknown error";
      return {
        text:
          "Thanks for the message. I can help with this and will provide next steps shortly." +
          `\n\nOllama unavailable: ${reason}`,
        aiUsed: false,
        model,
      };
    }
  }
}
