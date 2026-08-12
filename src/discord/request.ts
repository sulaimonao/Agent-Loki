import { makeJumpLink } from "../ai/analyzer";
import type {
  AttachmentLookupRow,
  ChannelLookupRow,
  LokiDb,
  MessageCoverageStats,
  MessageWindowRow,
  UserLookupRow,
} from "../storage/db";

const SMART_WINDOWS_HOURS = [24, 168, 720] as const;
const DEFAULT_RECENT_READABLE_LIMITS = [300, 1000, 5000] as const;
const MAX_EXPLICIT_RECENT_READABLE_LIMIT = 20000;
const MAX_WINDOW_HOURS = 720;
const REQUEST_LIMIT = 1200;
const MAX_REPORT_SOURCE_ROWS = 8;
const MAX_CHAT_SOURCE_ROWS = 5;
const MAX_ATTACHMENT_ROWS = 20;
const MIN_SIGNAL_TEXT_LENGTH = 4;
const SHORT_PROMPT_WORD_THRESHOLD = 2;
const SHORT_PROMPT_CHAR_THRESHOLD = 12;

type RetrievalStrategy = "recent_count" | "time_window";
type StrategyReason = "explicit_window" | "prompt_time_language" | "default_recent_count";

const TIME_LANGUAGE_PATTERN =
  /\b(today|yesterday|tonight|now|currently|recently|this (morning|afternoon|evening|week|month|year)|last (hour|day|week|month|year)|past \d+\s*(hours?|days?|weeks?|months?|years?)|in the last|over the last|since|between|before|after|\d+\s*(h|hr|hrs|hours?|d|days?|w|weeks?|m|months?|y|years?))\b/i;
const ABSOLUTE_DATE_PATTERN = /\b\d{4}-\d{2}-\d{2}\b/;
const CALENDAR_DATE_PATTERN =
  /\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2}(?:,\s*\d{4})?\b/i;
const GREETING_OR_META_ONLY_PATTERN =
  /^(hi|hello|hey|yo|howdy|hiya|sup|gm|gn|good (morning|afternoon|evening)|thanks|thank you|thx|ty|good bot|how are you|who are you|what can you do|what do you do|help|are you there|ping|test)(?:[!?.\s]+)?$/i;
const SHORT_ACK_ONLY_PATTERN =
  /^(ok(?:ay)?|k+|yes|yep|yup|no|nah|lol|lmao|rofl|done|same|sgtm|cool|nice|great|sounds good|looks good|got it|\+1|bump)(?:[!?.\s]+)?$/i;

export type RequestScopeOption = "here" | "channel" | "server";
export type RequestResponseStyle = "report" | "chat";

export interface RequestWorkflowContext {
  db: LokiDb;
  defaultModel: string;
}

export interface RequestWorkflowInput {
  prompt: string;
  scope: RequestScopeOption;
  guildId?: string;
  channelId?: string;
  excludeMessageIds?: string[];
  windowHours?: number;
  recentReadableLimit?: number;
  model?: string;
  ai: "on" | "off";
  nowMs?: number;
  responseStyle?: RequestResponseStyle;
  includeDiagnostics?: boolean;
}

export interface RequestWorkflowResult {
  text: string;
  reportPrefix: string;
}

interface TimeAttempt {
  windowHours: number;
  since: string;
  until: string;
  rows: MessageWindowRow[];
  coverage: MessageCoverageStats;
}

interface CountAttempt {
  limit: number;
  rows: MessageWindowRow[];
  promptMatches: number;
}

const compact = (value: string): string => value.replace(/\s+/g, " ").trim();

const clampWindowHours = (windowHours?: number): number | undefined => {
  if (windowHours === undefined || Number.isNaN(windowHours)) {
    return undefined;
  }
  return Math.min(Math.max(windowHours, 1), MAX_WINDOW_HOURS);
};

const clampRecentReadableLimit = (limit?: number): number | undefined => {
  if (limit === undefined || Number.isNaN(limit)) {
    return undefined;
  }
  return Math.min(Math.max(limit, 1), MAX_EXPLICIT_RECENT_READABLE_LIMIT);
};

const resolveRecentReadableLimits = (requestedLimit?: number): number[] => {
  const explicitLimit = clampRecentReadableLimit(requestedLimit);
  if (explicitLimit === undefined) {
    return [...DEFAULT_RECENT_READABLE_LIMITS];
  }

  const candidates = [
    ...DEFAULT_RECENT_READABLE_LIMITS.filter((limit) => limit <= explicitLimit),
    explicitLimit,
  ];
  return [...new Set(candidates)].sort((a, b) => a - b);
};

const tokenizePrompt = (prompt: string): string[] => {
  const tokens = prompt.toLowerCase().match(/[a-z0-9']+/g) ?? [];
  return [...new Set(tokens.filter((token) => token.length >= 3))];
};

const formatUser = (row: UserLookupRow | undefined, fallbackId: string): string => {
  if (!row) {
    return fallbackId;
  }
  return row.global_name || row.username || fallbackId;
};

const formatChannel = (row: ChannelLookupRow | undefined, fallbackId: string): string => {
  if (!row) {
    return fallbackId;
  }
  return row.name || fallbackId;
};

const truncate = (value: string, max: number): string => {
  if (value.length <= max) {
    return value;
  }
  return `${value.slice(0, max - 3)}...`;
};

const sinceIso = (windowHours: number, nowMs: number): string => {
  return new Date(nowMs - windowHours * 60 * 60 * 1000).toISOString();
};

const hasPromptTimeLanguage = (prompt: string): boolean => {
  return (
    TIME_LANGUAGE_PATTERN.test(prompt) ||
    ABSOLUTE_DATE_PATTERN.test(prompt) ||
    CALENDAR_DATE_PATTERN.test(prompt)
  );
};

const resolveStrategy = (input: RequestWorkflowInput): { strategy: RetrievalStrategy; reason: StrategyReason } => {
  if (clampWindowHours(input.windowHours) !== undefined) {
    return { strategy: "time_window", reason: "explicit_window" };
  }

  if (hasPromptTimeLanguage(input.prompt)) {
    return { strategy: "time_window", reason: "prompt_time_language" };
  }

  return { strategy: "recent_count", reason: "default_recent_count" };
};

const formatStrategyReason = (reason: StrategyReason): string => {
  if (reason === "explicit_window") {
    return "explicit window requested";
  }
  if (reason === "prompt_time_language") {
    return "prompt contains time language";
  }
  return "default recent-by-count";
};

const getTimeCandidates = (windowHours?: number): number[] => {
  const clamped = clampWindowHours(windowHours);
  if (clamped !== undefined) {
    return [clamped];
  }
  return [...SMART_WINDOWS_HOURS];
};

const buildScopeLabel = (input: RequestWorkflowInput): string => {
  if (input.scope === "server") {
    return `guild:${input.guildId ?? "unknown"}`;
  }

  return `channel:${input.channelId ?? "unknown"}`;
};

const collectTimeAttempt = (
  db: LokiDb,
  input: RequestWorkflowInput,
  windowHours: number,
  nowMs: number,
): TimeAttempt => {
  const since = sinceIso(windowHours, nowMs);
  const until = new Date(nowMs).toISOString();

  if (input.scope === "server") {
    if (!input.guildId) {
      throw new Error("Server scope requires guildId.");
    }

    const rows = db.getGuildWindowMessages(input.guildId, since, until, REQUEST_LIMIT);
    const coverage = db.getMessageCoverageStats({
      sinceIso: since,
      untilIso: until,
      guildId: input.guildId,
    });

    return { windowHours, since, until, rows, coverage };
  }

  if (!input.channelId) {
    throw new Error("Channel scope requires channelId.");
  }

  const rows = db.getChannelWindowMessages(input.channelId, since, until, REQUEST_LIMIT);
  const coverage = db.getMessageCoverageStats({
    sinceIso: since,
    untilIso: until,
    channelId: input.channelId,
  });

  return { windowHours, since, until, rows, coverage };
};

const collectReadableCountRows = (
  db: LokiDb,
  input: RequestWorkflowInput,
  limit: number,
): MessageWindowRow[] => {
  if (input.scope === "server") {
    if (!input.guildId) {
      throw new Error("Server scope requires guildId.");
    }
    return db.getRecentReadableMessagesByGuild(input.guildId, limit);
  }

  if (!input.channelId) {
    throw new Error("Channel scope requires channelId.");
  }
  return db.getRecentReadableMessagesByChannel(input.channelId, limit);
};

const formatTimeWindowDiagnostics = (attempts: TimeAttempt[]): string[] => {
  return attempts.map(
    (attempt) =>
      `- last ${attempt.windowHours}h: total=${attempt.coverage.totalMessages}, available=${attempt.coverage.availableMessages}, unavailable=${attempt.coverage.unavailableMessages}`,
  );
};

const formatCountDiagnostics = (attempts: CountAttempt[]): string[] => {
  return attempts.map(
    (attempt) =>
      `- latest ${attempt.limit} readable: rows=${attempt.rows.length}, prompt_matches=${attempt.promptMatches}`,
  );
};

const countTop = (
  values: string[],
  toLabel: (id: string) => string,
  limit: number,
): string => {
  const counts = new Map<string, number>();
  for (const value of values) {
    counts.set(value, (counts.get(value) ?? 0) + 1);
  }

  const items = [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, limit)
    .map(([id, count]) => `${toLabel(id)} (${count})`);

  return items.length > 0 ? items.join(", ") : "none";
};

const rankEvidenceRows = (rows: MessageWindowRow[], prompt: string): MessageWindowRow[] => {
  const promptTokens = tokenizePrompt(prompt);
  if (promptTokens.length === 0) {
    return rows;
  }

  const scoreRow = (row: MessageWindowRow): number => {
    const content = row.content?.toLowerCase() ?? "";
    let score = 0;
    for (const token of promptTokens) {
      if (content.includes(token)) {
        score += 1;
      }
    }
    return score;
  };

  return [...rows].sort((a, b) => {
    const diff = scoreRow(b) - scoreRow(a);
    if (diff !== 0) {
      return diff;
    }
    return b.created_at.localeCompare(a.created_at);
  });
};

const countPromptMatches = (rows: MessageWindowRow[], promptTokens: string[]): number => {
  if (promptTokens.length === 0) {
    return 0;
  }

  let matches = 0;
  for (const row of rows) {
    const content = row.content?.toLowerCase() ?? "";
    if (promptTokens.some((token) => content.includes(token))) {
      matches += 1;
    }
  }
  return matches;
};

const shouldAllowShortEvidence = (prompt: string): boolean => {
  const normalized = compact(prompt);
  if (!normalized) {
    return true;
  }

  const wordCount = normalized.match(/[\p{L}\p{N}']+/gu)?.length ?? 0;
  return wordCount <= SHORT_PROMPT_WORD_THRESHOLD || normalized.length <= SHORT_PROMPT_CHAR_THRESHOLD;
};

const stripLowSignalTokens = (content: string): string => {
  return content
    .replace(/<a?:[a-zA-Z0-9_]+:\d+>/g, " ")
    .replace(/<[@#][!&]?\d+>/g, " ")
    .replace(/[\p{Extended_Pictographic}\u200D\uFE0F]/gu, " ")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
};

const isLowSignalEvidenceMessage = (content: string, allowShortEvidence: boolean): boolean => {
  if (GREETING_OR_META_ONLY_PATTERN.test(content) || SHORT_ACK_ONLY_PATTERN.test(content)) {
    return true;
  }

  const signal = stripLowSignalTokens(content);
  if (!signal) {
    return true;
  }

  if (!allowShortEvidence && signal.length < MIN_SIGNAL_TEXT_LENGTH) {
    return true;
  }

  if (!allowShortEvidence) {
    const tokenCount = signal.match(/[\p{L}\p{N}']+/gu)?.length ?? 0;
    if (tokenCount <= 2 && signal.length <= 12) {
      return true;
    }
  }

  return false;
};

const filterReadableEvidenceRows = (
  rows: MessageWindowRow[],
  allowShortEvidence: boolean,
): MessageWindowRow[] => {
  return rows.filter((row) => {
    if (row.content_unavailable !== 0 || row.content === null) {
      return false;
    }

    const normalized = compact(row.content);
    if (!normalized) {
      return false;
    }

    return !isLowSignalEvidenceMessage(normalized, allowShortEvidence);
  });
};

const filterExcludedMessageRows = (
  rows: MessageWindowRow[],
  excludedMessageIds: string[] | undefined,
): MessageWindowRow[] => {
  if (!excludedMessageIds || excludedMessageIds.length === 0) {
    return rows;
  }

  const excluded = new Set(excludedMessageIds.filter(Boolean));
  if (excluded.size === 0) {
    return rows;
  }

  return rows.filter((row) => !excluded.has(row.id));
};

const formatReportSourceLines = (
  rows: MessageWindowRow[],
  userMap: ReadonlyMap<string, UserLookupRow>,
  channelMap: ReadonlyMap<string, ChannelLookupRow>,
): string[] => {
  return rows.map((row, index) => {
    const author = formatUser(userMap.get(row.author_id), row.author_id);
    const channel = formatChannel(channelMap.get(row.channel_id), row.channel_id);
    const excerpt = truncate(compact(row.content ?? ""), 220);
    const jump = row.guild_id ? makeJumpLink(row.guild_id, row.channel_id, row.id) : "n/a";
    return `${index + 1}. ${row.created_at} | ${author} | ${channel}\n   excerpt: ${excerpt}\n   jump: ${jump}`;
  });
};

const formatChatSourceLines = (
  rows: MessageWindowRow[],
  userMap: ReadonlyMap<string, UserLookupRow>,
  channelMap: ReadonlyMap<string, ChannelLookupRow>,
): string[] => {
  if (rows.length === 0) {
    return ["- none"];
  }

  return rows.map((row, index) => {
    const author = formatUser(userMap.get(row.author_id), row.author_id);
    const channel = formatChannel(channelMap.get(row.channel_id), row.channel_id);
    const excerpt = truncate(compact(row.content ?? ""), 180);
    const jump = row.guild_id ? makeJumpLink(row.guild_id, row.channel_id, row.id) : "n/a";
    return `${index + 1}. ${jump} | ${author} | ${channel} | ${excerpt}`;
  });
};

const formatAttachmentLines = (
  attachments: AttachmentLookupRow[],
  evidenceRows: MessageWindowRow[],
): string[] => {
  if (attachments.length === 0) {
    return ["- none"];
  }

  const byMessageId = new Map(evidenceRows.map((row) => [row.id, row]));
  const lines = attachments.slice(0, MAX_ATTACHMENT_ROWS).map((attachment) => {
    const message = byMessageId.get(attachment.message_id);
    const jump = message?.guild_id
      ? makeJumpLink(message.guild_id, message.channel_id, message.id)
      : "n/a";
    return `- ${attachment.filename ?? "unnamed"} | content_type=${attachment.content_type ?? "unknown"} | size=${attachment.size ?? 0} | message: ${jump}`;
  });

  if (attachments.length > MAX_ATTACHMENT_ROWS) {
    lines.push(`- ... ${attachments.length - MAX_ATTACHMENT_ROWS} more attachment(s) omitted`);
  }

  return lines;
};

const safeFilePart = (value: string): string => value.replace(/[^a-zA-Z0-9_-]/g, "_");

const withOptionalDiagnostics = (
  baseLines: string[],
  includeDiagnostics: boolean,
  diagnosticsLines: string[],
): string => {
  if (!includeDiagnostics) {
    return baseLines.join("\n");
  }

  return [...baseLines, "", "Diagnostics", ...diagnosticsLines].join("\n");
};

const buildReportPrefix = (input: RequestWorkflowInput): string => {
  if (input.scope === "server") {
    return `loki_request_server_${safeFilePart(input.guildId ?? "unknown")}`;
  }
  return `loki_request_channel_${safeFilePart(input.channelId ?? "unknown")}`;
};

const noActivityText = (
  input: RequestWorkflowInput,
  scopeLabel: string,
  responseStyle: RequestResponseStyle,
  includeDiagnostics: boolean,
  strategyReportLine: string,
  strategyChatSentence: string,
  diagnostics: string[],
): string => {
  if (responseStyle === "chat") {
    return withOptionalDiagnostics(
      [
        `${strategyChatSentence} I could not find indexed activity for this request yet.`,
        "",
        "Sources",
        "- none",
      ],
      includeDiagnostics,
      [
        `- Scope: ${scopeLabel}`,
        `- Prompt: ${input.prompt}`,
        ...diagnostics,
        "- No evidence rows were returned from the local DB for this strategy.",
      ],
    );
  }

  return withOptionalDiagnostics(
    [
      "No activity found for this request.",
      strategyReportLine,
      "",
      "Try this next",
      "- Try `scope:server` to search across all channels.",
      "- Run `/loki backfill scope:all` to index older history.",
      "- Ask from a more active channel or refine your request.",
    ],
    includeDiagnostics,
    [
      `- Scope: ${scopeLabel}`,
      `- Prompt: ${input.prompt}`,
      ...diagnostics,
      "- No evidence rows were returned from the local DB for this strategy.",
    ],
  );
};

const unreadableActivityText = (
  input: RequestWorkflowInput,
  scopeLabel: string,
  responseStyle: RequestResponseStyle,
  includeDiagnostics: boolean,
  strategyReportLine: string,
  strategyChatSentence: string,
  diagnostics: string[],
): string => {
  if (responseStyle === "chat") {
    return withOptionalDiagnostics(
      [
        `${strategyChatSentence} I found indexed activity, but no readable content is available yet.`,
        "",
        "Sources",
        "- none",
      ],
      includeDiagnostics,
      [
        `- Scope: ${scopeLabel}`,
        `- Prompt: ${input.prompt}`,
        strategyReportLine,
        ...diagnostics,
        "- Indexed rows exist, but all rows are content-unavailable or empty.",
      ],
    );
  }

  return withOptionalDiagnostics(
    ["Activity exists, but readable content is unavailable for this request.", strategyReportLine],
    includeDiagnostics,
    [
      `- Scope: ${scopeLabel}`,
      `- Prompt: ${input.prompt}`,
      ...diagnostics,
      "- Indexed rows exist, but all rows are content-unavailable or empty.",
    ],
  );
};

export const runConversationalRequest = async (
  ctx: RequestWorkflowContext,
  input: RequestWorkflowInput,
): Promise<RequestWorkflowResult> => {
  const nowMs = input.nowMs ?? Date.now();
  const scopeLabel = buildScopeLabel(input);
  const responseStyle = input.responseStyle ?? "report";
  const includeDiagnostics = input.includeDiagnostics ?? responseStyle === "report";

  const strategyResolved = resolveStrategy(input);
  const strategyReasonLabel = formatStrategyReason(strategyResolved.reason);
  const allowShortEvidence = shouldAllowShortEvidence(input.prompt);
  const lowSignalFilterLine = allowShortEvidence
    ? "- Low-signal filter: allow short replies (short prompt)."
    : "- Low-signal filter: exclude mention/emoji-only and very short replies.";

  let readableRows: MessageWindowRow[] = [];
  let strategyReportLine = "";
  let strategyChatSentence = "";
  let retrievalDiagnostics: string[] = [];
  let selectedTimeWindowHours: number | undefined;
  let selectedTimeSince: string | undefined;
  let selectedTimeUntil: string | undefined;
  let selectedCountLimit: number | undefined;

  if (strategyResolved.strategy === "time_window") {
    const attempts: TimeAttempt[] = [];
    let selected: TimeAttempt | undefined;

    for (const windowHours of getTimeCandidates(input.windowHours)) {
      const attempt = collectTimeAttempt(ctx.db, input, windowHours, nowMs);
      attempts.push(attempt);

      if (attempt.coverage.availableMessages > 0) {
        selected = attempt;
        break;
      }
    }

    const selectedWindowForMessage = selected?.windowHours ?? attempts[0]?.windowHours ?? 24;
    strategyReportLine = `Evidence strategy: time-window (last ${selectedWindowForMessage}h).`;
    strategyChatSentence = `I used a time-window search over the last ${selectedWindowForMessage}h.`;
    retrievalDiagnostics = [
      `- Strategy: time-window (${strategyReasonLabel})`,
      lowSignalFilterLine,
      ...formatTimeWindowDiagnostics(attempts),
    ];

    if (!selected) {
      if (attempts.some((attempt) => attempt.coverage.totalMessages > 0)) {
        return {
          text: unreadableActivityText(
            input,
            scopeLabel,
            responseStyle,
            includeDiagnostics,
            strategyReportLine,
            strategyChatSentence,
            retrievalDiagnostics,
          ),
          reportPrefix: buildReportPrefix(input),
        };
      }

      return {
        text: noActivityText(
          input,
          scopeLabel,
          responseStyle,
          includeDiagnostics,
          strategyReportLine,
          strategyChatSentence,
          retrievalDiagnostics,
        ),
        reportPrefix: buildReportPrefix(input),
      };
    }

    selectedTimeWindowHours = selected.windowHours;
    selectedTimeSince = selected.since;
    selectedTimeUntil = selected.until;
    readableRows = rankEvidenceRows(filterReadableEvidenceRows(selected.rows, allowShortEvidence), input.prompt);
  } else {
    const promptTokens = tokenizePrompt(input.prompt);
    const countCandidates = resolveRecentReadableLimits(input.recentReadableLimit);
    const attempts: CountAttempt[] = [];
    let selectedRows: MessageWindowRow[] | undefined;
    let selectedLimit: number | undefined;

    for (const limit of countCandidates) {
      const rows = rankEvidenceRows(
        filterReadableEvidenceRows(collectReadableCountRows(ctx.db, input, limit), allowShortEvidence),
        input.prompt,
      );
      const promptMatches = countPromptMatches(rows, promptTokens);
      attempts.push({ limit, rows, promptMatches });

      if (rows.length === 0) {
        continue;
      }

      selectedRows = rows;
      selectedLimit = limit;

      const hasMoreRows = rows.length >= limit;
      if (promptTokens.length === 0 || promptMatches > 0 || !hasMoreRows) {
        break;
      }
    }

    const selectedLimitForMessage = selectedLimit ?? countCandidates[countCandidates.length - 1];
    selectedCountLimit = selectedLimit;
    strategyReportLine =
      `Evidence strategy: recent-by-count (latest ${selectedLimitForMessage} readable messages).`;
    strategyChatSentence =
      `I used recent-by-count evidence from the latest ${selectedLimitForMessage} readable messages.`;
    retrievalDiagnostics = [
      `- Strategy: recent-by-count (${strategyReasonLabel})`,
      lowSignalFilterLine,
      ...formatCountDiagnostics(attempts),
    ];

    if (!selectedRows || selectedRows.length === 0) {
      return {
        text: noActivityText(
          input,
          scopeLabel,
          responseStyle,
          includeDiagnostics,
          strategyReportLine,
          strategyChatSentence,
          retrievalDiagnostics,
        ),
        reportPrefix: buildReportPrefix(input),
      };
    }

    readableRows = selectedRows;
  }

  if (readableRows.length === 0) {
    return {
      text: noActivityText(
        input,
        scopeLabel,
        responseStyle,
        includeDiagnostics,
        strategyReportLine,
        strategyChatSentence,
        retrievalDiagnostics,
      ),
      reportPrefix: buildReportPrefix(input),
    };
  }

  readableRows = filterExcludedMessageRows(readableRows, input.excludeMessageIds);
  if (readableRows.length === 0) {
    return {
      text: noActivityText(
        input,
        scopeLabel,
        responseStyle,
        includeDiagnostics,
        strategyReportLine,
        strategyChatSentence,
        retrievalDiagnostics,
      ),
      reportPrefix: buildReportPrefix(input),
    };
  }

  const reportEvidenceRows = readableRows.slice(0, MAX_REPORT_SOURCE_ROWS);
  const userMap = ctx.db.getUserMap([...new Set(readableRows.map((row) => row.author_id))]);
  const channelMap = ctx.db.getChannelMap([...new Set(readableRows.map((row) => row.channel_id))]);
  const attachments = ctx.db.getAttachmentsForMessageIds(reportEvidenceRows.map((row) => row.id));

  const promptTokens = tokenizePrompt(input.prompt);
  const promptMatchRows = readableRows.filter((row) => {
    if (promptTokens.length === 0) {
      return false;
    }
    const content = row.content?.toLowerCase() ?? "";
    return promptTokens.some((token) => content.includes(token));
  });
  const promptMatches = promptMatchRows.length;

  const topAuthors = countTop(
    readableRows.map((row) => row.author_id),
    (id) => formatUser(userMap.get(id), id),
    3,
  );
  const topChannels = countTop(
    readableRows.map((row) => row.channel_id),
    (id) => formatChannel(channelMap.get(id), id),
    3,
  );

  const diagnosticsLines = [
    `- Scope: ${scopeLabel}`,
    `- Prompt: ${input.prompt}`,
    strategyReportLine,
    ...retrievalDiagnostics,
    ...(selectedTimeWindowHours !== undefined && selectedTimeSince && selectedTimeUntil
      ? [`- Time window used: last ${selectedTimeWindowHours}h (${selectedTimeSince} -> ${selectedTimeUntil})`]
      : []),
    ...(selectedCountLimit !== undefined
      ? [`- Count limit used: ${selectedCountLimit}`]
      : []),
    `- AI mode requested: ${input.ai}`,
    `- Model selected: ${input.model ?? ctx.defaultModel}`,
  ];

  if (responseStyle === "chat") {
    const chatEvidenceRows = readableRows.slice(0, MAX_CHAT_SOURCE_ROWS);
    const highlight = (promptMatchRows.length > 0 ? promptMatchRows : readableRows)[0];
    const author = formatUser(userMap.get(highlight.author_id), highlight.author_id);
    const snippet = truncate(compact(highlight.content ?? ""), 180);
    const answer =
      promptMatches > 0
        ? `${author} said: "${snippet}". ${strategyChatSentence}`
        : `I did not find direct keyword matches, so I used the strongest recent evidence: ${author} said "${snippet}". ${strategyChatSentence}`;

    return {
      text: withOptionalDiagnostics(
        [answer, "", "Sources", ...formatChatSourceLines(chatEvidenceRows, userMap, channelMap)],
        includeDiagnostics,
        diagnosticsLines,
      ),
      reportPrefix: buildReportPrefix(input),
    };
  }

  const conversationalSummary = [
    `Here is what I found for: "${input.prompt}"`,
    strategyReportLine,
    selectedTimeWindowHours !== undefined
      ? `I reviewed ${readableRows.length} readable message(s) from ${scopeLabel} in the last ${selectedTimeWindowHours}h.`
      : `I reviewed ${readableRows.length} readable message(s) from ${scopeLabel} using recent-by-count retrieval.`,
    promptMatches > 0
      ? `${promptMatches} message(s) directly matched key terms in your request.`
      : "Fallback mode: strongest recent evidence in scope (no direct keyword matches).",
    `Most active participants: ${topAuthors}.`,
    `Most active channels in this evidence set: ${topChannels}.`,
  ];

  const sourceLines = formatReportSourceLines(reportEvidenceRows, userMap, channelMap);
  const attachmentLines = formatAttachmentLines(attachments, reportEvidenceRows);

  return {
    text: withOptionalDiagnostics(
      [
        ...conversationalSummary,
        "",
        "Sources",
        ...sourceLines,
        "",
        "Attachment metadata",
        ...attachmentLines,
      ],
      includeDiagnostics,
      diagnosticsLines,
    ),
    reportPrefix: buildReportPrefix(input),
  };
};
