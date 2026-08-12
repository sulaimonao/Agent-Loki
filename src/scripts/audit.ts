import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import yaml from "js-yaml";
import { writeDerivedPhaseStatus } from "../status/phase";

const root = process.cwd();
const failures: string[] = [];

const assert = (condition: boolean, message: string): void => {
  if (!condition) {
    failures.push(message);
  }
};

const envExamplePath = path.join(root, ".env.example");
if (fs.existsSync(envExamplePath)) {
  const envExample = fs.readFileSync(envExamplePath, "utf8");
  assert(
    envExample.includes("DISCORD_TOKEN=") && envExample.includes("DISCORD_CLIENT_ID="),
    ".env.example must include Discord credential keys",
  );
  assert(
    envExample.includes("ENABLE_ENFORCEMENT=false"),
    ".env.example must set ENABLE_ENFORCEMENT=false",
  );
} else {
  failures.push("Missing .env.example");
}

const policyPath = path.join(root, "config", "loki.yaml");
if (fs.existsSync(policyPath)) {
  const parsed = yaml.load(fs.readFileSync(policyPath, "utf8")) as { schemaVersion?: number };
  assert(parsed.schemaVersion === 1, "config/loki.yaml schemaVersion must be 1");
} else {
  failures.push("Missing config/loki.yaml");
}

const schemaPath = path.join(root, "src", "storage", "schema.ts");
if (fs.existsSync(schemaPath)) {
  const schemaFile = fs.readFileSync(schemaPath, "utf8");
  const match = schemaFile.match(/SCHEMA_VERSION\s*=\s*(\d+)/);
  assert(Boolean(match), "SCHEMA_VERSION constant missing in src/storage/schema.ts");
  if (match) {
    assert(Number(match[1]) === 1, `Expected SCHEMA_VERSION=1, got ${match[1]}`);
  }
} else {
  failures.push("Missing src/storage/schema.ts");
}

const configPath = path.join(root, "src", "config.ts");
if (fs.existsSync(configPath)) {
  const configFile = fs.readFileSync(configPath, "utf8");
  assert(
    configFile.includes("toBoolean(process.env.ENABLE_ENFORCEMENT, false)"),
    "src/config.ts must default ENABLE_ENFORCEMENT to false",
  );
} else {
  failures.push("Missing src/config.ts");
}

if (failures.length > 0) {
  console.error("Audit failed before tests:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

const testRun = spawnSync("npm", ["test"], {
  cwd: root,
  stdio: "inherit",
  shell: process.platform === "win32",
});
if (testRun.status !== 0) {
  console.error("Audit failed: tests did not pass.");
  process.exit(testRun.status ?? 1);
}

const statusPath = path.join(root, "data", "status.json");
const lastUpdated = new Date().toISOString().slice(0, 10);
writeDerivedPhaseStatus(statusPath, {
  phase: "Public Baseline",
  status: "READY",
  lastUpdated,
});

console.log("Audit passed.");
console.log(`Derived status written to ${statusPath}`);
