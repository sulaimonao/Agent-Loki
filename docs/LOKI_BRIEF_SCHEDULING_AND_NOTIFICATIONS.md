# Loki Brief scheduling and notifications

## What must remain running

Scheduled briefs run inside the Loki Brief menu-bar application. Closing its main window does not quit it. Menu-bar actions, Dock activation, **Open Today**, and valid notification selection activate or reuse the same logical main window. Choosing **Quit Loki Brief** stops the process and pauses scheduled delivery until the app is opened again.

Launch at login is optional and off until explicitly enabled. When enabled and approved by macOS, the main Loki Brief app launches on subsequent user logins. Loki Brief does not install a helper, LaunchAgent, daemon, or privileged component.

## Delivery settings

The Delivery settings surface controls:

- schedule enabled state, local time, weekdays, and time-zone behavior;
- missed-run policy and grace window;
- participating connected sources;
- optional scheduled Ollama presentation consent;
- pause in Low Power Mode;
- launch-at-login preference and actual system status;
- notification preference, actual authorization, and privacy mode;
- Generate Brief Now, cancellation, and recent delivery history.

The displayed next occurrence is calculated from the saved recurrence and current system state. It is not a promise that macOS will keep a quit, logged-out, or sleeping process running.

## Missed-run examples

With the default six-hour grace window, a 06:00 brief can run once after a 07:10 wake. Opening Loki Brief at 20:00 records that occurrence as skipped because it is outside the grace window. After several days away, Loki Brief considers only the newest eligible occurrence and never creates an automatic historical catch-up chain.

## Daylight saving and time zones

If the selected local time does not exist during spring-forward, Loki Brief uses the next valid time on that same local day. If the selected time occurs twice during fall-back, Loki Brief uses the first occurrence and the ledger prevents a second success. Following the system time zone recalculates future occurrences; fixed-zone schedules keep the selected zone.

## Notifications

Loki Brief asks for notification permission only after **Enable Notifications** is selected. If permission is denied, brief generation continues and Delivery settings report the block without repeatedly prompting.

The default notification is deliberately minimal:

> Loki Brief is ready
>
> Your daily brief is ready.

The optional **Summary** privacy mode adds bounded counts only:

> Loki Brief is ready
>
> 8 items from 3 sources

Notification bodies do not include Slack excerpts, workspace or channel names, account or author names, email addresses, private URLs, search terms, prompts, or model output. Selecting a valid brief notification opens that persisted brief on Today. Notification delivery is best effort: a submitted notification is not reported as seen unless the user selects it.

## Local generation

Deterministic evidence selection and ordering are always authoritative. Scheduled Ollama presentation is separately configurable and off by default. It also respects each Slack workspace’s local-model consent. If Ollama is unavailable, disabled, missing a selected model, times out, is canceled, or returns invalid output, Loki Brief completes with deterministic presentation. It never starts Ollama or downloads a model.

## Sleep, power, and network

Loki Brief cancels or safely finishes narrowly bounded work before sleep, then recalculates on wake. With **Pause in Low Power Mode** enabled, scheduled synchronization defers and applies the saved catch-up policy later. Source clients still enforce their own timeouts and network safety; no background monitor or power assertion keeps the Mac awake.

## Troubleshooting

- **Schedule enabled, no run:** confirm Loki Brief is open in the menu bar or enable launch at login. Explicit Quit pauses delivery.
- **Launch approval required:** use **Open Login Items Settings**, approve Loki Brief if desired, then refresh status.
- **Notifications denied:** open macOS Notifications settings and enable Loki Brief; generation remains available meanwhile.
- **Slack unavailable:** configure and connect Slack, then select channels. Feed-only and local-evidence runs can continue without Slack.
- **Ollama fallback:** open Local Models to check the loopback provider and selected installed model. Deterministic delivery remains valid.
- **Interrupted run:** reopen Loki Brief. It marks incomplete work truthfully, reconciles the newest eligible occurrence, and avoids duplicate successful slots.

## Privacy and deletion

Delivery history contains timing, consumer-safe trigger/result labels, bounded counts, brief link, notification result, and bounded status explanations—not private source text or raw internal reason codes. Stable reason codes remain available only in local structured evidence. **Delete All Local Data** cancels active delivery work, removes schedule/run/delivery records and local notifications, removes the existing local data planes covered by the product contract, and rejects late callbacks.
