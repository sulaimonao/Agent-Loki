import type { PendingApprovalRecord } from "../storage/db";
import { LokiDb } from "../storage/db";
import { NdjsonLogger } from "../storage/ndjson";

export interface ApprovalActionPayload {
  guildId?: string | null;
  channelId?: string | null;
  targetUserId?: string | null;
  action: string;
  reason?: string | null;
  evidence: Record<string, unknown>;
  execution: Record<string, unknown>;
  requestedBy?: string | null;
}

export interface ApprovalResult {
  executed: boolean;
  message: string;
}

const makeId = (): string => {
  const rand = Math.random().toString(36).slice(2, 8);
  return `apr_${Date.now()}_${rand}`;
};

export class ApprovalService {
  constructor(
    private readonly db: LokiDb,
    private readonly logger: NdjsonLogger,
    private readonly enforcementEnabled: boolean,
  ) {}

  createPendingApproval(payload: ApprovalActionPayload): string {
    const id = makeId();
    const ts = new Date().toISOString();

    this.db.queueApproval({
      id,
      ts,
      guildId: payload.guildId,
      channelId: payload.channelId,
      targetUserId: payload.targetUserId,
      action: payload.action,
      reason: payload.reason,
      payloadJson: JSON.stringify(payload),
      requestedBy: payload.requestedBy,
      status: "pending",
    });

    this.logger.logEvent("approval.pending", {
      id,
      ts,
      action: payload.action,
      reason: payload.reason,
      channelId: payload.channelId,
      targetUserId: payload.targetUserId,
      requestedBy: payload.requestedBy,
    });

    const modActionId = `mod_pending_${id}`;
    this.db.insertModAction({
      id: modActionId,
      ts,
      guildId: payload.guildId,
      channelId: payload.channelId,
      targetUserId: payload.targetUserId,
      action: `suggest:${payload.action}`,
      reason: payload.reason,
      approvedBy: null,
      evidenceJson: JSON.stringify(payload.evidence),
    });

    this.logger.logModAction({
      id: modActionId,
      ts,
      status: "pending",
      action: payload.action,
      reason: payload.reason,
      evidence: payload.evidence,
      execution: payload.execution,
    });

    return id;
  }

  getPendingApproval(id: string): PendingApprovalRecord | undefined {
    return this.db.getPendingApproval(id);
  }

  async approveAndExecute(
    id: string,
    approvedBy: string,
    executor: (record: PendingApprovalRecord, payload: ApprovalActionPayload) => Promise<void>,
  ): Promise<ApprovalResult> {
    const record = this.db.getPendingApproval(id);
    if (!record) {
      return {
        executed: false,
        message: `No pending action found for id ${id}.`,
      };
    }

    if (record.status !== "pending") {
      return {
        executed: false,
        message: `Action ${id} is already ${record.status}.`,
      };
    }

    if (!this.enforcementEnabled) {
      return {
        executed: false,
        message:
          "Enforcement is disabled (`ENABLE_ENFORCEMENT=false`). Suggestion remains pending and was not executed.",
      };
    }

    const parsed = JSON.parse(record.payloadJson) as ApprovalActionPayload;
    await executor(record, parsed);

    this.db.markApprovalApproved(id, approvedBy);
    this.db.markApprovalExecuted(id, approvedBy);

    const modActionId = `mod_${id}`;
    const ts = new Date().toISOString();

    this.db.insertModAction({
      id: modActionId,
      ts,
      guildId: record.guildId,
      channelId: record.channelId,
      targetUserId: record.targetUserId,
      action: record.action,
      reason: record.reason,
      approvedBy,
      evidenceJson: JSON.stringify(parsed.evidence),
    });

    this.logger.logModAction({
      id: modActionId,
      ts,
      approvedBy,
      action: record.action,
      reason: record.reason,
      payload: parsed,
    });

    return {
      executed: true,
      message: `Action ${id} executed: ${record.action}.`,
    };
  }
}
