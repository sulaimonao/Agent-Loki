import { describe, expect, test, vi } from "vitest";
import { DiscordAPIError } from "discord.js";
import {
  deferEphemeralReplySafely,
  deferUpdateSafely,
  ephemeralReply,
  respondSafely,
} from "../src/discord/ui/interaction";

const unknownInteractionError = (): DiscordAPIError => {
  return Object.assign(Object.create(DiscordAPIError.prototype), {
    code: 10062,
    message: "Unknown interaction",
  }) as DiscordAPIError;
};

describe("interaction helper", () => {
  test("respondSafely uses reply when not deferred", async () => {
    const reply = vi.fn(async () => undefined);
    const editReply = vi.fn(async () => undefined);
    const followUp = vi.fn(async () => undefined);

    await respondSafely(
      {
        deferred: false,
        replied: false,
        reply,
        editReply,
        followUp,
      },
      ephemeralReply("hello"),
      "replyOrFollowUp",
    );

    expect(reply).toHaveBeenCalledTimes(1);
    expect(editReply).toHaveBeenCalledTimes(0);
    expect(followUp).toHaveBeenCalledTimes(0);
  });

  test("respondSafely uses editReply when deferred in edit mode", async () => {
    const reply = vi.fn(async () => undefined);
    const editReply = vi.fn(async () => undefined);
    const followUp = vi.fn(async () => undefined);

    await respondSafely(
      {
        deferred: true,
        replied: false,
        reply,
        editReply,
        followUp,
      },
      "updated",
      "editOrReply",
    );

    expect(editReply).toHaveBeenCalledTimes(1);
    expect(reply).toHaveBeenCalledTimes(0);
    expect(followUp).toHaveBeenCalledTimes(0);
  });

  test("defer helpers no-op when already acknowledged", async () => {
    const deferUpdate = vi.fn(async () => undefined);
    const deferReply = vi.fn(async () => undefined);

    const updateOk = await deferUpdateSafely({
      deferred: true,
      replied: false,
      deferUpdate,
    });

    const replyOk = await deferEphemeralReplySafely({
      deferred: false,
      replied: true,
      deferReply,
    });

    expect(updateOk).toBe(true);
    expect(replyOk).toBe(true);
    expect(deferUpdate).toHaveBeenCalledTimes(0);
    expect(deferReply).toHaveBeenCalledTimes(0);
  });

  test("deferUpdateSafely catches unknown interaction and does not throw", async () => {
    const onUnknown = vi.fn();
    const onError = vi.fn();
    const deferUpdate = vi.fn(async () => {
      throw unknownInteractionError();
    });

    const ok = await deferUpdateSafely(
      {
        deferred: false,
        replied: false,
        deferUpdate,
      },
      onUnknown,
      onError,
    );

    expect(ok).toBe(false);
    expect(onUnknown).toHaveBeenCalledTimes(1);
    expect(onError).toHaveBeenCalledTimes(0);
  });

  test("respondSafely catches unknown interaction and does not throw", async () => {
    const onUnknown = vi.fn();
    const onError = vi.fn();
    const editReply = vi.fn(async () => {
      throw unknownInteractionError();
    });

    const ok = await respondSafely(
      {
        deferred: true,
        replied: false,
        reply: vi.fn(async () => undefined),
        editReply,
        followUp: vi.fn(async () => undefined),
      },
      "payload",
      "editOrReply",
      onUnknown,
      onError,
    );

    expect(ok).toBe(false);
    expect(onUnknown).toHaveBeenCalledTimes(1);
    expect(onError).toHaveBeenCalledTimes(0);
  });
});
