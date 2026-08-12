import fs from "node:fs";
import yaml from "js-yaml";
import { z } from "zod";

const policySchema = z.object({
  schemaVersion: z.literal(1),
  moderation: z.object({
    scam_domains: z.array(z.string().min(1)).default([]),
    spam: z.object({
      repeated_messages_threshold: z.number().int().min(2),
      window_seconds: z.number().int().min(1),
    }),
    mass_mentions: z.object({
      threshold: z.number().int().min(1),
    }),
    forbidden_phrases: z.array(z.string()).default([]),
  }),
});

export type LokiPolicy = z.infer<typeof policySchema>;

export class PolicyManager {
  private policy: LokiPolicy;

  constructor(private readonly policyPath: string) {
    this.policy = this.loadFromDisk();
  }

  getPolicy(): LokiPolicy {
    return this.policy;
  }

  reload(): LokiPolicy {
    this.policy = this.loadFromDisk();
    return this.policy;
  }

  show(): string {
    return JSON.stringify(this.policy, null, 2);
  }

  private loadFromDisk(): LokiPolicy {
    const raw = fs.readFileSync(this.policyPath, "utf8");
    const parsed = yaml.load(raw);
    return policySchema.parse(parsed);
  }
}

export const loadPolicyFile = (policyPath: string): LokiPolicy => {
  const raw = fs.readFileSync(policyPath, "utf8");
  const parsed = yaml.load(raw);
  return policySchema.parse(parsed);
};

export const POLICY_SCHEMA_VERSION = 1;
