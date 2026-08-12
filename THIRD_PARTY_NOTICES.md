# Third-party notices

Agent Loki is licensed under Apache License 2.0. Its dependency graphs contain
software under other licenses. Those licenses apply to their respective
components; they do not replace the Agent Loki license.

## Native macOS dependency

- **Sparkle 2.9.4** — pinned by Swift Package Manager in
  `macos/LokiBrief/LokiBrief.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
  Sparkle is distributed under an MIT-style license and its distribution also
  carries external notices for bundled components. Preserve Sparkle's complete
  `LICENSE` file when redistributing a binary that embeds Sparkle.

## Node.js dependency graph

`package-lock.json` is the authoritative version lock. Direct runtime
dependencies at this release boundary are:

| Package | Locked version | Declared license |
| --- | ---: | --- |
| `better-sqlite3` | 11.10.0 | MIT |
| `discord.js` | 14.25.1 | Apache-2.0 |
| `dotenv` | 16.6.1 | BSD-2-Clause |
| `js-yaml` | 4.1.1 | MIT |
| `zod` | 3.25.76 | MIT |

The development graph includes TypeScript, tsx, Vitest, and their transitive
dependencies. Most locked packages declare MIT, Apache-2.0, ISC, BSD-2-Clause,
BSD-3-Clause, or 0BSD licenses. The graph also contains packages declaring
Python-2.0 or a choice among permissive licenses. Run
`scripts/generate-dependency-inventory.sh` against the exact candidate and
review every nonstandard or dual-license entry before publication.

## Release rule

This file is a repository-level summary, not a substitute for the license text
shipped by a dependency. A source or binary publication must attach the
generated dependency inventory and preserve every license or notice required
by the exact resolved graph. Do not infer a dependency license from memory or
from a package name.

## Models, runtimes, and project artwork

No Ollama runtime or model weights are bundled in the source candidate. Their
separate licenses apply when a user installs them independently.

The candidate contains the two Loki Brief icon masters under
`macos/LokiBrief/Branding/Approved/` and their generated AppIcon renditions.
The release provenance review classifies them as project artwork contributed
to Agent Loki and distributed with this Apache-2.0 source candidate; no
separate artwork or trademark reservation is declared. The final human
publication review still confirms that these exact files are unchanged and
that no later third-party artwork or restriction has been introduced.
