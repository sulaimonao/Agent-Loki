import { describe, expect, test } from "vitest";
import { makeJumpLink } from "../src/ai/analyzer";

describe("jump link", () => {
  test("formats Discord jump links", () => {
    const url = makeJumpLink("g1", "c1", "m1");
    expect(url).toBe("https://discord.com/channels/g1/c1/m1");
  });
});
