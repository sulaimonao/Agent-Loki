import {
  DiscordAPIError,
  MessageFlags,
  type InteractionEditReplyOptions,
  type InteractionReplyOptions,
} from "discord.js";

export const isUnknownInteractionError = (error: unknown): boolean => {
  return error instanceof DiscordAPIError && error.code === 10062;
};

export const ephemeralReply = (content: string): InteractionReplyOptions => ({
  content,
  flags: MessageFlags.Ephemeral,
});

export const withEphemeralFlags = <T extends Record<string, unknown>>(
  options: T,
): T & { flags: MessageFlags.Ephemeral } => {
  return {
    ...options,
    flags: MessageFlags.Ephemeral,
  };
};

export const deferUpdateSafely = async (
  interaction: {
    deferred: boolean;
    replied: boolean;
    deferUpdate: () => Promise<unknown>;
  },
  onUnknownInteraction?: () => void,
  onError?: (error: unknown) => void,
): Promise<boolean> => {
  if (interaction.deferred || interaction.replied) {
    return true;
  }

  try {
    await interaction.deferUpdate();
    return true;
  } catch (error) {
    if (isUnknownInteractionError(error)) {
      onUnknownInteraction?.();
      return false;
    }
    onError?.(error);
    return false;
  }
};

export const deferEphemeralReplySafely = async (
  interaction: {
    deferred: boolean;
    replied: boolean;
    deferReply: (...args: any[]) => Promise<unknown>;
  },
  onUnknownInteraction?: () => void,
  onError?: (error: unknown) => void,
): Promise<boolean> => {
  if (interaction.deferred || interaction.replied) {
    return true;
  }

  try {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });
    return true;
  } catch (error) {
    if (isUnknownInteractionError(error)) {
      onUnknownInteraction?.();
      return false;
    }
    onError?.(error);
    return false;
  }
};

export const respondSafely = async (
  interaction: {
    deferred: boolean;
    replied: boolean;
    reply: (options: InteractionReplyOptions) => Promise<unknown>;
    editReply: (options: string | InteractionEditReplyOptions) => Promise<unknown>;
    followUp: (options: InteractionReplyOptions) => Promise<unknown>;
  },
  payload: InteractionReplyOptions | InteractionEditReplyOptions | string,
  mode: "editOrReply" | "replyOrFollowUp" = "editOrReply",
  onUnknownInteraction?: () => void,
  onError?: (error: unknown) => void,
): Promise<boolean> => {
  try {
    if (mode === "editOrReply") {
      if (interaction.deferred || interaction.replied) {
        await interaction.editReply(payload as string | InteractionEditReplyOptions);
      } else {
        if (typeof payload === "string") {
          await interaction.reply({ content: payload });
        } else {
          await interaction.reply(payload as InteractionReplyOptions);
        }
      }
      return true;
    }

    if (interaction.deferred || interaction.replied) {
      if (typeof payload === "string") {
        await interaction.followUp({ content: payload });
      } else {
        await interaction.followUp(payload as InteractionReplyOptions);
      }
      return true;
    }

    if (typeof payload === "string") {
      await interaction.reply({ content: payload });
    } else {
      await interaction.reply(payload as InteractionReplyOptions);
    }
    return true;
  } catch (error) {
    if (isUnknownInteractionError(error)) {
      onUnknownInteraction?.();
      return false;
    }
    onError?.(error);
    return false;
  }
};
