import fs from "node:fs";
import path from "node:path";
import { AttachmentBuilder, type InteractionEditReplyOptions } from "discord.js";

export interface MarkdownReportResult {
  filePath: string;
  fileName: string;
}

const PREVIEW_BUDGET = 1500;

const safeTimestamp = (): string => new Date().toISOString().replace(/[.:]/g, "-");

export const writeMarkdownReport = (
  dataDir: string,
  prefix: string,
  markdown: string,
): MarkdownReportResult => {
  const exportDir = path.join(dataDir, "exports");
  fs.mkdirSync(exportDir, { recursive: true });

  const fileName = `${prefix}_${safeTimestamp()}.md`;
  const filePath = path.join(exportDir, fileName);
  fs.writeFileSync(filePath, `${markdown}\n`, "utf8");

  return { filePath, fileName };
};

export const renderBudgetedReport = (
  dataDir: string,
  prefix: string,
  report: string,
): InteractionEditReplyOptions => {
  if (report.length <= PREVIEW_BUDGET) {
    return { content: report };
  }

  const written = writeMarkdownReport(dataDir, prefix, report);
  const preview = `${report.slice(0, PREVIEW_BUDGET)}\n...`;

  return {
    content: [
      preview,
      "",
      "Attached full report.",
      `Attached report: ${written.filePath}`,
    ].join("\n"),
    files: [new AttachmentBuilder(written.filePath, { name: written.fileName })],
  };
};
