import fs from "node:fs";
import path from "node:path";
import {
  ChannelType,
  MessageFlags,
  PermissionFlagsBits,
  SlashCommandBuilder,
  type ButtonInteraction,
  type ChatInputCommandInteraction,
  type ModalSubmitInteraction,
  type StringSelectMenuInteraction,
} from "discord.js";
import type { LokiConfig } from "../../config";
import { Analyzer, makeJumpLink } from "../../ai/analyzer";
import { OllamaClient } from "../../ai/ollama";
import { ApprovalService, type ApprovalActionPayload } from "../../moderation/approvals";
import { PolicyManager } from "../../moderation/policy";
import { runBackfill, type BackfillScope } from "../backfill";
import { discoverCoverage } from "../coverage";
import { LokiDb, type ChatThreadMode } from "../../storage/db";
import { NdjsonLogger } from "../../storage/ndjson";
import { readPhaseStatus } from "../../status/phase";
import {
  exportMessagesToFile,
  handleLokiUiInteraction as handleLokiHomeUiInteraction,
  renderLokiHome,
  type ExportFormat,
  type ExportScope,
} from "../ui/home";
import { renderBudgetedReport } from "../ui/report";
import { runConversationalRequest, type RequestScopeOption } from "../request";

const SUPPORTED_CHANNEL_TYPES = [
  ChannelType.GuildText,
  ChannelType.GuildAnnouncement,
  ChannelType.PublicThread,
  ChannelType.PrivateThread,
  ChannelType.AnnouncementThread,
] as const;

type AskScopeOption = "auto" | "channel" | "server";
type AskScopeResolved = "channel" | "server";
type ChatModeOption = "mention" | "prefix" | "channel" | "off";
type ChatThreadModeOption = ChatThreadMode;
const HIGH_CONTENT_UNAVAILABLE_RATIO = 0.25;

const clampAskWindowHours = (windowHours?: number): number | undefined => {
  if (windowHours === undefined || Number.isNaN(windowHours)) {
    return undefined;
  }
  return Math.min(Math.max(windowHours, 1), 720);
};

const inferAskScope = (
  requestedScope: AskScopeOption,
  prompt: string,
  channelId?: string,
  hasChannelOverride = false,
): AskScopeResolved => {
  if (requestedScope === "channel") {
    return "channel";
  }
  if (requestedScope === "server") {
    return "server";
  }

  if (hasChannelOverride) {
    return "channel";
  }

  if (/\b(server|guild|across channels|across the server|whole server)\b/i.test(prompt)) {
    return "server";
  }

  if (channelId) {
    return "channel";
  }

  return "server";
};

const searchSnippet = (content: string | null, contentUnavailable: number): string => {
  if (contentUnavailable === 1) {
    return "[content unavailable: missing message content intent]";
  }
  return (content ?? "").replace(/\s+/g, " ").slice(0, 180);
};

const formatSearchEvidenceLine = (row: {
  id: string;
  guild_id: string | null;
  channel_id: string;
  author_id: string;
  created_at: string;
  content: string | null;
  content_unavailable: number;
}): string => {
  const snippet = searchSnippet(row.content, row.content_unavailable);
  const jump = row.guild_id ? makeJumpLink(row.guild_id, row.channel_id, row.id) : "n/a";
  return `${row.created_at} | ch=${row.channel_id} | user=${row.author_id} | ${snippet}\n  jump: ${jump}`;
};

const editReplyRendered = async (
  interaction: ChatInputCommandInteraction,
  ctx: LokiCommandContext,
  content: string,
  reportPrefix: string,
): Promise<void> => {
  const payload = renderBudgetedReport(
    ctx.config.dataDir,
    reportPrefix,
    `# Loki Report\n\n${content}`,
  );
  await interaction.editReply(payload);
};

interface CheckpointSummary {
  total: number;
  completed: number;
  latestRunAt?: string;
}

const readCheckpointSummary = (checkpointDir: string): CheckpointSummary => {
  if (!fs.existsSync(checkpointDir)) {
    return { total: 0, completed: 0 };
  }

  const files = fs.readdirSync(checkpointDir).filter((entry) => entry.endsWith(".json"));
  let completed = 0;
  let latestRunAt: string | undefined;

  for (const file of files) {
    const filePath = path.join(checkpointDir, file);
    const parsed = JSON.parse(fs.readFileSync(filePath, "utf8")) as {
      completed?: boolean;
      lastRunAt?: string;
    };

    if (parsed.completed) {
      completed += 1;
    }

    if (parsed.lastRunAt && (!latestRunAt || parsed.lastRunAt > latestRunAt)) {
      latestRunAt = parsed.lastRunAt;
    }
  }

  return {
    total: files.length,
    completed,
    latestRunAt,
  };
};

const parseIsoOrUndefined = (input: string | null): string | undefined => {
  if (!input) {
    return undefined;
  }
  const value = Date.parse(input);
  if (Number.isNaN(value)) {
    return undefined;
  }
  return new Date(value).toISOString();
};

export interface LokiCommandContext {
  config: LokiConfig;
  db: LokiDb;
  logger: NdjsonLogger;
  policyManager: PolicyManager;
  analyzer: Analyzer;
  approvals: ApprovalService;
  ollama: OllamaClient;
  hasMessageContent: boolean;
  isGuildAllowed?: (guildId: string | undefined) => boolean;
  runDailyIndexNow?: () => Promise<{
    runAt: string;
    finishedAt: string;
    guildsProcessed: number;
    targetsConsidered: number;
    targetsProcessed: number;
    targetsSkipped: number;
    messagesIngested: number;
  }>;
}

export const buildLokiCommand = () => {
  const builder = new SlashCommandBuilder()
    .setName("loki")
    .setDescription("Local-first Discord copilot + moderator")
    .addSubcommand((subcommand) => subcommand.setName("home").setDescription("Open Loki Home workspace"))
    .addSubcommand((subcommand) => subcommand.setName("status").setDescription("Show Loki status"))
    .addSubcommandGroup((group) =>
      group
        .setName("index")
        .setDescription("Daily indexing status and controls")
        .addSubcommand((subcommand) =>
          subcommand.setName("status").setDescription("Show daily indexing status"),
        )
        .addSubcommand((subcommand) =>
          subcommand.setName("run").setDescription("Run daily incremental index now"),
        )
        .addSubcommand((subcommand) =>
          subcommand.setName("verify").setDescription("Verify dedupe and index health"),
        ),
    )
    .addSubcommandGroup((group) =>
      group
        .setName("db")
        .setDescription("Database health checks")
        .addSubcommand((subcommand) =>
          subcommand
            .setName("verify")
            .setDescription("Verify duplicate attachments and FTS consistency"),
        ),
    )
    .addSubcommandGroup((group) =>
      group
        .setName("isolation")
        .setDescription("Guild isolation status")
        .addSubcommand((subcommand) =>
          subcommand.setName("status").setDescription("Show allowlist and DB isolation mode"),
        ),
    )
    .addSubcommand((subcommand) =>
      subcommand
        .setName("backfill")
        .setDescription("Backfill message history")
        .addStringOption((option) =>
          option
            .setName("scope")
            .setDescription("Backfill scope")
            .setRequired(true)
            .addChoices(
              { name: "all", value: "all" },
              { name: "channel", value: "channel" },
              { name: "threads", value: "threads" },
            ),
        )
        .addChannelOption((option) =>
          option
            .setName("channel")
            .setDescription("Specific channel or thread")
            .addChannelTypes(...SUPPORTED_CHANNEL_TYPES)
            .setRequired(false),
        )
        .addStringOption((option) =>
          option
            .setName("since")
            .setDescription("Optional ISO date")
            .setRequired(false),
        )
        .addIntegerOption((option) =>
          option
            .setName("max")
            .setDescription("Optional max messages per target")
            .setMinValue(1)
            .setMaxValue(100000)
            .setRequired(false),
        ),
    )
    .addSubcommand((subcommand) =>
      subcommand
        .setName("search")
        .setDescription("Search indexed messages")
        .addStringOption((option) => option.setName("query").setDescription("Search text").setRequired(true))
        .addChannelOption((option) =>
          option
            .setName("channel")
            .setDescription("Filter channel")
            .addChannelTypes(...SUPPORTED_CHANNEL_TYPES)
            .setRequired(false),
        )
        .addUserOption((option) => option.setName("user").setDescription("Filter user").setRequired(false))
        .addStringOption((option) => option.setName("since").setDescription("Since ISO date").setRequired(false))
        .addStringOption((option) => option.setName("until").setDescription("Until ISO date").setRequired(false))
        .addIntegerOption((option) =>
          option
            .setName("limit")
            .setDescription("Result limit")
            .setMinValue(1)
            .setMaxValue(50)
            .setRequired(false),
        ),
    )
    .addSubcommand((subcommand) =>
      subcommand
        .setName("summarize")
        .setDescription("Summarize channel/thread/user window")
        .addStringOption((option) =>
          option
            .setName("target")
            .setDescription("Summary target type")
            .setRequired(true)
            .addChoices(
              { name: "channel", value: "channel" },
              { name: "thread", value: "thread" },
              { name: "user", value: "user" },
            ),
        )
        .addStringOption((option) => option.setName("id").setDescription("Target ID").setRequired(true))
        .addStringOption((option) =>
          option
            .setName("ai")
            .setDescription("AI mode")
            .setRequired(true)
            .addChoices(
              { name: "on", value: "on" },
              { name: "off", value: "off" },
            ),
        )
        .addIntegerOption((option) =>
          option
            .setName("window")
            .setDescription("Window in hours")
            .setRequired(false)
            .setMinValue(1)
            .setMaxValue(336),
        )
        .addStringOption((option) => option.setName("model").setDescription("Ollama model").setRequired(false)),
    )
    .addSubcommand((subcommand) =>
      subcommand
        .setName("ask")
        .setDescription("Conversational evidence-backed request with auto scope")
        .addStringOption((option) =>
          option
            .setName("prompt")
            .setDescription("Natural language request")
            .setRequired(true),
        )
        .addStringOption((option) =>
          option
            .setName("scope")
            .setDescription("Scope for evidence search")
            .setRequired(false)
            .addChoices(
              { name: "auto", value: "auto" },
              { name: "channel", value: "channel" },
              { name: "server", value: "server" },
            ),
        )
        .addChannelOption((option) =>
          option
            .setName("channel")
            .setDescription("Optional channel/thread override")
            .addChannelTypes(...SUPPORTED_CHANNEL_TYPES)
            .setRequired(false),
        )
        .addIntegerOption((option) =>
          option
            .setName("window")
            .setDescription("Optional window in hours (default: smart 24h -> 7d -> 30d)")
            .setRequired(false)
            .setMinValue(1)
            .setMaxValue(720),
        )
        .addIntegerOption((option) =>
          option
            .setName("limit")
            .setDescription("Optional recent-count limit override (use intentionally for large server scans)")
            .setRequired(false)
            .setMinValue(1)
            .setMaxValue(20000),
        )
        .addStringOption((option) =>
          option
            .setName("model")
            .setDescription("Optional Ollama model override")
            .setRequired(false),
        ),
    )
    .addSubcommand((subcommand) =>
      subcommand
        .setName("request")
        .setDescription("Conversational evidence-backed request")
        .addStringOption((option) =>
          option
            .setName("prompt")
            .setDescription("What should Loki do?")
            .setRequired(true),
        )
        .addStringOption((option) =>
          option
            .setName("scope")
            .setDescription("Where to pull evidence from")
            .setRequired(false)
            .addChoices(
              { name: "here", value: "here" },
              { name: "channel", value: "channel" },
              { name: "server", value: "server" },
            ),
        )
        .addIntegerOption((option) =>
          option
            .setName("window")
            .setDescription("Optional window in hours (default: smart 24h -> 7d -> 30d)")
            .setRequired(false)
            .setMinValue(1)
            .setMaxValue(720),
        )
        .addStringOption((option) =>
          option
            .setName("model")
            .setDescription("Optional Ollama model override")
            .setRequired(false),
        )
        .addStringOption((option) =>
          option
            .setName("ai")
            .setDescription("AI mode")
            .setRequired(false)
            .addChoices(
              { name: "on", value: "on" },
              { name: "off", value: "off" },
            ),
        ),
    )
    .addSubcommandGroup((group) =>
      group
        .setName("chat")
        .setDescription("Manage non-slash conversational chat behavior")
        .addSubcommand((subcommand) =>
          subcommand.setName("status").setDescription("Show chat trigger configuration"),
        )
        .addSubcommand((subcommand) =>
          subcommand
            .setName("enable")
            .setDescription("Enable channel-wide chat trigger for a channel")
            .addChannelOption((option) =>
              option
                .setName("channel")
                .setDescription("Channel/thread to enable")
                .addChannelTypes(...SUPPORTED_CHANNEL_TYPES)
                .setRequired(true),
            ),
        )
        .addSubcommand((subcommand) =>
          subcommand
            .setName("disable")
            .setDescription("Disable channel-wide chat trigger for a channel")
            .addChannelOption((option) =>
              option
                .setName("channel")
                .setDescription("Channel/thread to disable")
                .addChannelTypes(...SUPPORTED_CHANNEL_TYPES)
                .setRequired(true),
            ),
        )
        .addSubcommand((subcommand) =>
          subcommand
            .setName("mode")
            .setDescription("Set global chat trigger mode for this server")
            .addStringOption((option) =>
              option
                .setName("mode")
                .setDescription("Trigger mode override")
                .setRequired(true)
                .addChoices(
                  { name: "mention", value: "mention" },
                  { name: "prefix", value: "prefix" },
                  { name: "channel", value: "channel" },
                  { name: "off", value: "off" },
                ),
            ),
        )
        .addSubcommand((subcommand) =>
          subcommand
            .setName("thread")
            .setDescription("Set chat thread routing behavior for this server")
            .addStringOption((option) =>
              option
                .setName("mode")
                .setDescription("Thread routing mode")
                .setRequired(true)
                .addChoices(
                  { name: "auto", value: "auto" },
                  { name: "ask", value: "ask" },
                  { name: "off", value: "off" },
                ),
            ),
        ),
    )
    .addSubcommand((subcommand) =>
      subcommand
        .setName("policy")
        .setDescription("Policy controls")
        .addStringOption((option) =>
          option
            .setName("action")
            .setDescription("show or reload")
            .setRequired(true)
            .addChoices(
              { name: "show", value: "show" },
              { name: "reload", value: "reload" },
            ),
        ),
    )
    .addSubcommand((subcommand) =>
      subcommand
        .setName("export")
        .setDescription("Export indexed messages to local files")
        .addStringOption((option) =>
          option
            .setName("scope")
            .setDescription("Export scope")
            .setRequired(true)
            .addChoices(
              { name: "server", value: "server" },
              { name: "channel", value: "channel" },
            ),
        )
        .addStringOption((option) =>
          option
            .setName("format")
            .setDescription("Export format")
            .setRequired(true)
            .addChoices(
              { name: "ndjson", value: "ndjson" },
              { name: "json", value: "json" },
            ),
        )
        .addChannelOption((option) =>
          option
            .setName("channel")
            .setDescription("Required for channel scope")
            .addChannelTypes(...SUPPORTED_CHANNEL_TYPES)
            .setRequired(false),
        ),
    )
    .addSubcommand((subcommand) =>
      subcommand
        .setName("lock")
        .setDescription("Suggest locking a channel")
        .addChannelOption((option) =>
          option
            .setName("channel")
            .setDescription("Target channel")
            .addChannelTypes(ChannelType.GuildText)
            .setRequired(true),
        )
        .addIntegerOption((option) =>
          option
            .setName("minutes")
            .setDescription("Duration in minutes")
            .setRequired(true)
            .setMinValue(1)
            .setMaxValue(1440),
        ),
    )
    .addSubcommand((subcommand) =>
      subcommand
        .setName("slowmode")
        .setDescription("Suggest changing slowmode")
        .addChannelOption((option) =>
          option
            .setName("channel")
            .setDescription("Target channel")
            .addChannelTypes(ChannelType.GuildText)
            .setRequired(true),
        )
        .addIntegerOption((option) =>
          option
            .setName("seconds")
            .setDescription("Slowmode seconds")
            .setRequired(true)
            .setMinValue(0)
            .setMaxValue(21600),
        ),
    )
    .addSubcommand((subcommand) =>
      subcommand
        .setName("purge")
        .setDescription("Suggest purging messages")
        .addChannelOption((option) =>
          option
            .setName("channel")
            .setDescription("Target channel")
            .addChannelTypes(ChannelType.GuildText)
            .setRequired(true),
        )
        .addIntegerOption((option) =>
          option
            .setName("count")
            .setDescription("Message count")
            .setRequired(true)
            .setMinValue(1)
            .setMaxValue(100),
        )
        .addStringOption((option) => option.setName("reason").setDescription("Reason").setRequired(true)),
    )
    .addSubcommand((subcommand) =>
      subcommand
        .setName("approve")
        .setDescription("Approve and execute a pending moderation action")
        .addStringOption((option) =>
          option.setName("id").setDescription("Pending action id").setRequired(true),
        ),
    );

  return builder;
};

const formatStatus = async (
  interaction: ChatInputCommandInteraction,
  ctx: LokiCommandContext,
): Promise<string> => {
  const phase = readPhaseStatus(process.cwd());
  const dbStats = ctx.db.getDbStats();
  const backfillStats = ctx.db.getBackfillSummary();
  const coverage = ctx.db.getCoverageReport(5);
  const checkpoints = readCheckpointSummary(ctx.config.checkpointDir);
  const guild = interaction.guild;

  const aiReachable = await ctx.ollama.isReachable(ctx.config.ollamaModel);

  return [
    `Phase: ${phase.phase}`,
    `Phase Status: ${phase.status}`,
    `Phase Source: ${phase.source}`,
    `Guild Connected: ${guild ? `${guild.name} (${guild.id})` : "N/A"}`,
    `Channels Readable: ${backfillStats.readableChannels}`,
    `Coverage Readable: ${coverage.readable}`,
    `Coverage Unreadable/Skipped: ${coverage.unreadable}`,
    `Coverage Sample: ${
      coverage.skipped.length > 0
        ? coverage.skipped.map((item) => `${item.channelId}:${item.reason}`).join(", ")
        : "none"
    }`,
    `Content Intent Available: ${ctx.hasMessageContent ? "yes" : "no"}`,
    `Backfill Targets Tracked: ${backfillStats.totalTrackedChannels}`,
    `Backfill Completed Targets: ${backfillStats.completedBackfills}`,
    `Backfill Last Run: ${backfillStats.lastBackfillAt ?? "n/a"}`,
    `Checkpoint Files: ${checkpoints.total}`,
    `Checkpoints Completed: ${checkpoints.completed}`,
    `Latest Checkpoint: ${checkpoints.latestRunAt ?? "n/a"}`,
    `DB Messages Indexed: ${dbStats.messages}`,
    `DB Channels Indexed: ${dbStats.channels}`,
    `FTS Ready: ${dbStats.ftsReady ? "yes" : "no"}`,
    `FTS Rows: ${dbStats.ftsRows}`,
    `AI Default: ${ctx.config.ollamaModel}`,
    `AI Reachable: ${aiReachable ? "yes" : "no"}`,
    `Enforcement Enabled: ${ctx.config.enableEnforcement ? "yes" : "no"}`,
  ].join("\n");
};

const describeChatMode = (mode: ChatModeOption | undefined): string => {
  if (!mode) {
    return "default (mention + prefix; channel trigger only for explicitly enabled channels)";
  }

  if (mode === "mention") {
    return "mention only";
  }
  if (mode === "prefix") {
    return "prefix only";
  }
  if (mode === "channel") {
    return "channel only (requires enabled channels)";
  }
  return "off";
};

const describeChatThreadMode = (mode: ChatThreadModeOption): string => {
  if (mode === "auto") {
    return "auto (route all conversational replies into user threads)";
  }
  if (mode === "ask") {
    return "ask (route task questions into user threads)";
  }
  return "off";
};

const handleChatSubcommand = async (
  interaction: ChatInputCommandInteraction,
  ctx: LokiCommandContext,
  subcommand: string,
): Promise<void> => {
  if (!interaction.guildId) {
    await interaction.editReply("`/loki chat` commands can only run inside a server.");
    return;
  }

  const guildId = interaction.guildId;

  if (subcommand === "status") {
    const mode = ctx.db.getChatMode(guildId);
    const threadMode = ctx.db.getChatThreadMode(guildId);
    const enabledChannels = ctx.db.listChatEnabledChannels(guildId, 20);
    const threadRoutes = ctx.db.countChatThreadRoutes(guildId);

    await interaction.editReply(
      [
        "Loki chat status",
        `Mode: ${describeChatMode(mode)}`,
        `Thread mode: ${describeChatThreadMode(threadMode)}`,
        `Thread routes: ${threadRoutes}`,
        `Enabled channels: ${enabledChannels.length}`,
        `Channels: ${enabledChannels.length > 0 ? enabledChannels.map((id) => `<#${id}>`).join(", ") : "none"}`,
        "Cooldown: 15s per channel",
        "Default triggers: mention + `loki:`/`loki ` prefix",
      ].join("\n"),
    );
    return;
  }

  if (subcommand === "enable") {
    const channel = interaction.options.getChannel("channel", true);
    ctx.db.enableChatChannel(guildId, channel.id);
    await interaction.editReply(
      `Enabled channel-triggered chat for <#${channel.id}>.`,
    );
    return;
  }

  if (subcommand === "disable") {
    const channel = interaction.options.getChannel("channel", true);
    ctx.db.disableChatChannel(guildId, channel.id);
    await interaction.editReply(
      `Disabled channel-triggered chat for <#${channel.id}>.`,
    );
    return;
  }

  if (subcommand === "mode") {
    const mode = interaction.options.getString("mode", true) as ChatModeOption;
    ctx.db.setChatMode(guildId, mode);
    await interaction.editReply(`Chat mode set to \`${mode}\`.`);
    return;
  }

  if (subcommand === "thread") {
    const mode = interaction.options.getString("mode", true) as ChatThreadModeOption;
    ctx.db.setChatThreadMode(guildId, mode);
    await interaction.editReply(`Chat thread mode set to \`${mode}\`.`);
    return;
  }

  await interaction.editReply(`Unknown chat subcommand: ${subcommand}`);
};

const handleIndexSubcommand = async (
  interaction: ChatInputCommandInteraction,
  ctx: LokiCommandContext,
  subcommand: string,
): Promise<void> => {
  if (subcommand === "status") {
    const status = ctx.db.getIndexStatus();
    await interaction.editReply(
      [
        "Loki index status",
        `Last run: ${status.lastIndexRunAt ?? "n/a"}`,
        `Last success: ${status.lastIndexOkAt ?? "n/a"}`,
        `Last error: ${status.lastIndexError ?? "none"}`,
        `Index version: ${status.indexVersion ?? "n/a"}`,
      ].join("\n"),
    );
    return;
  }

  if (subcommand === "run") {
    if (!ctx.runDailyIndexNow) {
      await interaction.editReply("Daily index runner is not initialized.");
      return;
    }

    const summary = await ctx.runDailyIndexNow();
    await interaction.editReply(
      [
        "Daily incremental index complete.",
        `Started: ${summary.runAt}`,
        `Finished: ${summary.finishedAt}`,
        `Guilds processed: ${summary.guildsProcessed}`,
        `Targets considered: ${summary.targetsConsidered}`,
        `Targets processed: ${summary.targetsProcessed}`,
        `Targets skipped: ${summary.targetsSkipped}`,
        `Messages ingested: ${summary.messagesIngested}`,
      ].join("\n"),
    );
    return;
  }

  if (subcommand === "verify") {
    const status = ctx.db.getIndexStatus();
    const duplicates = ctx.db.getIndexDuplicateStats();
    const availability = ctx.db.getEvidenceAvailabilityStats();

    let channelTracked = 0;
    let channelReadable = 0;
    let threadTracked = 0;
    let threadReadable = 0;
    let coverageError: string | undefined;

    if (interaction.guild) {
      try {
        const coverage = await discoverCoverage(interaction.guild);
        for (const entry of coverage.entries) {
          const readable = entry.canView && entry.canReadHistory;
          if (entry.kind === "thread") {
            threadTracked += 1;
            if (readable) {
              threadReadable += 1;
            }
          } else {
            channelTracked += 1;
            if (readable) {
              channelReadable += 1;
            }
          }
        }
      } catch (error) {
        coverageError = error instanceof Error ? error.message : "unknown coverage error";
      }
    }

    const warnings: string[] = [];
    if (!ctx.hasMessageContent) {
      warnings.push(
        "Message Content intent is unavailable. Enable it in the Discord Developer Portal for full ingestion.",
      );
    }
    if (availability.totalMessages > 0 && availability.unavailableRatio >= HIGH_CONTENT_UNAVAILABLE_RATIO) {
      warnings.push(
        `content_unavailable ratio is high (${(availability.unavailableRatio * 100).toFixed(1)}%).`,
      );
    }
    if (
      duplicates.messageIdDuplicates > 0 ||
      duplicates.attachmentIdDuplicates > 0 ||
      duplicates.attachmentMessageUrlDuplicates > 0
    ) {
      warnings.push("Duplicate rows detected. Investigate upsert/constraint behavior immediately.");
    }
    if (coverageError) {
      warnings.push(`Coverage probe failed: ${coverageError}`);
    }

    await interaction.editReply(
      [
        "Loki index verify",
        `messages.id duplicates: ${duplicates.messageIdDuplicates}`,
        `attachments.id duplicates: ${duplicates.attachmentIdDuplicates}`,
        `attachments(message_id,url) duplicates: ${duplicates.attachmentMessageUrlDuplicates}`,
        `Last success: ${status.lastIndexOkAt ?? "n/a"}`,
        `Last run: ${status.lastIndexRunAt ?? "n/a"}`,
        `Last error: ${status.lastIndexError ?? "none"}`,
        `Channels tracked/readable: ${channelTracked}/${channelReadable}`,
        `Threads tracked/readable: ${threadTracked}/${threadReadable}`,
        `Content unavailable ratio: ${(availability.unavailableRatio * 100).toFixed(1)}% (${availability.unavailableMessages}/${availability.totalMessages})`,
        `Warnings: ${warnings.length === 0 ? "none" : warnings.join(" | ")}`,
      ].join("\n"),
    );
    return;
  }

  await interaction.editReply(`Unknown index subcommand: ${subcommand}`);
};

const handleDbSubcommand = async (
  interaction: ChatInputCommandInteraction,
  ctx: LokiCommandContext,
  subcommand: string,
): Promise<void> => {
  if (subcommand === "verify") {
    const duplicates = ctx.db.getIndexDuplicateStats();
    const fts = ctx.db.getFtsConsistencyStats();

    const warnings: string[] = [];
    if (duplicates.attachmentIdDuplicates > 0 || duplicates.attachmentMessageUrlDuplicates > 0) {
      warnings.push("Duplicate attachment rows detected.");
    }
    if (!fts.consistent) {
      warnings.push("FTS consistency checks failed.");
    }
    if (!fts.ftsReady) {
      warnings.push("messages_fts table is missing.");
    }

    await interaction.editReply(
      [
        "Loki db verify",
        `Health: ${warnings.length === 0 ? "ok" : "warn"}`,
        `Attachment duplicates: id=${duplicates.attachmentIdDuplicates}, message_url=${duplicates.attachmentMessageUrlDuplicates}`,
        `FTS consistency: ${fts.consistent ? "ok" : "mismatch"}`,
        `FTS stats: messages=${fts.messagesCount}, fts_rows=${fts.ftsRows}, missing=${fts.missingFtsRows}, orphan=${fts.orphanFtsRows}, duplicate_message_ids=${fts.duplicateFtsMessageIds}`,
        `Warnings: ${warnings.length === 0 ? "none" : warnings.join(" | ")}`,
      ].join("\n"),
    );
    return;
  }

  await interaction.editReply(`Unknown db subcommand: ${subcommand}`);
};

const handleIsolationSubcommand = async (
  interaction: ChatInputCommandInteraction,
  ctx: LokiCommandContext,
  subcommand: string,
): Promise<void> => {
  if (subcommand === "status") {
    const currentGuildId = interaction.guildId ?? "n/a";
    const currentGuildAllowed = ctx.isGuildAllowed
      ? ctx.isGuildAllowed(interaction.guildId ?? undefined)
      : true;
    const allowlistText =
      ctx.config.guildAllowlist.length === 0
        ? "disabled (all guilds allowed)"
        : ctx.config.guildAllowlist.join(", ");

    await interaction.editReply(
      [
        "Loki isolation status",
        `DB mode: ${ctx.config.dbMode}`,
        `DB path: ${ctx.config.dbPath}`,
        `Checkpoint dir: ${ctx.config.checkpointDir}`,
        `Log dir: ${ctx.config.logDir}`,
        `Allowlist: ${allowlistText}`,
        `Current guild: ${currentGuildId}`,
        `Current guild allowed: ${currentGuildAllowed ? "yes" : "no"}`,
      ].join("\n"),
    );
    return;
  }

  await interaction.editReply(`Unknown isolation subcommand: ${subcommand}`);
};

const createSuggestedAction = (
  interaction: ChatInputCommandInteraction,
  ctx: LokiCommandContext,
  payload: Omit<ApprovalActionPayload, "requestedBy">,
): string => {
  return ctx.approvals.createPendingApproval({
    ...payload,
    requestedBy: interaction.user.id,
  });
};

const handleApprove = async (
  interaction: ChatInputCommandInteraction,
  ctx: LokiCommandContext,
): Promise<void> => {
  const id = interaction.options.getString("id", true);

  const result = await ctx.approvals.approveAndExecute(
    id,
    interaction.user.id,
    async (_record, payload) => {
      if (!interaction.guild) {
        throw new Error("This command must be used in a guild.");
      }

      const channelId = payload.channelId;
      if (!channelId) {
        return;
      }

      const channel = interaction.guild.channels.cache.get(channelId);
      if (!channel) {
        throw new Error(`Channel ${channelId} not found.`);
      }

      switch (payload.action) {
        case "lock": {
          if (!("permissionOverwrites" in channel)) {
            throw new Error("Target channel is not text-based.");
          }

          const minutes = Number(payload.execution.minutes ?? 5);
          const editableChannel = channel as {
            permissionOverwrites: {
              edit: (
                roleId: string,
                permissions: { SendMessages: boolean | null },
                options: { reason: string },
              ) => Promise<unknown>;
            };
          };

          await editableChannel.permissionOverwrites.edit(
            interaction.guild.roles.everyone.id,
            { SendMessages: false },
            { reason: payload.reason ?? "Loki approved lock" },
          );

          setTimeout(() => {
            editableChannel.permissionOverwrites
              .edit(interaction.guild!.roles.everyone.id, { SendMessages: null }, { reason: "Loki lock auto-expire" })
              .catch(() => {
                // Intentionally ignored; recovery handled through runbook.
              });
          }, minutes * 60 * 1000);
          break;
        }

        case "slowmode": {
          if (!("setRateLimitPerUser" in channel) || typeof channel.setRateLimitPerUser !== "function") {
            throw new Error("Target channel is not text-based.");
          }
          const seconds = Number(payload.execution.seconds ?? 0);
          await channel.setRateLimitPerUser(
            seconds,
            payload.reason ?? "Loki approved slowmode",
          );
          break;
        }

        case "purge": {
          if (!("bulkDelete" in channel) || typeof channel.bulkDelete !== "function") {
            throw new Error("Target channel is not text-based.");
          }
          const count = Number(payload.execution.count ?? 0);
          if (count <= 0) {
            throw new Error("Invalid purge count.");
          }
          await channel.bulkDelete(count, true);
          break;
        }

        case "timeout": {
          if (!payload.targetUserId) {
            throw new Error("Timeout action missing target user.");
          }
          const member = await interaction.guild.members.fetch(payload.targetUserId);
          const minutes = Number(payload.execution.minutes ?? 10);
          await member.timeout(minutes * 60 * 1000, payload.reason ?? "Loki approved timeout");
          break;
        }

        case "warn": {
          if (!("send" in channel) || typeof channel.send !== "function") {
            return;
          }
          const target = payload.targetUserId ? `<@${payload.targetUserId}>` : "user";
          await channel.send(
            `${target} warning issued by Loki approval: ${payload.reason ?? "policy trigger"}`,
          );
          break;
        }

        default:
          throw new Error(`Unsupported action type: ${payload.action}`);
      }
    },
  );

  await interaction.editReply(result.message);
};

export const handleLokiCommand = async (
  interaction: ChatInputCommandInteraction,
  ctx: LokiCommandContext,
): Promise<void> => {
  await interaction.deferReply({ flags: MessageFlags.Ephemeral });

  try {
    const subcommandGroup = interaction.options.getSubcommandGroup(false);
    const subcommand = interaction.options.getSubcommand(true);
    const isIsolationStatus = subcommandGroup === "isolation" && subcommand === "status";

    if (!isIsolationStatus && ctx.isGuildAllowed && !ctx.isGuildAllowed(interaction.guildId ?? undefined)) {
      await interaction.editReply("This guild is not approved for Loki operations.");
      return;
    }

    if (subcommandGroup === "chat") {
      await handleChatSubcommand(interaction, ctx, subcommand);
      return;
    }

    if (subcommandGroup === "index") {
      await handleIndexSubcommand(interaction, ctx, subcommand);
      return;
    }

    if (subcommandGroup === "db") {
      await handleDbSubcommand(interaction, ctx, subcommand);
      return;
    }

    if (subcommandGroup === "isolation") {
      await handleIsolationSubcommand(interaction, ctx, subcommand);
      return;
    }

    if (subcommand === "home") {
      await renderLokiHome(interaction, ctx);
      return;
    }

    if (subcommand === "status") {
      const body = await formatStatus(interaction, ctx);
      await interaction.editReply(`\`/loki status\`\n${body}`);
      return;
    }

    if (subcommand === "backfill") {
      if (!interaction.guild) {
        await interaction.editReply("Backfill can only run in a guild.");
        return;
      }

      const scope = interaction.options.getString("scope", true) as BackfillScope;
      const channel = interaction.options.getChannel("channel", false);
      const sinceInput = interaction.options.getString("since", false);
      const max = interaction.options.getInteger("max", false) ?? undefined;

      const since = parseIsoOrUndefined(sinceInput);
      if (sinceInput && !since) {
        await interaction.editReply(`Invalid ISO date for since: ${sinceInput}`);
        return;
      }

      let updateCount = 0;
      const summary = await runBackfill(
        interaction.guild,
        {
          db: ctx.db,
          logger: ctx.logger,
          checkpointDir: ctx.config.checkpointDir,
          hasMessageContent: ctx.hasMessageContent,
        },
        {
          scope,
          channelId: channel?.id,
          since,
          max,
          onProgress: async (progress) => {
            updateCount += 1;
            if (updateCount % 25 === 0) {
              await interaction.editReply(
                `Backfill in progress... channel=${progress.channelName} (${progress.channelId}) local=${progress.messagesIngested} total=${progress.totalIngested}`,
              );
            }
          },
        },
      );

      const skippedPreview = summary.skipped.slice(0, 10);
      const skippedText = skippedPreview.length
        ? skippedPreview.map((item) => `${item.channelId}: ${item.reason}`).join("\n")
        : "none";

      await editReplyRendered(
        interaction,
        ctx,
        [
          "Backfill complete.",
          `Targets considered: ${summary.targetsConsidered}`,
          `Targets processed: ${summary.targetsProcessed}`,
          `Targets skipped: ${summary.targetsSkipped}`,
          `Messages ingested: ${summary.messagesIngested}`,
          `Skipped sample:\n${skippedText}`,
        ].join("\n"),
        "loki_backfill",
      );
      return;
    }

    if (subcommand === "search") {
      const query = interaction.options.getString("query", true);
      const channel = interaction.options.getChannel("channel", false);
      const user = interaction.options.getUser("user", false);
      const since = parseIsoOrUndefined(interaction.options.getString("since", false));
      const until = parseIsoOrUndefined(interaction.options.getString("until", false));
      const limit = interaction.options.getInteger("limit", false) ?? 10;

      const rows = ctx.db.searchMessages({
        query,
        guildId: interaction.guildId ?? undefined,
        channelId: channel?.id,
        userId: user?.id,
        since,
        until,
        limit,
      });

      if (rows.length === 0) {
        await interaction.editReply("No search results.");
        return;
      }

      const body = rows.map((row) => formatSearchEvidenceLine(row)).join("\n");

      await editReplyRendered(interaction, ctx, body, "loki_search");
      return;
    }

    if (subcommand === "summarize") {
      const target = interaction.options.getString("target", true);
      const id = interaction.options.getString("id", true);
      const window = interaction.options.getInteger("window", false) ?? undefined;
      const model = interaction.options.getString("model", false) ?? undefined;
      const ai = interaction.options.getString("ai", true) as "on" | "off";

      if (target === "channel" || target === "thread") {
        const result = await ctx.analyzer.summarizeChannelWindow({
          channelId: id,
          windowHours: window,
          model,
          ai,
        });
        await editReplyRendered(interaction, ctx, result.text, "loki_summarize_channel");
        return;
      }

      if (target === "user") {
        const result = await ctx.analyzer.summarizeUserCase({
          userId: id,
          windowHours: window,
          model,
          ai,
        });
        await editReplyRendered(interaction, ctx, result.text, "loki_summarize_user");
        return;
      }

      await interaction.editReply(`Unsupported target: ${target}`);
      return;
    }

    if (subcommand === "ask") {
      const prompt = interaction.options.getString("prompt", true).trim();
      const requestedScope = (interaction.options.getString("scope", false) as AskScopeOption | null) ?? "auto";
      const requestedChannel = interaction.options.getChannel("channel", false);
      const windowHours = clampAskWindowHours(interaction.options.getInteger("window", false) ?? undefined);
      const recentReadableLimit = interaction.options.getInteger("limit", false) ?? undefined;
      const model = interaction.options.getString("model", false) ?? undefined;

      if (!prompt) {
        await interaction.editReply("Prompt cannot be empty.");
        return;
      }

      const channelId = requestedChannel?.id ?? interaction.channelId ?? undefined;
      const resolvedScope = inferAskScope(requestedScope, prompt, channelId, Boolean(requestedChannel));
      if (resolvedScope === "channel" && !channelId) {
        await interaction.editReply("Channel scope requires a channel context.");
        return;
      }
      if (resolvedScope === "server" && !interaction.guildId) {
        await interaction.editReply("Server scope is only available inside a guild.");
        return;
      }

      const scope: RequestScopeOption = resolvedScope === "server" ? "server" : "channel";
      const result = await runConversationalRequest(
        {
          db: ctx.db,
          defaultModel: ctx.config.ollamaModel,
        },
        {
          prompt,
          scope,
          guildId: interaction.guildId ?? undefined,
          channelId: resolvedScope === "channel" ? channelId : undefined,
          windowHours,
          recentReadableLimit,
          model,
          ai: "on",
        },
      );

      await interaction.editReply(
        renderBudgetedReport(
          ctx.config.dataDir,
          `loki_ask_${result.reportPrefix}`,
          `# Loki Report\n\n${result.text}`,
        ),
      );
      return;
    }

    if (subcommand === "request") {
      const prompt = interaction.options.getString("prompt", true).trim();
      const scope = (interaction.options.getString("scope", false) as RequestScopeOption | null) ?? "here";
      const windowHours = interaction.options.getInteger("window", false) ?? undefined;
      const model = interaction.options.getString("model", false) ?? undefined;
      const ai = (interaction.options.getString("ai", false) as "on" | "off" | null) ?? "on";

      if (!prompt) {
        await interaction.editReply("Prompt cannot be empty.");
        return;
      }

      if (scope === "server" && !interaction.guildId) {
        await interaction.editReply("Server scope is only available inside a guild.");
        return;
      }

      if ((scope === "here" || scope === "channel") && !interaction.channelId) {
        await interaction.editReply("Channel scope requires a channel context.");
        return;
      }

      const result = await runConversationalRequest(
        {
          db: ctx.db,
          defaultModel: ctx.config.ollamaModel,
        },
        {
          prompt,
          scope,
          guildId: interaction.guildId ?? undefined,
          channelId: interaction.channelId ?? undefined,
          windowHours,
          model,
          ai,
        },
      );

      await interaction.editReply(
        renderBudgetedReport(
          ctx.config.dataDir,
          result.reportPrefix,
          `# Loki Report\n\n${result.text}`,
        ),
      );
      return;
    }

    if (subcommand === "policy") {
      const action = interaction.options.getString("action", true);
      if (action === "show") {
        await editReplyRendered(
          interaction,
          ctx,
          `\`\`\`json\n${ctx.policyManager.show()}\n\`\`\``,
          "loki_policy_show",
        );
        return;
      }

      if (action === "reload") {
        ctx.policyManager.reload();
        await interaction.editReply("Policy reloaded successfully.");
        return;
      }

      await interaction.editReply(`Unknown policy action: ${action}`);
      return;
    }

    if (subcommand === "export") {
      if (!interaction.guildId) {
        await interaction.editReply("Export can only run in a server.");
        return;
      }

      const scope = interaction.options.getString("scope", true) as ExportScope;
      const format = interaction.options.getString("format", true) as ExportFormat;
      const channel = interaction.options.getChannel("channel", false);

      if (scope === "channel" && !channel) {
        await interaction.editReply("For `scope:channel`, provide a channel option.");
        return;
      }

      const result = exportMessagesToFile(ctx, {
        guildId: interaction.guildId,
        scope,
        format,
        channelId: channel?.id,
      });

      await interaction.editReply(
        [
          "Export complete.",
          `Scope: ${result.scope}`,
          `Format: ${result.format}`,
          `Messages exported: ${result.count}`,
          `File: ${result.filePath}`,
          "Example: `/loki export scope:channel format:json channel:#general`",
        ].join("\n"),
      );
      return;
    }

    if (subcommand === "lock") {
      const channel = interaction.options.getChannel("channel", true);
      const minutes = interaction.options.getInteger("minutes", true);

      const id = createSuggestedAction(interaction, ctx, {
        guildId: interaction.guildId,
        channelId: channel.id,
        action: "lock",
        reason: `Requested lock for ${minutes} minute(s)`,
        evidence: {
          command: "loki lock",
          requestedBy: interaction.user.id,
        },
        execution: {
          minutes,
        },
      });

      await interaction.editReply(
        `Suggestion created: ${id}. Enforcement is suggest-first. Use \`/loki approve id:${id}\` to execute when allowed.`,
      );
      return;
    }

    if (subcommand === "slowmode") {
      const channel = interaction.options.getChannel("channel", true);
      const seconds = interaction.options.getInteger("seconds", true);

      const id = createSuggestedAction(interaction, ctx, {
        guildId: interaction.guildId,
        channelId: channel.id,
        action: "slowmode",
        reason: `Requested slowmode ${seconds} second(s)`,
        evidence: {
          command: "loki slowmode",
          requestedBy: interaction.user.id,
        },
        execution: {
          seconds,
        },
      });

      await interaction.editReply(
        `Suggestion created: ${id}. Use \`/loki approve id:${id}\` after review.`,
      );
      return;
    }

    if (subcommand === "purge") {
      const channel = interaction.options.getChannel("channel", true);
      const count = interaction.options.getInteger("count", true);
      const reason = interaction.options.getString("reason", true);

      const id = createSuggestedAction(interaction, ctx, {
        guildId: interaction.guildId,
        channelId: channel.id,
        action: "purge",
        reason,
        evidence: {
          command: "loki purge",
          requestedBy: interaction.user.id,
        },
        execution: {
          count,
        },
      });

      await interaction.editReply(
        `Suggestion created: ${id}. No purge executes until approval and enforcement gate pass.`,
      );
      return;
    }

    if (subcommand === "approve") {
      await handleApprove(interaction, ctx);
      return;
    }

    await interaction.editReply(`Unknown subcommand: ${subcommand}`);
  } finally {
    if (interaction.deferred && !interaction.replied) {
      try {
        await interaction.editReply("Loki could not complete that command. Please retry.");
      } catch {
        // Nothing else to do if interaction token already expired.
      }
    }
  }
};

export const requiredBotPermissions = [
  PermissionFlagsBits.ViewChannel,
  PermissionFlagsBits.ReadMessageHistory,
  PermissionFlagsBits.SendMessages,
];

export const handleLokiUiInteraction = async (
  interaction: ButtonInteraction | StringSelectMenuInteraction | ModalSubmitInteraction,
  ctx: LokiCommandContext,
): Promise<boolean> => {
  return handleLokiHomeUiInteraction(interaction, ctx);
};
