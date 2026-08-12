import fs from "node:fs";
import path from "node:path";

export interface PhaseStatus {
  phase: string;
  status: string;
  lastUpdated?: string;
  source: "markdown" | "json";
}

interface PhaseStatusJson {
  phase: string;
  status: string;
  lastUpdated?: string;
}

const parseMarkdown = (content: string): PhaseStatus => {
  const phaseMatch = content.match(/^Current Phase:\s*(.+)$/m);
  const statusMatch = content.match(/^Current Status:\s*(.+)$/m);
  const updatedMatch = content.match(/^Last Updated:\s*(.+)$/m);

  return {
    phase: phaseMatch?.[1]?.trim() ?? "Unknown",
    status: statusMatch?.[1]?.trim() ?? "UNKNOWN",
    lastUpdated: updatedMatch?.[1]?.trim(),
    source: "markdown",
  };
};

export const readPhaseStatus = (
  rootDir: string = process.cwd(),
  statusJsonPath: string = path.join(rootDir, "data", "status.json"),
): PhaseStatus => {
  if (fs.existsSync(statusJsonPath)) {
    const data = JSON.parse(fs.readFileSync(statusJsonPath, "utf8")) as PhaseStatusJson;
    return {
      phase: data.phase,
      status: data.status,
      lastUpdated: data.lastUpdated,
      source: "json",
    };
  }

  const markdownPath = path.join(rootDir, "PHASE_STATUS.md");
  if (!fs.existsSync(markdownPath)) {
    return {
      phase: "Unknown",
      status: "UNKNOWN",
      source: "markdown",
    };
  }

  return parseMarkdown(fs.readFileSync(markdownPath, "utf8"));
};

export const writeDerivedPhaseStatus = (
  targetPath: string,
  status: Omit<PhaseStatus, "source">,
): void => {
  const payload: PhaseStatusJson = {
    phase: status.phase,
    status: status.status,
    lastUpdated: status.lastUpdated,
  };
  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
  fs.writeFileSync(targetPath, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
};
