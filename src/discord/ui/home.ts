import fs from "node:fs";
import path from "node:path";
import {
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
  ModalBuilder,
  TextInputBuilder,
  TextInputStyle,
  StringSelectMenuBuilder,
  type ButtonInteraction,
  type ChatInputCommandInteraction,
  type Guild,
  type ModalSubmitInteraction,
  type StringSelectMenuInteraction,
} from "discord.js";
import { makeJumpLink } from "../../ai/analyzer";
import { runConversationalRequest } from "../request";
import type { LokiCommandContext } from "../commands/loki";
import { runBackfill } from "../backfill";
import { discoverCoverage } from "../coverage";
import {
  deferEphemeralReplySafely,
  deferUpdateSafely,
  ephemeralReply,
  isUnknownInteractionError,
  respondSafely,
  withEphemeralFlags,
} from "./interaction";
import { renderBudgetedReport } from "./report";

const UI_PREFIX = "lokiui";
const PAGE_SIZE = 25;

type UiInteraction = ButtonInteraction | StringSelectMenuInteraction | ModalSubmitInteraction;

export type ExportScope = "server" | "channel";
export type ExportFormat = "ndjson" | "json";

interface ExportResult {
  filePath: string;
  count: number;
  scope: ExportScope;
  format: ExportFormat;
}

interface BrowserView {
  content: string;
  components: Array<ActionRowBuilder<ButtonBuilder> | ActionRowBuilder<StringSelectMenuBuilder>>;
}

const truncate = (text: string, max = 1900): string => {
  if (text.length <= max) {
    return text;
  }
  return `${text.slice(0, max - 20)}\n\n[truncated]`;
};

const shorten = (value: string, max = 100): string => {
  if (value.length <= max) {
    return value;
  }
  return `${value.slice(0, max - 3)}...`;
};

const safeTimestamp = (): string => {
  return new Date().toISOString().replace(/[.:]/g, "-");
};

const homeId = (userId: string): string => `${UI_PREFIX}:home:${userId}`;
const browseId = (userId: string, page: number): string => `${UI_PREFIX}:browse:${userId}:${page}`;
const browsePickId = (userId: string, page: number): string => `${UI_PREFIX}:pick:${userId}:${page}`;
const indexId = (userId: string): string => `${UI_PREFIX}:idx:${userId}`;
const searchHomeId = (userId: string): string => `${UI_PREFIX}:search:${userId}`;
const requestHomeId = (userId: string): string => `${UI_PREFIX}:request:${userId}`;
const summarizeHomeId = (userId: string): string => `${UI_PREFIX}:sum:${userId}`;
const exportMenuId = (userId: string): string => `${UI_PREFIX}:exp:${userId}`;
const exportServerId = (userId: string, format: ExportFormat): string => `${UI_PREFIX}:expserv:${userId}:${format}`;
const channelActionId = (
  userId: string,
  channelId: string,
  page: number,
  action: "sum24" | "sum168" | "search" | "export",
): string => `${UI_PREFIX}:act:${userId}:${channelId}:${page}:${action}`;
const searchModalId = (userId: string, channelIdOrAll: string): string =>
  `${UI_PREFIX}:modal:${userId}:${channelIdOrAll}`;
const requestModalId = (userId: string, channelId: string): string =>
  `${UI_PREFIX}:reqmodal:${userId}:${channelId}`;

const logUnknownInteraction = (ctx: LokiCommandContext, customId: string): void => {
  ctx.logger.logEvent("discord.interaction.expired", {
    customId,
  });
};

const ensureOwner = async (
  interaction: UiInteraction,
  ownerId: string,
  ctx: LokiCommandContext,
): Promise<boolean> => {
  if (interaction.user.id === ownerId) {
    return true;
  }

  await respondSafely(
    interaction,
    withEphemeralFlags({
      content: "This panel belongs to another user. Run `/loki home` to open your own workspace.",
    }),
    "replyOrFollowUp",
    () => logUnknownInteraction(ctx, interaction.customId),
  );
  return false;
};

const buildHomeComponents = (userId: string): ActionRowBuilder<ButtonBuilder>[] => {
  return [
    new ActionRowBuilder<ButtonBuilder>().addComponents(
      new ButtonBuilder().setCustomId(browseId(userId, 0)).setLabel("Browse Channels").setStyle(ButtonStyle.Primary),
      new ButtonBuilder().setCustomId(indexId(userId)).setLabel("Index Server").setStyle(ButtonStyle.Secondary),
      new ButtonBuilder().setCustomId(requestHomeId(userId)).setLabel("Request").setStyle(ButtonStyle.Secondary),
    ),
    new ActionRowBuilder<ButtonBuilder>().addComponents(
      new ButtonBuilder().setCustomId(searchHomeId(userId)).setLabel("Search").setStyle(ButtonStyle.Secondary),
      new ButtonBuilder().setCustomId(summarizeHomeId(userId)).setLabel("Summarize").setStyle(ButtonStyle.Secondary),
      new ButtonBuilder().setCustomId(exportMenuId(userId)).setLabel("Export").setStyle(ButtonStyle.Secondary),
    ),
  ];
};

const buildExportMenuComponents = (userId: string): ActionRowBuilder<ButtonBuilder>[] => {
  return [
    new ActionRowBuilder<ButtonBuilder>().addComponents(
      new ButtonBuilder()
        .setCustomId(exportServerId(userId, "ndjson"))
        .setLabel("Export Server (NDJSON)")
        .setStyle(ButtonStyle.Primary),
      new ButtonBuilder()
        .setCustomId(exportServerId(userId, "json"))
        .setLabel("Export Server (JSON)")
        .setStyle(ButtonStyle.Secondary),
      new ButtonBuilder().setCustomId(browseId(userId, 0)).setLabel("Browse Channels").setStyle(ButtonStyle.Secondary),
      new ButtonBuilder().setCustomId(homeId(userId)).setLabel("Back Home").setStyle(ButtonStyle.Secondary),
    ),
  ];
};

const buildChannelActionComponents = (
  userId: string,
  channelId: string,
  page: number,
): ActionRowBuilder<ButtonBuilder>[] => {
  return [
    new ActionRowBuilder<ButtonBuilder>().addComponents(
      new ButtonBuilder()
        .setCustomId(channelActionId(userId, channelId, page, "sum24"))
        .setLabel("Summarize (last 24h)")
        .setStyle(ButtonStyle.Primary),
      new ButtonBuilder()
        .setCustomId(channelActionId(userId, channelId, page, "sum168"))
        .setLabel("Summarize (last 7d)")
        .setStyle(ButtonStyle.Secondary),
      new ButtonBuilder()
        .setCustomId(channelActionId(userId, channelId, page, "search"))
        .setLabel("Search")
        .setStyle(ButtonStyle.Secondary),
      new ButtonBuilder()
        .setCustomId(channelActionId(userId, channelId, page, "export"))
        .setLabel("Export channel")
        .setStyle(ButtonStyle.Secondary),
    ),
    new ActionRowBuilder<ButtonBuilder>().addComponents(
      new ButtonBuilder().setCustomId(browseId(userId, page)).setLabel("Back to Browser").setStyle(ButtonStyle.Secondary),
      new ButtonBuilder().setCustomId(homeId(userId)).setLabel("Back Home").setStyle(ButtonStyle.Secondary),
    ),
  ];
};

const getReadableTargets = async (guild: Guild): Promise<Array<{ channelId: string; channelName: string; kind: string }>> => {
  const coverage = await discoverCoverage(guild);
  return coverage.targets
    .map((target) => ({
      channelId: target.channelId,
      channelName: target.channelName,
      kind: target.kind,
    }))
    .sort((a, b) => a.channelName.localeCompare(b.channelName));
};

const buildBrowserView = async (
  guild: Guild,
  userId: string,
  page: number,
  hint?: string,
): Promise<BrowserView> => {
  const targets = await getReadableTargets(guild);

  if (targets.length === 0) {
    return {
      content: [
        "**Loki Channel Browser**",
        "No readable text channels/threads were found for this bot.",
        "Check bot permissions (`ViewChannel`, `ReadMessageHistory`) and try again.",
      ].join("\n"),
      components: [
        new ActionRowBuilder<ButtonBuilder>().addComponents(
          new ButtonBuilder().setCustomId(homeId(userId)).setLabel("Back Home").setStyle(ButtonStyle.Secondary),
        ),
      ],
    };
  }

  const totalPages = Math.max(1, Math.ceil(targets.length / PAGE_SIZE));
  const safePage = Math.min(Math.max(page, 0), totalPages - 1);
  const offset = safePage * PAGE_SIZE;
  const pageTargets = targets.slice(offset, offset + PAGE_SIZE);

  const select = new StringSelectMenuBuilder()
    .setCustomId(browsePickId(userId, safePage))
    .setPlaceholder("Choose a channel or thread")
    .setMinValues(1)
    .setMaxValues(1)
    .addOptions(
      pageTargets.map((target) => ({
        label: shorten(target.channelName, 100),
        value: target.channelId,
        description: shorten(`${target.kind} • ${target.channelId}`, 100),
      })),
    );

  const content = [
    "**Loki Channel Browser**",
    hint ?? "Pick a channel, then choose what you want Loki to do.",
    `Page ${safePage + 1}/${totalPages} • Showing ${pageTargets.length} of ${targets.length} readable channels/threads`,
    "Example flow: Browse -> pick #general -> Summarize (last 24h).",
  ].join("\n");

  return {
    content,
    components: [
      new ActionRowBuilder<StringSelectMenuBuilder>().addComponents(select),
      new ActionRowBuilder<ButtonBuilder>().addComponents(
        new ButtonBuilder()
          .setCustomId(browseId(userId, safePage - 1))
          .setLabel("Prev")
          .setStyle(ButtonStyle.Secondary)
          .setDisabled(safePage === 0),
        new ButtonBuilder()
          .setCustomId(browseId(userId, safePage + 1))
          .setLabel("Next")
          .setStyle(ButtonStyle.Secondary)
          .setDisabled(safePage >= totalPages - 1),
        new ButtonBuilder().setCustomId(homeId(userId)).setLabel("Back Home").setStyle(ButtonStyle.Secondary),
      ),
    ],
  };
};

const parsePage = (value: string | undefined): number => {
  if (!value) {
    return 0;
  }
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    return 0;
  }
  return parsed;
};

const showSearchModal = async (
  interaction: ButtonInteraction,
  userId: string,
  channelIdOrAll: string,
): Promise<void> => {
  const modal = new ModalBuilder()
    .setCustomId(searchModalId(userId, channelIdOrAll))
    .setTitle(channelIdOrAll === "all" ? "Search server index" : "Search channel index");

  const queryInput = new TextInputBuilder()
    .setCustomId("query")
    .setLabel("What are we looking for?")
    .setPlaceholder("Examples: release blocker, scam link, deploy failure")
    .setRequired(true)
    .setMaxLength(200)
    .setStyle(TextInputStyle.Short);

  modal.addComponents(new ActionRowBuilder<TextInputBuilder>().addComponents(queryInput));
  await interaction.showModal(modal);
};

const showRequestModal = async (
  interaction: ButtonInteraction,
  userId: string,
): Promise<void> => {
  const channelId = interaction.channelId ?? "unknown";
  const modal = new ModalBuilder()
    .setCustomId(requestModalId(userId, channelId))
    .setTitle("Loki Request");

  const promptInput = new TextInputBuilder()
    .setCustomId("prompt")
    .setLabel("What should Loki do?")
    .setPlaceholder("Example: What changed in this channel today?")
    .setRequired(true)
    .setMaxLength(500)
    .setStyle(TextInputStyle.Paragraph);

  modal.addComponents(new ActionRowBuilder<TextInputBuilder>().addComponents(promptInput));
  await interaction.showModal(modal);
};

const buildHomeText = async (guild: Guild, ctx: LokiCommandContext): Promise<string> => {
  const dbStats = ctx.db.getDbStats();
  const backfill = ctx.db.getBackfillSummary();
  const aiReachable = await ctx.ollama.isReachable(ctx.config.ollamaModel);

  return [
    "**Loki Home**",
    `Guild: ${guild.name} (${guild.id})`,
    `Index: messages=${dbStats.messages}, channels=${dbStats.channels}, fts_rows=${dbStats.ftsRows}`,
    `Backfill: tracked=${backfill.totalTrackedChannels}, readable=${backfill.readableChannels}, completed=${backfill.completedBackfills}, last=${backfill.lastBackfillAt ?? "n/a"}`,
    `AI: ${aiReachable ? "reachable" : "unreachable"} (model=${ctx.config.ollamaModel})`,
    "Use the buttons below to navigate. All actions here are private to you.",
  ].join("\n");
};

export const renderLokiHome = async (
  interaction: ChatInputCommandInteraction,
  ctx: LokiCommandContext,
): Promise<void> => {
  if (!interaction.guild) {
    await interaction.editReply("`/loki home` is only available in a server.");
    return;
  }

  const content = await buildHomeText(interaction.guild, ctx);
  await interaction.editReply({
    content,
    components: buildHomeComponents(interaction.user.id),
  });
};

export const exportMessagesToFile = (
  ctx: LokiCommandContext,
  input: {
    guildId: string;
    scope: ExportScope;
    format: ExportFormat;
    channelId?: string;
  },
): ExportResult => {
  if (input.scope === "channel" && !input.channelId) {
    throw new Error("Channel scope requires a channel id.");
  }

  const rows = ctx.db.getMessagesForExport(input.guildId, input.scope === "channel" ? input.channelId : undefined);
  const normalized = rows.map((row) => ({
    id: row.id,
    created_at: row.created_at,
    channel_id: row.channel_id,
    author_id: row.author_id,
    content: row.content,
    content_unavailable: row.content_unavailable === 1,
  }));

  const exportDir = path.join(ctx.config.dataDir, "exports");
  fs.mkdirSync(exportDir, { recursive: true });

  const ts = safeTimestamp();
  const scopePart = input.scope === "channel" ? input.channelId : input.guildId;
  const filePath = path.join(exportDir, `loki_export_${input.scope}_${scopePart}_${ts}.${input.format}`);

  if (input.format === "ndjson") {
    const payload = normalized.map((row) => JSON.stringify(row)).join("\n");
    fs.writeFileSync(filePath, payload.length > 0 ? `${payload}\n` : "", "utf8");
  } else {
    fs.writeFileSync(filePath, `${JSON.stringify(normalized, null, 2)}\n`, "utf8");
  }

  return {
    filePath,
    count: normalized.length,
    scope: input.scope,
    format: input.format,
  };
};

const runChannelSummary = async (
  interaction: ButtonInteraction,
  ctx: LokiCommandContext,
  userId: string,
  channelId: string,
  page: number,
  windowHours: number,
): Promise<void> => {
  const acked = await deferUpdateSafely(
    interaction,
    () => logUnknownInteraction(ctx, interaction.customId),
  );
  if (!acked) {
    return;
  }

  await respondSafely(
    interaction,
    {
      content: `Working on a summary for <#${channelId}> (${windowHours}h window)...`,
      components: [],
    },
    "editOrReply",
    () => logUnknownInteraction(ctx, interaction.customId),
  );

  const result = await ctx.analyzer.summarizeChannelWindow({
    channelId,
    windowHours,
    ai: "on",
  });

  const report = [
    `Summary for <#${channelId}> (${windowHours}h):`,
    result.text,
    "",
    "Tip: use `/loki summarize target:channel id:<channel_id> ai:off` for deterministic output.",
  ].join("\n");

  await respondSafely(
    interaction,
    {
      ...renderBudgetedReport(ctx.config.dataDir, `loki_home_summary_${channelId}`, `# Loki Report\n\n${report}`),
      components: buildChannelActionComponents(userId, channelId, page),
    },
    "editOrReply",
    () => logUnknownInteraction(ctx, interaction.customId),
  );
};

const runIndexServer = async (
  interaction: ButtonInteraction,
  ctx: LokiCommandContext,
  userId: string,
): Promise<void> => {
  if (!interaction.guild) {
    await respondSafely(
      interaction,
      ephemeralReply("Indexing can only run in a server."),
      "replyOrFollowUp",
      () => logUnknownInteraction(ctx, interaction.customId),
    );
    return;
  }

  const acked = await deferUpdateSafely(
    interaction,
    () => logUnknownInteraction(ctx, interaction.customId),
  );
  if (!acked) {
    return;
  }

  await respondSafely(
    interaction,
    {
      content: "Starting full server indexing. I will post progress updates as I go.",
      components: [],
    },
    "editOrReply",
    () => logUnknownInteraction(ctx, interaction.customId),
  );

  let progressTicks = 0;
  const touchedChannels = new Set<string>();

  const summary = await runBackfill(
    interaction.guild,
    {
      db: ctx.db,
      logger: ctx.logger,
      checkpointDir: ctx.config.checkpointDir,
      hasMessageContent: ctx.hasMessageContent,
    },
    {
      scope: "all",
      onProgress: async (progress) => {
        touchedChannels.add(progress.channelId);
        progressTicks += 1;

        if (progress.totalIngested % 200 !== 0 && progress.messagesIngested !== 1) {
          return;
        }

        try {
          await interaction.editReply({
            content: [
              "Indexing in progress...",
              `Channels touched: ${touchedChannels.size}`,
              `Current: ${progress.channelName} (${progress.channelId})`,
              `Total messages ingested: ${progress.totalIngested}`,
            ].join("\n"),
          });
        } catch (error) {
          if (!isUnknownInteractionError(error)) {
            throw error;
          }
        }
      },
    },
  );

  const skippedPreview = summary.skipped.slice(0, 8);
  const skippedText =
    skippedPreview.length > 0
      ? skippedPreview.map((item) => `- ${item.channelId}: ${item.reason}`).join("\n")
      : "- none";

  const completion = [
    "Indexing complete.",
    `Targets considered: ${summary.targetsConsidered}`,
    `Targets processed: ${summary.targetsProcessed}`,
    `Targets skipped: ${summary.targetsSkipped}`,
    `Messages ingested: ${summary.messagesIngested}`,
    "Skipped sample:",
    skippedText,
  ].join("\n");

  await respondSafely(
    interaction,
    {
      ...renderBudgetedReport(ctx.config.dataDir, "loki_home_index", `# Loki Report\n\n${completion}`),
      components: [
        new ActionRowBuilder<ButtonBuilder>().addComponents(
          new ButtonBuilder().setCustomId(homeId(userId)).setLabel("Back Home").setStyle(ButtonStyle.Secondary),
          new ButtonBuilder().setCustomId(browseId(userId, 0)).setLabel("Browse Channels").setStyle(ButtonStyle.Secondary),
        ),
      ],
    },
    "editOrReply",
    () => logUnknownInteraction(ctx, interaction.customId),
  );
};

export const isLokiUiCustomId = (customId: string): boolean => customId.startsWith(`${UI_PREFIX}:`);

export const handleLokiUiInteraction = async (
  interaction: UiInteraction,
  ctx: LokiCommandContext,
): Promise<boolean> => {
  if (!isLokiUiCustomId(interaction.customId)) {
    return false;
  }

  const parts = interaction.customId.split(":");

  if (!interaction.guild) {
    await respondSafely(
      interaction,
      ephemeralReply("This UI only works inside a server."),
      "replyOrFollowUp",
      () => logUnknownInteraction(ctx, interaction.customId),
    );
    return true;
  }

  if (interaction.isButton()) {
    const action = parts[1];
    const channelAction = action === "act" ? parts[5] : undefined;
    const opensModal =
      action === "search" ||
      action === "request" ||
      (action === "act" && channelAction === "search");

    if (!opensModal) {
      const acked = await deferUpdateSafely(
        interaction,
        () => logUnknownInteraction(ctx, interaction.customId),
      );
      if (!acked) {
        return true;
      }
    }

    if (action === "home") {
      const ownerId = parts[2] ?? "";
      if (!(await ensureOwner(interaction, ownerId, ctx))) {
        return true;
      }

      const content = await buildHomeText(interaction.guild, ctx);
      await respondSafely(
        interaction,
        {
          content,
          components: buildHomeComponents(ownerId),
        },
        "editOrReply",
        () => logUnknownInteraction(ctx, interaction.customId),
      );
      return true;
    }

    if (action === "browse") {
      const ownerId = parts[2] ?? "";
      if (!(await ensureOwner(interaction, ownerId, ctx))) {
        return true;
      }

      const page = parsePage(parts[3]);
      const view = await buildBrowserView(interaction.guild, ownerId, page);
      await respondSafely(
        interaction,
        view,
        "editOrReply",
        () => logUnknownInteraction(ctx, interaction.customId),
      );
      return true;
    }

    if (action === "idx") {
      const ownerId = parts[2] ?? "";
      if (!(await ensureOwner(interaction, ownerId, ctx))) {
        return true;
      }
      await runIndexServer(interaction, ctx, ownerId);
      return true;
    }

    if (action === "search") {
      const ownerId = parts[2] ?? "";
      if (!(await ensureOwner(interaction, ownerId, ctx))) {
        return true;
      }
      await showSearchModal(interaction, ownerId, "all");
      return true;
    }

    if (action === "request") {
      const ownerId = parts[2] ?? "";
      if (!(await ensureOwner(interaction, ownerId, ctx))) {
        return true;
      }
      await showRequestModal(interaction, ownerId);
      return true;
    }

    if (action === "sum") {
      const ownerId = parts[2] ?? "";
      if (!(await ensureOwner(interaction, ownerId, ctx))) {
        return true;
      }
      const view = await buildBrowserView(
        interaction.guild,
        ownerId,
        0,
        "Choose a channel first, then use Summarize (last 24h) or Summarize (last 7d).",
      );
      await respondSafely(
        interaction,
        view,
        "editOrReply",
        () => logUnknownInteraction(ctx, interaction.customId),
      );
      return true;
    }

    if (action === "exp") {
      const ownerId = parts[2] ?? "";
      if (!(await ensureOwner(interaction, ownerId, ctx))) {
        return true;
      }

      await respondSafely(
        interaction,
        {
          content: [
            "**Export Workspace**",
            "Pick a format to export the full server index.",
            "For single-channel export, open Browse Channels and choose Export channel.",
          ].join("\n"),
          components: buildExportMenuComponents(ownerId),
        },
        "editOrReply",
        () => logUnknownInteraction(ctx, interaction.customId),
      );
      return true;
    }

    if (action === "expserv") {
      const ownerId = parts[2] ?? "";
      const format = (parts[3] ?? "ndjson") as ExportFormat;
      if (!(await ensureOwner(interaction, ownerId, ctx))) {
        return true;
      }

      const result = exportMessagesToFile(ctx, {
        guildId: interaction.guild.id,
        scope: "server",
        format,
      });

      await respondSafely(
        interaction,
        {
          content: [
            "Export complete.",
            `Scope: ${result.scope}`,
            `Format: ${result.format}`,
            `Messages exported: ${result.count}`,
            `File: ${result.filePath}`,
          ].join("\n"),
          components: buildExportMenuComponents(ownerId),
        },
        "editOrReply",
        () => logUnknownInteraction(ctx, interaction.customId),
      );
      return true;
    }

    if (action === "act") {
      const ownerId = parts[2] ?? "";
      const channelId = parts[3] ?? "";
      const page = parsePage(parts[4]);
      const resolvedAction = parts[5] as "sum24" | "sum168" | "search" | "export";

      if (!(await ensureOwner(interaction, ownerId, ctx))) {
        return true;
      }

      if (resolvedAction === "sum24") {
        await runChannelSummary(interaction, ctx, ownerId, channelId, page, 24);
        return true;
      }

      if (resolvedAction === "sum168") {
        await runChannelSummary(interaction, ctx, ownerId, channelId, page, 168);
        return true;
      }

      if (resolvedAction === "search") {
        await showSearchModal(interaction, ownerId, channelId);
        return true;
      }

      if (resolvedAction === "export") {
        const result = exportMessagesToFile(ctx, {
          guildId: interaction.guild.id,
          scope: "channel",
          channelId,
          format: "ndjson",
        });

        await respondSafely(
          interaction,
          {
            content: [
              `Channel export complete for <#${channelId}>.`,
              `Format: ${result.format}`,
              `Messages exported: ${result.count}`,
              `File: ${result.filePath}`,
              "Tip: use `/loki export scope:channel format:json channel:<id>` for JSON output.",
            ].join("\n"),
            components: buildChannelActionComponents(ownerId, channelId, page),
          },
          "editOrReply",
          () => logUnknownInteraction(ctx, interaction.customId),
        );
        return true;
      }
    }

    await respondSafely(
      interaction,
      ephemeralReply("This UI action is no longer available. Reopen `/loki home`."),
      "replyOrFollowUp",
      () => logUnknownInteraction(ctx, interaction.customId),
    );
    return true;
  }

  if (interaction.isStringSelectMenu()) {
    const action = parts[1];
    if (action !== "pick") {
      await respondSafely(
        interaction,
        ephemeralReply("This selector has expired. Reopen `/loki home`."),
        "replyOrFollowUp",
        () => logUnknownInteraction(ctx, interaction.customId),
      );
      return true;
    }

    const ownerId = parts[2] ?? "";
    const page = parsePage(parts[3]);

    if (!(await ensureOwner(interaction, ownerId, ctx))) {
      return true;
    }

    const acked = await deferUpdateSafely(
      interaction,
      () => logUnknownInteraction(ctx, interaction.customId),
    );
    if (!acked) {
      return true;
    }

    const channelId = interaction.values[0];
    const channel = interaction.guild.channels.cache.get(channelId);
    const channelName = channel && "name" in channel ? channel.name : channelId;

    await respondSafely(
      interaction,
      {
      content: [
        `Selected: ${channelName} (${channelId})`,
        "What should Loki do with this channel?",
        "You can summarize recent activity, search this channel, or export it.",
      ].join("\n"),
      components: buildChannelActionComponents(ownerId, channelId, page),
      },
      "editOrReply",
      () => logUnknownInteraction(ctx, interaction.customId),
    );
    return true;
  }

  if (interaction.isModalSubmit()) {
    const action = parts[1];

    if (action === "reqmodal") {
      const ownerId = parts[2] ?? "";
      const channelId = parts[3] ?? interaction.channelId ?? "";

      if (!(await ensureOwner(interaction, ownerId, ctx))) {
        return true;
      }

      const acked = await deferEphemeralReplySafely(
        interaction,
        () => logUnknownInteraction(ctx, interaction.customId),
      );
      if (!acked) {
        return true;
      }

      const prompt = interaction.fields.getTextInputValue("prompt").trim();
      if (!prompt) {
        await respondSafely(
          interaction,
          "Please provide a request prompt.",
          "editOrReply",
          () => logUnknownInteraction(ctx, interaction.customId),
        );
        return true;
      }

      const result = await runConversationalRequest(
        {
          db: ctx.db,
          defaultModel: ctx.config.ollamaModel,
        },
        {
          prompt,
          scope: "here",
          guildId: interaction.guildId ?? undefined,
          channelId: channelId || interaction.channelId || undefined,
          ai: "on",
        },
      );

      await respondSafely(
        interaction,
        {
          ...renderBudgetedReport(
            ctx.config.dataDir,
            result.reportPrefix,
            `# Loki Report\n\n${result.text}`,
          ),
          components: buildHomeComponents(ownerId),
        },
        "editOrReply",
        () => logUnknownInteraction(ctx, interaction.customId),
      );
      return true;
    }

    if (action !== "modal") {
      await respondSafely(
        interaction,
        ephemeralReply("This modal is no longer active. Reopen `/loki home`."),
        "replyOrFollowUp",
        () => logUnknownInteraction(ctx, interaction.customId),
      );
      return true;
    }

    const ownerId = parts[2] ?? "";
    const channelIdOrAll = parts[3] ?? "all";

    if (!(await ensureOwner(interaction, ownerId, ctx))) {
      return true;
    }

    const acked = await deferEphemeralReplySafely(
      interaction,
      () => logUnknownInteraction(ctx, interaction.customId),
    );
    if (!acked) {
      return true;
    }

    const query = interaction.fields.getTextInputValue("query").trim();
    if (!query) {
      await respondSafely(
        interaction,
        "Please provide a search query.",
        "editOrReply",
        () => logUnknownInteraction(ctx, interaction.customId),
      );
      return true;
    }

    const rows = ctx.db.searchMessages({
      query,
      guildId: interaction.guildId ?? undefined,
      channelId: channelIdOrAll === "all" ? undefined : channelIdOrAll,
      limit: 10,
    });

    if (rows.length === 0) {
      await respondSafely(
        interaction,
        [
          `No results for \"${query}\" in ${channelIdOrAll === "all" ? "server scope" : `<#${channelIdOrAll}>`}.`,
          "Try broader terms (for example: deploy, incident, scam).",
        ].join("\n"),
        "editOrReply",
        () => logUnknownInteraction(ctx, interaction.customId),
      );
      return true;
    }

    const lines = rows.map((row) => {
      const snippet = row.content_unavailable
        ? "[content unavailable: missing message content intent]"
        : (row.content ?? "").replace(/\s+/g, " ").slice(0, 150);
      const jump = row.guild_id ? makeJumpLink(row.guild_id, row.channel_id, row.id) : "n/a";
      return `${row.created_at} | ch=${row.channel_id} | user=${row.author_id} | ${snippet}\n  jump: ${jump}`;
    });

    await respondSafely(
      interaction,
      truncate(
        [
          `Search results for \"${query}\" (${rows.length} rows):`,
          ...lines,
          "",
          "Need filters by user/date? Use `/loki search` with optional fields.",
        ].join("\n"),
      ),
      "editOrReply",
      () => logUnknownInteraction(ctx, interaction.customId),
    );
    return true;
  }

  return true;
};
