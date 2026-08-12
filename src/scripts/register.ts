import { REST, Routes } from "discord.js";
import { assertDiscordEnv, loadConfig } from "../config";
import { buildLokiCommand } from "../discord/commands/loki";
import { validateRequiredOptionsBeforeOptional } from "./validateCommandOptions";

const run = async (): Promise<void> => {
  const config = loadConfig();
  assertDiscordEnv(config);

  const rest = new REST({ version: "10" }).setToken(config.discordToken);
  const command = buildLokiCommand().toJSON();
  const validationErrors = validateRequiredOptionsBeforeOptional(command);

  if (validationErrors.length > 0) {
    console.error("Command preflight failed: required options must be defined before optional options.");
    for (const error of validationErrors) {
      console.error(`- ${error}`);
    }
    process.exit(1);
  }

  if (!config.discordGuildId || !config.guildAllowlist.includes(config.discordGuildId)) {
    throw new Error(
      "DISCORD_GUILD_ID must name one guild in GUILD_ALLOWLIST; global command registration is disabled.",
    );
  }

  await rest.put(Routes.applicationGuildCommands(config.discordClientId, config.discordGuildId), {
    body: [command],
  });
  console.log("Registered /loki for the explicitly allowlisted guild.");
};

run().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : "unknown register error";
  console.error(`Register failed: ${message}`);
  process.exit(1);
});
