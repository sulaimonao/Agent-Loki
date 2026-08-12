#!/bin/bash
set -euo pipefail

RELEASE_PROGRAM=generate-sbom
release_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=release-common.sh
source "$release_script_dir/release-common.sh"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/generate-sbom.sh --tag TAG --artifact-root ABSOLUTE_DIR [--dry-run]

Generates a deterministic SPDX 2.3 JSON dependency SBOM from the exact tagged
package-lock.json and Swift Package.resolved. It performs no dependency
resolution, installation, or network access.
USAGE
}

release_tag=
artifact_root_input=
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      release_require_value "$1" "${2-}"
      release_tag=$2
      shift 2
      ;;
    --artifact-root)
      release_require_value "$1" "${2-}"
      artifact_root_input=$2
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      release_usage_error "unknown argument: $1"
      ;;
  esac
done

[[ -n "$release_tag" && -n "$artifact_root_input" ]] || {
  usage
  release_usage_error "--tag and --artifact-root are required"
}

release_root=$(release_repository_root_from_script "$release_script_dir")
artifact_root=$(release_resolve_existing_directory "$artifact_root_input")
release_assert_artifact_root "$release_root" "$artifact_root"
release_assert_repo_clean_tag "$release_root" "$release_tag"
release_assert_release_metadata "$release_root" "$release_tag"

asset_prefix=$(release_asset_prefix "$release_tag")
sbom_path="$artifact_root/${asset_prefix}-SBOM.spdx.json"
release_assert_output_absent "$sbom_path"
lockfile="$release_root/package-lock.json"
resolved_file="$release_root/macos/LokiBrief/LokiBrief.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[[ -f "$lockfile" && -f "$resolved_file" ]] ||
  release_die "package-lock.json and Package.resolved are required"

if [[ "$dry_run" == true ]]; then
  printf 'DRY-RUN: generate SPDX 2.3 JSON offline from package-lock.json and Package.resolved\n'
  printf 'generate-sbom: output=%s\n' "$(basename "$sbom_path")"
  printf 'generate-sbom: execution=not-requested\n'
  exit 0
fi

release_require_command node
release_commit=$(git -C "$release_root" rev-parse "refs/tags/$release_tag^{commit}")
release_epoch=$(git -C "$release_root" show -s --format=%ct "$release_commit")
temporary_sbom=$(mktemp "$artifact_root/.${asset_prefix}-SBOM.XXXXXX")
trap 'rm -f "$temporary_sbom"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

node - "$release_root" "$release_tag" "$release_commit" "$release_epoch" "$temporary_sbom" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const [root, tag, commit, epoch, output] = process.argv.slice(2);
const sourceVersion = tag.slice(1);
const created = new Date(Number(epoch) * 1000).toISOString().replace(".000Z", "Z");
const packageJson = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
const lock = JSON.parse(fs.readFileSync(path.join(root, "package-lock.json"), "utf8"));
const resolved = JSON.parse(fs.readFileSync(path.join(
  root,
  "macos/LokiBrief/LokiBrief.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
), "utf8"));

const spdxId = (kind, identity) =>
  `SPDXRef-Package-${kind}-${crypto.createHash("sha256").update(identity).digest("hex").slice(0, 16)}`;
const safeLicense = (value) => {
  if (typeof value !== "string") return "NOASSERTION";
  return /^[A-Za-z0-9.+-]+(?:\s+(?:AND|OR|WITH)\s+[A-Za-z0-9.+-]+)*$/.test(value)
    ? value
    : "NOASSERTION";
};
const safeDownload = (value) => {
  if (typeof value !== "string" || value.length === 0) return "NOASSERTION";
  try {
    const url = new URL(value);
    if (!["https:", "http:"].includes(url.protocol) || url.username || url.password) return "NOASSERTION";
    return url.toString();
  } catch {
    return "NOASSERTION";
  }
};

const rootId = "SPDXRef-Package-Agent-Loki";
const packages = [{
  SPDXID: rootId,
  downloadLocation: "NOASSERTION",
  filesAnalyzed: false,
  licenseConcluded: "NOASSERTION",
  licenseDeclared: safeLicense(packageJson.license),
  name: "Agent Loki",
  versionInfo: sourceVersion,
}];

const dependencies = [];
for (const [location, metadata] of Object.entries(lock.packages ?? {})) {
  if (location === "") continue;
  const marker = "node_modules/";
  const markerIndex = location.lastIndexOf(marker);
  const name = metadata.name ?? location.slice(markerIndex + marker.length);
  dependencies.push({
    kind: "npm",
    identity: location,
    package: {
      SPDXID: spdxId("npm", location),
      downloadLocation: safeDownload(metadata.resolved),
      filesAnalyzed: false,
      licenseConcluded: "NOASSERTION",
      licenseDeclared: safeLicense(metadata.license),
      name,
      versionInfo: metadata.version ?? "UNKNOWN",
    },
  });
}

for (const pin of resolved.pins ?? []) {
  const identity = String(pin.identity ?? pin.location ?? "unknown");
  dependencies.push({
    kind: "swiftpm",
    identity,
    package: {
      SPDXID: spdxId("swiftpm", identity),
      downloadLocation: safeDownload(pin.location),
      filesAnalyzed: false,
      licenseConcluded: "NOASSERTION",
      licenseDeclared: "NOASSERTION",
      name: identity,
      versionInfo: pin.state?.version ?? pin.state?.revision ?? "UNKNOWN",
    },
  });
}

dependencies.sort((left, right) =>
  `${left.kind}:${left.identity}`.localeCompare(`${right.kind}:${right.identity}`, "en"));
for (const dependency of dependencies) packages.push(dependency.package);

const document = {
  SPDXID: "SPDXRef-DOCUMENT",
  creationInfo: {
    created,
    creators: ["Tool: Agent-Loki/scripts/generate-sbom.sh"],
  },
  dataLicense: "CC0-1.0",
  documentDescribes: [rootId],
  documentNamespace: `https://spdx.org/spdxdocs/agent-loki-${tag}-${commit}`,
  name: `Agent-Loki-${tag}-SBOM`,
  packages,
  relationships: dependencies.map((dependency) => ({
    relatedSpdxElement: dependency.package.SPDXID,
    relationshipType: "DEPENDS_ON",
    spdxElementId: rootId,
  })),
  spdxVersion: "SPDX-2.3",
};

fs.writeFileSync(output, `${JSON.stringify(document, null, 2)}\n`, { encoding: "utf8" });
NODE

node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))' "$temporary_sbom"
chmod 0644 "$temporary_sbom"
mv "$temporary_sbom" "$sbom_path"
trap - EXIT HUP INT TERM
printf '%s\n' "$sbom_path"
