#!/bin/sh
set -eu

dependency_output=''
if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--output" ]; then
    echo "usage: scripts/generate-dependency-inventory.sh [--output FILE]" >&2
    exit 2
  fi
  dependency_output=$2
  [ ! -e "$dependency_output" ] && [ ! -L "$dependency_output" ] || {
    echo "generate-dependency-inventory: refusing to overwrite $dependency_output" >&2
    exit 1
  }
fi

release_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || exit 2
release_root=$(dirname "$release_script_dir")
cd "$release_root"

generate_inventory() {
  node - "$release_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const root = process.argv[2];
const lock = JSON.parse(fs.readFileSync(path.join(root, "package-lock.json"), "utf8"));
const rootPackage = lock.packages?.[""] ?? {};
const direct = new Set([
  ...Object.keys(rootPackage.dependencies ?? {}),
  ...Object.keys(rootPackage.devDependencies ?? {}),
]);
const escapeCell = (value) => String(value ?? "REVIEW_REQUIRED").replaceAll("|", "\\|");

const npmRows = Object.entries(lock.packages ?? {})
  .filter(([location]) => location !== "")
  .map(([location, metadata]) => {
    const marker = "node_modules/";
    const index = location.lastIndexOf(marker);
    const name = metadata.name ?? location.slice(index + marker.length);
    return {
      name,
      location,
      version: metadata.version ?? "UNKNOWN",
      license: metadata.license ?? "REVIEW_REQUIRED",
      direct: direct.has(name) ? "yes" : "no",
    };
  })
  .sort((a, b) => a.location.localeCompare(b.location));

const resolvedPath = path.join(
  root,
  "macos/LokiBrief/LokiBrief.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
);
const resolved = JSON.parse(fs.readFileSync(resolvedPath, "utf8"));
const swiftRows = (resolved.pins ?? [])
  .map((pin) => ({
    identity: pin.identity,
    location: pin.location,
    version: pin.state?.version ?? pin.state?.revision ?? "UNKNOWN",
    revision: pin.state?.revision ?? "UNKNOWN",
  }))
  .sort((a, b) => a.identity.localeCompare(b.identity));

console.log("# Dependency inventory");
console.log("");
console.log("Generated offline from the candidate lockfiles. Verify licenses against the exact downloaded source before publication.");
console.log("");
console.log("## npm packages");
console.log("");
console.log("| Package | Version | Direct | Declared license | Lockfile location |");
console.log("| --- | ---: | :---: | --- | --- |");
for (const row of npmRows) {
  console.log(`| \`${escapeCell(row.name)}\` | ${escapeCell(row.version)} | ${row.direct} | ${escapeCell(row.license)} | \`${escapeCell(row.location)}\` |`);
}
console.log("");
console.log("## Swift Package Manager pins");
console.log("");
console.log("| Identity | Version | Revision | Source | License review |");
console.log("| --- | ---: | --- | --- | --- |");
for (const row of swiftRows) {
  console.log(`| \`${escapeCell(row.identity)}\` | ${escapeCell(row.version)} | \`${escapeCell(row.revision)}\` | ${escapeCell(row.location)} | Review package license and bundled notices |`);
}
NODE
}

if [ -z "$dependency_output" ]; then
  generate_inventory
  exit 0
fi

dependency_parent=$(dirname "$dependency_output")
[ -d "$dependency_parent" ] || {
  echo "generate-dependency-inventory: output directory does not exist" >&2
  exit 2
}
dependency_temp=$(mktemp "${dependency_output}.tmp.XXXXXX")
trap 'rm -f "$dependency_temp"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077
generate_inventory > "$dependency_temp"
chmod 0644 "$dependency_temp"
mv "$dependency_temp" "$dependency_output"
trap - EXIT HUP INT TERM
echo "$dependency_output"
