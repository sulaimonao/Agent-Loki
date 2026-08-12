import { describe, expect, test } from "vitest";
import { buildLokiCommand } from "../src/discord/commands/loki";
import { validateRequiredOptionsBeforeOptional } from "../src/scripts/validateCommandOptions";

describe("loki command definition", () => {
  test("keeps required options before optional options", () => {
    const command = buildLokiCommand().toJSON();
    const errors = validateRequiredOptionsBeforeOptional(command);
    expect(errors).toEqual([]);
  });

  test("defines /loki ask options", () => {
    const command = buildLokiCommand().toJSON();
    const ask = command.options?.find((option) => option.name === "ask");

    expect(ask).toBeDefined();
    expect(ask?.options?.map((option) => option.name)).toEqual([
      "prompt",
      "scope",
      "channel",
      "window",
      "limit",
      "model",
    ]);
    expect(ask?.options?.[0]?.required).toBe(true);
  });

  test("defines /loki request options", () => {
    const command = buildLokiCommand().toJSON();
    const request = command.options?.find((option) => option.name === "request");

    expect(request).toBeDefined();
    expect(request?.options?.map((option) => option.name)).toEqual([
      "prompt",
      "scope",
      "window",
      "model",
      "ai",
    ]);
    expect(request?.options?.[0]?.required).toBe(true);
  });

  test("defines /loki chat subcommands", () => {
    const command = buildLokiCommand().toJSON();
    const chat = command.options?.find((option) => option.name === "chat");

    expect(chat).toBeDefined();
    expect(chat?.type).toBe(2);
    expect(chat?.options?.map((option) => option.name)).toEqual([
      "status",
      "enable",
      "disable",
      "mode",
      "thread",
    ]);
  });

  test("defines /loki index subcommands", () => {
    const command = buildLokiCommand().toJSON();
    const index = command.options?.find((option) => option.name === "index");

    expect(index).toBeDefined();
    expect(index?.type).toBe(2);
    expect(index?.options?.map((option) => option.name)).toEqual([
      "status",
      "run",
      "verify",
    ]);
  });

  test("defines /loki isolation subcommands", () => {
    const command = buildLokiCommand().toJSON();
    const isolation = command.options?.find((option) => option.name === "isolation");

    expect(isolation).toBeDefined();
    expect(isolation?.type).toBe(2);
    expect(isolation?.options?.map((option) => option.name)).toEqual([
      "status",
    ]);
  });

  test("defines /loki db subcommands", () => {
    const command = buildLokiCommand().toJSON();
    const db = command.options?.find((option) => option.name === "db");

    expect(db).toBeDefined();
    expect(db?.type).toBe(2);
    expect(db?.options?.map((option) => option.name)).toEqual([
      "verify",
    ]);
  });
});
