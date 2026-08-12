import fs from "node:fs";
import path from "node:path";

export interface EventRecord {
  ts: string;
  type: string;
  payload: unknown;
}

export class NdjsonLogger {
  private readonly messagesPath: string;
  private readonly eventsPath: string;
  private readonly modActionsPath: string;

  constructor(logDir: string) {
    fs.mkdirSync(logDir, { recursive: true });
    this.messagesPath = path.join(logDir, "messages.ndjson");
    this.eventsPath = path.join(logDir, "events.ndjson");
    this.modActionsPath = path.join(logDir, "mod_actions.ndjson");
  }

  logMessage(payload: unknown): void {
    this.append(this.messagesPath, payload);
  }

  logEvent(type: string, payload: unknown): void {
    const record: EventRecord = {
      ts: new Date().toISOString(),
      type,
      payload,
    };
    this.append(this.eventsPath, record);
  }

  logModAction(payload: unknown): void {
    this.append(this.modActionsPath, payload);
  }

  private append(filePath: string, payload: unknown): void {
    fs.appendFileSync(filePath, `${JSON.stringify(payload)}\n`, "utf8");
  }
}
