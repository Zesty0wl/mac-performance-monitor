# Security Policy

Mac Performance Monitor reads process, memory, and device data. It keeps that
history and alert evidence on your Mac. It sends no usage telemetry, but it
does use the network. For example, it checks for updates and runs network tests.

## Reporting a vulnerability

Report security issues in private, not in a public issue.

- Use GitHub's private vulnerability reporting (the "Report a vulnerability"
  button under the repository's **Security** tab), or
- contact the maintainers at the address listed on the repository profile.

Tell us what went wrong, which version or commit you used, and how to repeat it.
We will confirm receipt, look into the issue, and keep you informed about a fix.
Please allow time for that work before making the report public.

## Supported versions

Fixes target the latest release and current development branches. Include the
version and build number when reporting an issue, plus the commit for a source
build. Older releases may not receive the same fixes.

## Privacy posture

- No usage telemetry or analytics. With recording on, the app stores full
  performance history in a local SQLite database.

- **Usage Timeline** can read Apple's local activity history. Each window starts
  with this off, even if the app already has Full Disk Access. Turning it on
  reads only app-usage and media intervals for the selected app bundle in the
  current user's account. These rows do not verify the source device or process.
  The read does not change Apple's database. The app keeps the rows in that
  window's memory and clears them when switched off or closed. It does not add
  them to saved performance history, trace exports, or network requests.

- Alert state uses separate local files. They can hold process names, paths,
  IDs, and evidence even with full history off. See
  [Adaptive alerts](docs/adaptive-alerts.md#local-evidence) for the limits.

- **Ask preview**, on-device AI, and Siri/Shortcuts sharing each start off.
  Report selection sends only the question and previous topic to Apple's local
  model. Generate explanations from evidence needs separate consent. It passes
  selected readings, process names, and bounded results from recorded history to
  the chosen local model. The model can request system history, process rankings,
  process search, and a selected process's history. The app runs fixed read-only
  queries, not SQL supplied by the model. Each investigation allows at most four
  checks over the past seven days, with row and output limits. It excludes full
  paths, raw row dumps, and file trees. Closing Ask clears the question, short
  follow-up context, checked-evidence list, and generated explanation.

- **Apple on-device** is the default model for new selections. Foundation Models
  uses Apple's local system model; macOS manages its download and availability.
  It needs no Qwen download. Ask keeps existing model choices and never silently
  falls back to Qwen or a cloud model. All models use the consent and read-only
  limits above. Source checks do not prove that a generated diagnosis is correct.

- **Qwen** is an optional local model for Apple silicon Macs with at least
  16 GiB RAM. Enabling explanations with Qwen selected starts its download;
  selecting Qwen while explanations are enabled does the same. The download
  contacts Hugging Face and its HTTPS download hosts,
  which receive normal request metadata such as the IP address. The app checks
  pinned file sizes and SHA-256 hashes. Inference runs from local files in a
  separate unprivileged process, with pressure checks and a two-minute deadline.
  The worker requests data through bounded messages; it has no direct database
  connection or access to the privileged helper. The app validates tool arguments
  and citations against the results it supplied. No cloud inference, shell tools,
  prompt logging, or saved conversations are used. Apple manages its own model.
  Remove Model deletes the downloaded weights. Disabling AI does not delete them.

- **Qwen3.5 4B and DeepAnalyze 8B** are experimental local choices. Each needs an
  explicit Download action and has a separate cache and removal control. Downloads
  use Hugging Face and its HTTPS hosts; some licence files come from GitHub's
  raw-file host. Revisions, sizes, and hashes are pinned. DeepAnalyze uses a
  third-party GGUF conversion with upstream attribution, loaded by a pinned
  llama.cpp framework in the worker. Its code training grants no code-execution
  tools. All worker output passes the same host-owned tool and evidence checks.
  Only one local worker can run at a time. The existing RAM, pressure, context,
  output, and deadline limits remain; DeepAnalyze also has an 8 GiB resident-memory
  ceiling. Model files do not ship in the app, and no cloud fallback is used.

- Siri/Shortcuts sharing is separate from in-app AI consent. Shared reports can
  include process names and resource use. Apple controls Siri processing, and
  Shortcuts can pass results to other actions. Do not assume this path stays
  on-device. The app holds at most eight report references in memory, with a
  five-minute validity period. Turning sharing off clears those references.
  This preview does not index reports or process history in Spotlight.

- CSV, traces, hardware reports, and screenshots can contain private details.
  Check them before sharing. Exports keep the original names and paths; they
  do not hide who or what the data describes.

- Sparkle checks for and downloads updates. The app also downloads signed
  checks and glossary content. Network tools contact the hosts or networks you
  choose. These features do not upload your recorded performance history.

- The app is not sandboxed. You can enable a privileged helper to read more
  processes. The app and helper check each other's code signatures.
  Full Disk Access lets disk scans and other tools read more files.

- **ANE power** uses that approved helper to run Apple's powermetrics as root.
  The executable, arguments, one-second interval, and 60-sample child lifetime
  are fixed. Clients cannot supply commands or paths. One shared sampler uses
  short client leases; it stops when demand ends or a client disconnects.
  Output frames and replies have size limits, and stale replies are discarded.
  The helper returns only ANE watts, a timestamp, and the sample interval. It
  saves no raw tool output and makes no network requests. ANE Time does not
  need root. See [ANE power](docs/gpu-tab-design.md#ane-power-18-september-2026).

- Actions you choose can make changes. These include force-quitting a process,
  installing the helper, or applying an update. Routine monitoring is separate
  from those actions. Read prompts and check permissions before proceeding.

## Release Integrity

Published apps and packages use Developer ID signing and Apple notarization.
Sparkle also checks the update's EdDSA signature. A local or ad-hoc build does
not provide the same checks as a published package.

Keep signing keys, certificates, private settings, databases, and alert logs
out of git and security reports. Send only what we need to repeat the issue.
Remove unrelated paths and account details first.

