# AI Integration PRD: Siri And On-Device Answers

Date: 2026-09-15

Status: Full feature proposed; a smaller opt-in preview is in development on main.
No public preview release has been published as part of this work.

Audience: The product owner and engineers building Mac Performance Monitor.

## 1. Product Decision

Add two features that share the same measured evidence:

1. **Siri integration:** expose the app's supported queries and actions through
   App Intents. Include macOS 27 discovery, onscreen context, and system tests.
2. **Ask About This Mac:** let people ask questions about performance in the
   app. Use Apple's on-device Foundation Models or an optional local model
   only after the user opts in.

Siri support must work without enabling the in-app model. The model must explain
readings, not invent them or replace the app's rules.

Keep the current macOS 15 deployment target and Apple silicon distribution.
Gate newer APIs by OS version. Neither feature needs an account, subscription,
API key, cloud service, or new privileged helper.

### What Success Looks Like

A person can find the main measured causes of a slowdown, inspect the
evidence, and choose a useful next step without opening each chart first.
The answer must also say when the app lacks enough evidence.

For Siri, completion means a tested integration across the supported system
surfaces. Registering a few phrases or opening the main window is not enough.
Apple controls which natural-language requests Siri can understand. The release
must describe that boundary accurately.

## 2. Scope And Platform Rules

### Generative Preview

Ask now runs a read-only investigation, not just a summary of a fixed report.
Turn on Use on-device AI and Generate explanations from evidence in Ask's settings.
The second choice gives separate consent to pass selected facts and recorded
performance data to the local model. Existing AI consent alone does not grant it.

The model starts with a small snapshot. It can choose four database tools:

- System history: CPU, valid memory pressure, swap activity, disk activity and
   latency, network traffic, GPU, thermal pressure, and component power.

- Top processes: find candidates by recorded CPU, memory, disk, network, GPU,
   energy impact, or file-descriptor use. A peak ranking is a lead, not a verdict.

- Process search: find a named app among recorded processes, including exited ones.

- Process history: check a returned process over the selected interval.

The model chooses the next check from its results. A ranked candidate needs
process history and the matching system interval before an early conclusion.
The first tool version allows at most four checks over the past seven days.
The app runs fixed, parameterized queries on its existing database read queue.
There is no SQL text, shell, file-content, or system-changing tool.

Tool results carry small sets of facts, observed times, and coverage limits.
Rankings read at most 50,000 source rows. System and process reads cap at 8,000
rows or points. Larger requests return a limit rather than a database dump.
Missing recordings, unreadable values, and discarded aggregate detail remain
unknown. Partial aggregate buckets outside the requested interval are excluded.
Raw pressure validity is checked; older aggregates cannot recreate those flags.

Ask shows the checks it ran and cites the returned evidence. Answers name the
strongest supported contributor, a competing explanation, a useful comparison,
and one follow-up question. A short reply carries the previous question and
clarification, not old readings or a full chat transcript. Closing Ask clears
this context. Current reports remain available without a model or recording.

Apple on-device is the default model. It uses Foundation Models and the system
model supplied by macOS, including the updated on-device model on macOS 27.
It needs macOS 26.4 or later and a ready, enabled Apple Intelligence model.
Settings shows its readiness or the reason it is unavailable. No Qwen download
is needed, and Qwen's 16 GiB RAM gate does not apply to Apple.

Qwen remains an optional choice. Ask keeps an existing Qwen selection; choose
Apple on-device (default) in settings to switch. If Apple is unavailable, Ask
keeps current reports available. It never silently switches to or downloads Qwen.
All model choices use the same read-only tools, consent checks, and evidence checks.

The original Qwen option uses Qwen3-4B-Instruct-2507 at 4-bit precision through MLX.
Each optional model needs Apple silicon and at least 16 GiB of physical RAM. The app applies this
gate before both download and inference. Smaller Macs keep Apple AI and reports.

Local models also need normal memory pressure and no serious thermal pressure when they
run. The app and worker both check resources. A warning during inference stops
the worker. The hardware threshold alone is not a guarantee of enough headroom.

Ask and preview settings show a pause notice naming the selected model when memory
pressure is high or cannot be read. The notice offers a readiness recheck and
keeps current reports available. Ask checks again before each request and when
the app returns to the foreground. Recovery clears the old pause message without
changing the selected model, downloading files, or starting a request on its own.

When Qwen is selected, enabling explanations starts its download automatically.
Selecting the original Qwen while explanations are enabled does the same. Turning AI or
explanations off, or switching models, cancels an active download. Cancel and
Remove remain user choices; opening settings does not undo them. macOS manages
Apple's model download, so the app cannot start or control that download itself.

The Qwen download is about 2.3 GB. The app needs 5 GB of free space to stage and
verify it. It pins the model revision, tokenizer, and configuration hashes.
Downloads use Hugging Face and its approved HTTPS redirects. No model weights
ship in the app bundle. Settings provides progress, cancellation, and removal.

Two more local models are available as **experimental** choices:

| Model | Download | Free disk space before download | Runtime |
| --- | --- | --- | --- |
| Qwen3.5 4B | About 3.1 GB | 7 GiB | MLX, text only, thinking disabled |
| DeepAnalyze 8B | About 5.0 GB | 11 GiB | llama.cpp, Q4_K_M GGUF |

Select either model in Ask settings, then choose Download. Neither starts a download
just because you select it or open settings. Each has its own folder, progress,
cancel, and removal controls. Changing models preserves the other downloads.
The original Qwen preference and files remain unchanged. Apple remains the default.

Qwen3.5 is a newer general model. DeepAnalyze is a data-analysis model, not a
macOS diagnostic specialist. Its training includes code workflows, but this app
provides no code interpreter or execution tool. The worker requires JSON output
and applies the same tool and evidence checks to every answer.

The downloads pin revisions, sizes, and hashes. DeepAnalyze uses the GGUF conversion
from `mattritchey/DeepAnalyze-8B-Q4_K_M-GGUF`; its model card and upstream licences
stay with the files. A pinned llama.cpp framework runs only in the worker, not
the main app or privileged helper. Model licences also use GitHub's raw-file host.

Only one local worker can run at a time. MLX keeps its 5 GiB allocation limit.
DeepAnalyze has an 8 GiB peak resident-memory ceiling and may stop under memory
pressure on a busy Mac. These are different memory measures, not a speed or
efficiency comparison. The 16 GiB hardware gate does not guarantee enough free RAM.

The new models have not yet completed a real-model trial here. Tests cover selection,
separate storage, explicit downloads, the worker protocol, and native settings.
The packaged GGUF runtime starts with network and build-directory access blocked.
That check does not load weights or measure answer quality. A trial with existing
Qwen weights stopped at the memory-pressure guard. The contributor guide has a
no-download trial command for each local choice. Treat both new options as experiments.

The local-model worker is a separate, unprivileged process. It loads local files, serves
one investigation, and exits. It keeps the model loaded across that investigation's
turns and exchanges bounded messages with the app. The app executes each data tool
and verifies the final citations against the evidence it supplied. The worker
does not receive a database connection, executable paths, or raw process IDs.
Investigations have a two-minute deadline, including loading and generation.
Cancelling ends the worker and clears its model allocations.

Each turn uses a fresh context. Apple keeps a 4,096-token budget; local workers use an
8,192-token cap. Input counts include instructions and schema or chat template.
Output and safety reserves remain separate. The app bounds tool results, and
Apple drops older facts when needed to fit. Model context size is not a limit
on the database size: it limits how much evidence fits in one reasoning step.

The app checks field bounds, fact IDs, quoted values, and selected unsafe wording.
Equivalent percentages, such as "118.0%" and "118 percent", count as the same
value. Changed values, wrong units, and invented sources still fail. The app adds
a source link when an answer quotes a supplied value or a name containing a number.
These links can exceed the model's preferred five citations, but not the limit
of 24 supplied facts. A bare tool name is not a valid next check.

Tool results also carry the requested window and the observed time spans as
structured data. The answer checker accepts times and durations that match this
data, such as a quoted timestamp or a five-minute query window. It still rejects
unknown times and wrong measurements. A requested window is not proof that the
app recorded data throughout it. The host checks times against its own query
results, not against dates claimed by the worker.

All models use short letter labels to cite facts. The app maps each label back to its
real source before checking or showing the answer. Unknown labels fail. Invalid
output leaves the measured report available. These checks do not prove semantic
truth. Models can overstate a conclusion; wider review remains a release gate.

All models can retry each failed planning step once and a failed answer once.
Repair uses existing evidence, without reading the database again. It gets the
rejected draft and all failed checks together, not just the first error. Apple
may trim evidence to fit its context budget; it checks citations against the facts
the model saw. The tools, time limit, and answer checks stay the same.
A failed retry stops the request. Known worker
errors now retain their type, so the app can show a clearer message. Logs name
the step and the kind of failure. They never store questions, process names,
readings, or answers.

Ask now separates unmatched numbers, other text/source failures, unsupported
checks, and unknown process references in its messages. Qwen's final-answer
prompt asks for prose without numbers, leaving exact values in the cited facts.
Its repair input names the fields with unmatched numbers. Diagnostic logs name
only those fields and failure types, not the rejected text. The validator is
unchanged: unsupported numbers and sources still fail, even after a retry.

A synthetic SQLite test records a busy build before a quiet current snapshot.
Apple's model queried the process ranking, process history, and system history,
then identified the build as the strongest lead. The latest run took about 20 seconds.
Tests also cover invalid queries, missing values, cancellation, forged citations,
and consent revocation during a read. One fixture is not a broad accuracy score.

Apple also completed a read-only local-history investigation in about 25 seconds.
Smoke tests cover memory pressure, disk activity, and missing network evidence.
They check output structure and citations, not the truth of every interpretation.
Apple can still misread disk latency or suggest a weak comparison. It remains a
Preview feature, not a verified root-cause engine. Check its cited facts before acting.

On 18 September, Qwen completed the same test in about 31 seconds. A read-only
test of local history also found failures in planned queries and final answers.
After the answer-handling fixes, the local-history test completed three checks
and returned a validated answer in about 37 seconds. Tests cover equivalent
percentages, citation mapping, Unicode numbers, and the retry limit. A real-model test can still
stop when memory is tight, even on an eligible 18 GiB Mac. Keep that safeguard on.

A later failure came from valid time references being treated as unknown
measurements. A replay pinned to the failed request's timestamp reproduced it.
With explicit time-window data, that case and a fresh full investigation both
returned validated answers. The pinned replay avoids relying on changing live
readings when checking a reported failure.

A later run failed the numeric check on both answer attempts. Its exact answer
was not retained, and a CPU replay near that time did not reproduce the failure.
The revised prompt passed a full synthetic investigation and a fixed read-only
local-history replay. This is not proof that all such failures are resolved.
The clearer messages and field-level diagnostics make future failures easier to
identify without logging private answers. Native warning layout and recovery
tests pass; screenshot review still needs an unlocked macOS session.

The original preview below records the earlier report-selection behavior.
This section supersedes its limits on generated prose, history tools, and optional models.

### First Preview

The original preview is a limited step toward this PRD, not its completion.
Enable it under Settings > General > Ask About This Mac (Preview). Open Ask
from the toolbar, the Ask menu, or the menu bar's More actions menu.

- Five read-only reports cover current system activity, CPU, memory, startup
   disk space, and network traffic. No recording is needed for current reports.
- Typed questions use Apple's on-device model to select a report topic. All
   values and explanatory text come from Swift, not generated prose.
- Questions about past activity, named apps, and changes to the system return
   a clear limit. There is no free-form chatbot or automatic repair.
- Each typed request starts a fresh model session. It sends only the question
   and previous report topic, not process names, file trees, or performance history.
- Token counts include instructions, the answer schema, and the question. The
   input limit is 2,800 tokens at a 4,096-token capacity. Output and safety reserves
   remain separate; the first preview has no model-callable tools.
- A loaded, complete startup-disk scan can add category totals to the disk report.
   Ask does not load a file tree or start a scan on its own.
- Six App Shortcuts cover the five reports and opening Ask. Report results use
   a typed entity and local-device authentication. A macOS 27 open schema supports
   the public Ask destination; broader schemas and view annotations remain planned.
- Preview enablement, on-device AI, and Siri/Shortcuts data sharing each start off.
   Model consent does not grant Siri access. Closing Ask clears its question and report.
- Current reports retain the macOS 15 app baseline. On-device questions in this
   preview need macOS 26.4 or later. Build the distributable preview with Xcode 27.
- Preview UI and errors have English, Simplified Chinese, German, and French
   strings. New non-English text is AI-translated and awaits native review. Voice
   phrases are English in this first build. Existing translations are unchanged.

Local checks cover report accuracy, missing data, resource limits, consent,
cancellation, native rendering, one-shot sampling without recording, and a small
real-model routing test. App Intents metadata must be present in the final bundle.
These checks do not replace signed-install Siri tests, language review, or the
full quality and performance gates below. The full catalogue is still the target,
not a claim about this preview.

### Included

- Current and recorded CPU, memory, disk, network, GPU, energy, and thermal facts.
- App and process rankings, with timestamps and coverage limits.
- Explanations of alerts and diagnostic findings.
- Disk capacity analysis using an existing scan, or a scan the user approves.
- Navigation to the exact process, volume, finding, or recorded interval.
- Explicit, bounded app actions through App Intents.
- Short follow-up questions in the in-app experience.
- Localized controls, accessible results, and useful non-AI alternatives.

### Excluded

- Cloud inference, including Private Cloud Compute and third-party providers.
- A general chatbot, shell agent, remote support service, or autonomous repairer.
- Automatic file deletion, process termination, cache clearing, or system tuning.
- Automatic access to file contents, browser history, or Apple activity records.
- Continuous model analysis of every sample or background AI alerts.
- Claims about another device, an ISP, or hardware failure without measurements.
- A rewrite of the sampler, charts, alert engine, or existing history storage.

### Compatibility

| Environment | Behavior |
| --- | --- |
| macOS 15 | Existing app remains usable. Support baseline App Intents and Shortcuts where the APIs allow. No Foundation Models UI that can crash or call absent symbols. |
| macOS 26 | Offer on-device answers on eligible Macs when the system model is available. Keep baseline intents available without the model. |
| macOS 27 | Add the verified Siri schema routes, view annotations, and tests through App Intents Testing. |
| Apple Intelligence off, unsupported region, or model unavailable | Keep rule-based reports and app actions. Explain why the model is not ready. |
| Siri unavailable or disabled | Keep the app and Shortcuts useful. Check Siri and model support separately. |
| No internet connection | On-device answers work once the system model is ready. Do not promise offline Siri or offline network probes. |

Use Xcode 27 and the macOS 27 SDK to build and test the new integration.
Confirm deployment guards and framework linking in the actual release bundle.
Do not infer support from the OS version alone.

### What Apple Documents Today

Apple's macOS 27 overview covers schemas for entities and intents. It also
describes view annotations and App Intents Testing [A1]. The schema list separates Siri
domains from domains that only work in Shortcuts [A2].

There is no system-performance domain in the reviewed list. The system domain
does support opening and searching content [A3]. Use matching schemas only.
Do not represent a process as a note, message, or file to gain Siri coverage.
Apple deprecates `.system.search` in macOS 27 and names `.system.searchInApp`
as its replacement [A10]. Use that route for search and `.system.open` for
opening content [A11]. Prove each conformance in the selected SDK.

Custom App Intents and App Shortcuts remain part of the plan. They are not proof
that the new Siri can invoke every custom query through arbitrary phrasing.
The first milestone must produce a tested route for each Siri journey in scope.
An unsupported route is a product decision, not a hidden fallback or a pass.

The Foundation Models framework is available from macOS 26. Apple documents
checks for model availability and a limited context window [A4, A5].
The macOS 27 APIs also offer cloud models. This product must select its local
backend explicitly. No cloud backend or automatic cloud fallback is implemented.

## 3. Questions The Product Must Answer

| User question | Answer | Evidence boundary |
| --- | --- | --- |
| Why is my Mac slow? | Rank the strongest measured contributors and show the affected interval. | A busy process is not proof that it caused every symptom. |
| What is using my CPU? | Name the leading apps or processes and state the measurement window. | Distinguish per-process CPU from whole-machine CPU. |
| What is taking the RAM? | Show physical footprint, pressure, paging, and recent growth where known. | Used memory, cached files, and old swap alone do not prove a problem. |
| Why is my disk full? | Show capacity, the selected volume, and the largest measured categories or folders. | Separate scanned files, shared APFS space, purgeable space, and unknown bytes. |
| Why is my network slow? | Report traffic, adapter facts, and any approved probe results. | Low traffic is not a speed test. Link rate is not internet speed. |
| Why was it slow earlier? | Read the requested interval and state the retained detail and gaps. | Do not apply today's process list to an earlier event. |
| What does this alert mean? | Explain the rule, measurements, and relevant limits. | Preserve the rule's severity and uncertainty. |
| What should I do next? | Offer a short list of approved, relevant next steps. | The model cannot execute a repair or invent a command. |

Default to the current Mac and current readings. Ask for a time, process, or
volume when ambiguity would change the answer. Use the app's selected interval
when the user explicitly asks about that view.

## 4. Shared Evidence Contract

### Current Code To Reuse

| Existing owner | Role in this feature |
| --- | --- |
| [Package.swift](../Package.swift) | Keep the core independent of SwiftUI and preserve the macOS 15 target. |
| [Sampler.swift](../Sources/MacPerfMonitorCore/Sampling/Sampler.swift) | Reuse `Sampler.Snapshot` and its serial queue. |
| [SystemSample.swift](../Sources/MacPerfMonitorCore/Models/SystemSample.swift) | Reuse measured values, optional fields, and validity flags. |
| [ProcessDiagnostics.swift](../Sources/MacPerfMonitorCore/Analysis/ProcessDiagnostics.swift) | Reuse `ProcessDiagnostics.run`, fixed probes, and catalog findings. |
| [README.md](../README.md) | Preserve existing feature boundaries and the no-telemetry promise. |

The sampler computes rates and returns typed snapshots. Some readers
refresh less often than others. A snapshot timestamp alone does not prove that
every field is fresh. Process diagnostics also use inputs from detailed process
checks. A basic question must not silently start every probe.

### New Shared Service

Add a read-focused `SystemEvidenceService` in the core layer. This is a proposed
type, not an existing API. It must serve both App Intents and the in-app answer
coordinator through the same bounded query contract.

The service must:

- Read the existing snapshot and history, without starting a second sampler.
- Calculate ranks, changes, units, and rule findings in Swift.
- Return immutable `Sendable` results.
- Distinguish current facts, historical facts, rule findings, and missing data.
- Limit query size and avoid blocking the sampler, UI, or database writer.
- Keep the language model out of the privileged helper and persistence layer.

Each result must contain a request ID, capture time, requested range, actual
range, source, and coverage state. Each fact must carry a stable evidence ID,
unit, value, observation time, and relevant subject identity.

Coverage must distinguish at least: available, stale, not recorded, not sampled,
permission denied, tracking disabled, unsupported, and partial. A missing value
must never become a measured zero.

### Freshness And Identity

- Default live queries use the latest valid reading for each source.
- Derive freshness from that source's cadence, not one fixed timeout for all data.
- Show scan age separately from the age of disk capacity readings.
- After launch or wake, wait for valid counter deltas or state that rates are pending.
- Identify a process by `ProcessIdentity`, not its PID alone.
- Check that a process still exists before opening it or proposing an action.
- Keep each run separate when a process restarts or macOS reuses its PID.
- Return a clear gap when recording was off or retention removed the interval.

### Answer Shape

Every answer must present these parts, using the same facts on all surfaces:

1. A direct summary of what the readings show.
2. Up to three likely contributors, each linked to supporting evidence.
3. Important missing data or reasons the conclusion remains uncertain.
4. Up to three approved next steps and a route to the relevant app view.

The app must check model output before showing it as an answer.
It must resolve evidence IDs, render numbers from typed facts, and reject unknown
subjects or action IDs. A citation does not by itself prove that generated prose
correctly describes the evidence.

If the checks fail, show the rule-based report. Do not show an unsupported
diagnosis and attach a generic disclaimer.

## 5. Privacy And Safety

### Separate Choices

The in-app model is off by default. Enabling it must not enable Siri, recording,
per-app network tracking, Full Disk Access, or the privileged helper.

Siri receives information through Apple-controlled system features. The app must
not claim that every Siri interaction stays on-device. In-app answers must use
only the on-device model, with no automatic cloud fallback.

Use [SECURITY.md](../SECURITY.md) as the baseline. Add clear controls for sharing
app content with Siri and Spotlight, separate from using the in-app model.
Index only approved, minimal content. Never index the live process stream, raw
history, scanned file trees, or conversations by default.

### Data Handling

- Keep conversations in memory for the current session by default.
- Provide New Conversation, Stop, and Clear controls.
- Clear session data when the user disables the feature or quits the app.
- Do not log prompts, answers, file paths, network addresses, or raw tool results.
- Use redacted metadata for local diagnostics and tests.
- Exclude serial numbers, usernames, full paths, endpoints, and command arguments
  unless the user approves a specific use that needs them.
- Treat process names, file names, and other source text as untrusted data.
- Do not allow that text to change instructions, tool permissions, or query limits.
- Keep existing Apple activity records outside this feature's data sources.

An explicit export must show a preview and privacy warning. Sharing an answer
must not silently include the whole conversation or underlying history.

### Action Boundary

The model may request only read tools. It may propose an action from an allow
list, but the app must check and route that proposal.

Navigation can open an app view. A new disk scan, active network test, export,
or settings change needs the appropriate explicit user action or confirmation.
Permission prompts belong in the foreground and remain under macOS control.

There must be no model tool for arbitrary SQL, shell commands, filesystem writes,
process signals, helper installation, or permission changes. Refusing a request
must leave the rest of the monitoring app usable.

## 6. Part A: Complete App Intents Support

All rows below are in the first release. P0 means the feature cannot ship as
complete without that requirement. Type names are proposed and may change before
release, but the public intent and entity IDs must remain stable once shipped.

### Intent Catalogue

Read intents must return typed data and a short spoken summary. They must not
merely open a tab. Open and search intents must show the requested content.

| ID | Proposed intent | Inputs | Result and behavior |
| --- | --- | --- | --- |
| S01 | `GetSystemStatusIntent` | Now or a recorded interval. | A rule-based report on load, pressure, disk, network, and known limits. |
| S02 | `GetMetricIntent` | Metric and interval. | Value, unit, age, trend, and coverage. Cover CPU, RAM, GPU, energy, thermals, disk, and network. |
| S03 | `GetTopConsumersIntent` | Resource, interval, app or process grouping, count. | Ranked subjects and values. Default to five; cap at twenty. |
| S04 | `GetProcessSummaryIntent` | Process and interval. | Footprint, CPU, available I/O, growth, and known findings for that run. |
| S05 | `GetGroupSummaryIntent` | Saved group and interval. | Totals and members, without counting a process twice. |
| S06 | `GetVolumeSpaceIntent` | Volume, defaulting to the startup volume. | Capacity and free-space facts. Do not start a scan. |
| S07 | `GetDiskMapSummaryIntent` | Scan scope and optional category. | Largest measured items, scan age, and coverage from the last complete scan. |
| S08 | `GetNetworkStatusIntent` | Adapter, defaulting to the primary route. | Traffic, link facts, known issues, and limits. No active test. |
| S09 | `GetFindingsIntent` | Topic, severity, and interval. | Active alerts or retained findings, with the source and event time. |
| S10 | `ExplainFindingIntent` | Finding. | The rule, evidence, and approved next steps. No model needed. |
| S11 | `CompareActivityIntent` | Subject, metric, and two intervals. | Comparable aggregates, change, sample detail, and gaps. |
| S12 | `SearchMonitorContentIntent` | Query and content scope. | Matching sections, subjects, findings, or saved reports. Use the macOS 27 search schema. |
| S13 | `OpenMonitorContentIntent` | Entity and optional interval. | Open the exact view, selection, and time range. Use the macOS 27 open schema. |
| S14 | `SetRecordingEnabledIntent` | Explicit on or off value. | Confirm and set recording through its existing owner. Report the resulting state. |
| S15 | `SetNetworkTrackingEnabledIntent` | Explicit on or off value. | Confirm and set per-app tracking. Explain its extra cost before enabling it. |
| S16 | `SnoozeAlertIntent` | Alert. | Apply the existing one-hour snooze policy. Reject alerts that policy excludes. |
| S17 | `StartDiskScanIntent` | Approved volume or folder scope. | Open Disk Map, confirm scope, then return a scan job. |
| S18 | `RunNetworkCheckIntent` | Approved check profile and adapter. | Open a consent view, then return a bounded network-test job. |
| S19 | `GetOperationStatusIntent` | Job. | Queued, running, complete, cancelled, or failed state; progress and any result. |
| S20 | `CancelOperationIntent` | Job. | Cancel that job only. Repeat requests must be harmless. |
| S21 | `CreateDiagnosticReportIntent` | Subject and interval. | Prepare a redacted report for preview. Export or save only after approval. |
| S22 | `AskAboutThisMacIntent` | Question and optional selected subject. | Open Ask with the question intact. Respect model consent; never enable it through voice alone. |

S14 and S15 set a state rather than toggle it. Repeated requests must not undo
the user's last choice. S16 must use the existing alert policy, including its
rules for critical alerts. The model has no direct access to S14 through S22.

An interval must have explicit dates and a timezone once resolved. Reject future
ranges, reversed dates, and requests outside supported bounds. A valid range
with no stored data returns a coverage result, not an empty success.

### Entities And Queries

| Entity | Identity and query contract | Discovery policy |
| --- | --- | --- |
| `MonitorSectionEntity` | Stable keys for Dashboard, Processes, Groups, Explorer, Energy, Network, Disk, Disk Map, GPU, Hardware, Insights, and Settings. | Static destinations may appear in Spotlight. |
| `ProcessEntity` | Reuse the process identity and scope it to this Mac and boot. Resolve current and retained runs separately. | Query on demand. No bulk indexing of process names. |
| `ProcessGroupEntity` | Reuse the saved group's ID. Resolve names without changing membership. | Private content; follow the sharing choice. |
| `VolumeEntity` | Stable volume identity where available, with a rechecked mount and scope. | Do not encode a raw path as a public ID. |
| `NetworkInterfaceEntity` | Adapter identity plus capture context. Handle removed or renamed adapters. | Do not expose addresses or SSIDs as display names. |
| `FindingEntity` | Rule or incident ID, subject, and event time. | Live results by query; no raw alert archive in Spotlight. |
| `DiagnosticReportEntity` | Report ID, creation time, interval, and redacted evidence. | Index only a report the user saves and approves for discovery. |
| `DiagnosticOperationEntity` | App-owned job ID, type, owner, state, and creation time. | Transient query result, not a Spotlight record. |

Use `AppEnum` for bounded choices such as resource, metric, grouping, and range
preset. Use entity queries for actual subjects. Support identifier lookup, name
search, suggestions, disambiguation, and structured filters where the SDK allows.

Never resolve duplicate process names by taking the first match. Ask the user to
choose an app group or a specific run. Recheck access and identity at execution
time, including references that come back from a saved Shortcut.

Use `IndexedEntity` for content eligible for indexing. Use `Transferable` for
approved report exchange, with a redacted text or structured representation.
Apply real entity schemas where they fit. A custom entity is not proof of
schema-backed Siri support.

### Siri, Shortcuts, And Onscreen Context

- **SIR-01, P0:** Every catalogue action appears in Shortcuts with useful names,
   parameter summaries, defaults, validation, results, and localized errors.
- **SIR-02, P0:** Supply an `AppShortcutsProvider` within the SDK's shortcut limit.
   Use the application-name token and localized phrases. Do not register all
   catalogue rows as separate shortcuts if that exceeds the limit.
- **SIR-03, P0:** Supply ready-to-use voice routes for status, top CPU users, top
   RAM users, disk space, disk scan results, network status, alerts, and navigation.
   These journeys must not depend on the user building a Shortcut first.
- **SIR-04, P0:** Maintain a route matrix for all S01 through S22 actions. Record
   schema-backed Siri, App Shortcut, named user Shortcut, and foreground handoff
   separately. Test each route; never count one route as proof of another.
- **SIR-05, P0:** On macOS 27, annotate the selected process, finding, report,
   volume, and Explorer context using the supported view APIs [A7]. Resolve
   "this process" from actual visible selection, not a stale global variable.
- **SIR-06, P0:** Support search and open with app attribution. Clear annotations
   when a view closes, selection changes, or the referenced data expires.
- **SIR-07, P0:** Return a concise spoken result and a readable visual result
   where the surface allows. Include age, units, coverage, and an evidence link.
- **SIR-08, P0:** Donate only approved user actions and content. Do not donate
   each sampling tick. Remove indexed data when sharing stops or a report is deleted.

An example test phrase is "What is using the most memory in Mac Performance
Monitor?" Test paraphrases, follow-ups, and ambiguous names too. These are test
goals, not a promise that Siri accepts every possible wording.

### Execution And Consent

Read intents must work with the main window closed. A cold launch must register
dependencies before an intent runs. Inject the existing app services through
the framework's supported dependency mechanism, rather than constructing another
`SamplerModel` inside `perform()`.

If monitoring is idle, acquire a short sampling lease from the existing owner.
Release it on success, timeout, or cancellation. Do not turn on recording or
menu bar components as a side effect of a read query.

Use the SDK's foreground modes for navigation and consent. Set an authentication
policy for private data and state changes. Private queries must not reveal facts
while the Mac is locked. Test this through the system, not just a mocked policy.

Default data sharing with Siri and Spotlight to off. Static intent descriptions
and public destinations may remain discoverable. The first private query must
offer a foreground choice, then return a clear result if the user declines.
Revocation must stop queries, donations, and annotations that expose private data.

Long work must return a job, not hold Siri open for minutes. No background prompt
may install the helper, grant Full Disk Access, or choose a folder for the user.

## 7. Part B: Ask About This Mac

This part is in release scope but optional for each user. "Optional" means
opt-in use, not an unfinished second phase of the product.

### User Experience

- **ASK-01, P0:** Add a native Ask view and a menu bar entry. Keep the existing
   navigation, typography, window behavior, and light and dark appearances.
- **ASK-02, P0:** Add an Ask action beside a selected process, alert, Disk Map
   scope, and Explorer interval. Pass a typed context, not a screenshot.
- **ASK-03, P0:** Before first use, explain local model use, the data involved,
   and the effect on memory and power. Let the user decline without losing reports.
- **ASK-04, P0:** Show the current subject, time range, evidence age, and source.
   Keep those facts visible when the user asks a follow-up.
- **ASK-05, P0:** Provide Send, Stop, New Conversation, Clear, and explicit Copy
   or Share actions. Preserve typed text after a recoverable failure.
- **ASK-06, P0:** Offer Open Evidence actions that select the exact process,
   scan, alert, or interval. Do not send the user to an unrelated default tab.
- **ASK-07, P0:** With AI off or unavailable, offer the same core questions as
   rule-based reports. Label those results as reports, not generated answers.
- **ASK-08, P0:** Support keyboard use, VoiceOver, selectable text, zoomed text,
   and long translated labels. Never signal severity by color alone.

Use short answer sections: Summary, Evidence, Limits, and Next Steps. Keep
technical details behind an evidence disclosure. Suggested questions must act as
real commands, not an introductory marketing page.

A follow-up such as "what about that process?" keeps the prior report's subject
and time. "What about now?" creates a new report with a new capture time. Make
the change visible. Never combine old and new facts without saying so.

### Model And Tool Contract

- **MOD-01, P0:** Check `SystemLanguageModel.default.availability` before use and
   when the app returns to the foreground. Also check locale support [A9].
- **MOD-02, P0:** Use an isolated coordinator to own `LanguageModelSession`.
   Allow one response at a time. Cancel cleanly when the user stops or disables AI.
- **MOD-03, P0:** Use guided generation with `@Generable` for a small answer
   schema. The schema must carry evidence IDs and approved next-step IDs.
- **MOD-04, P0:** Fetch known context directly. Expose only the few read tools
   needed for that question, with bounded inputs and results.
- **MOD-05, P0:** Compute all numeric facts and diagnoses in Swift. The model
   may select and explain supported findings, but cannot raise their severity.
- **MOD-06, P0:** Keep a visible answer within roughly 250 words before evidence
   details. Validate the final structure and claims before displaying them.
- **MOD-07, P0:** Keep trusted instructions separate from user questions and
   source text. Treat file and process names as data, never as instructions.
- **MOD-08, P0:** Version prompts, answer schemas, tool contracts, and rule sets.
   Run the evaluation set again after changes to them or the Apple model.

Candidate tools are `readSystemEvidence`, `readProcessEvidence`,
`readHistoryEvidence`, `readDiskSpaceEvidence`, `readNetworkEvidence`, and
`readFindingEvidence`. These are proposed app tools, not Apple APIs.
Expose at most three for one request. Cap each turn at three tool calls and
one bounded recovery attempt. A tool cannot start a scan or network test.

Do not send raw time series, every process row, or a whole file tree to the model.
Send top contributors, Swift-computed summaries, and selected facts. Fetch more
only through a bounded tool. Tool schemas and results count toward context size.

### Context Budget (P0)

Design for **4,096 tokens per session**, the limit in Apple's current guide [A5].
This is the total for input and output, not space for 4,096 tokens of evidence.
Instructions, questions, prior turns, tool definitions, tool calls and results,
answer schemas, and generated replies all share that space.

Read `contextSize` from the selected system model and use `tokenCount(for:)`
where the SDK supports them. Cap the first release at the smaller of the reported
limit and 4,096 tokens. Do not assume 8,192 tokens from the OS version or chip.
A larger budget needs both a reported larger limit and quality and cost tests.

Start with this allocation for a 4,096-token session. These are design budgets,
not measured costs. M0 must measure the serialized forms and adjust the split
within the total. Keep a reserve for framing and estimation error.

| Context component | Token budget |
| --- | --- |
| Trusted instructions and answer schema | 600 |
| Active tool definitions | 400 |
| Current question and retained conversation state | 400 |
| Initial evidence | 700 |
| Tool calls and results, combined across the turn | 700 |
| Generated answer | 800 |
| Safety reserve | 496 |
| Total | 4096 |

The coordinator must check the combined budget before generation and before
handing tool results back to the model. Count existing transcript entries too.
At this allocation, context before the answer must fit within 2,800 tokens.
Three allowed tool calls do not grant three separate 700-token result budgets.
If tool schemas alone exceed their share, expose fewer tools or fetch facts in
Swift before generation. A response-length limit alone cannot prevent overflow.

Use token counts, not word counts or a fixed characters-per-token conversion.
Test English, Chinese, mixed-language names, and long identifiers. When token
counting is unavailable, use conservative bounds tested for each supported locale.
If the model itself is unavailable, use the report path, not an estimated capacity.

Start a fresh model session for each answer by default. Keep the visible
conversation outside model context. Carry only the current question, selected
subject and interval, relevant user constraints, and a small set of validated
facts. A prior model answer is not new evidence. Do not replay the full chat or
use repeated model-written summaries as the source of facts.

Trim low-priority detail before dropping facts needed to explain the answer.
Keep evidence IDs, dates, units, and coverage limits. Say when the report omits
detail, and keep it available through Open Evidence. Never silently truncate the
question, reset to Now, or remove uncertainty to make an answer fit.

If essential context does not fit, ask the user to narrow the question or show
the rule-based report. On overflow, allow the existing single bounded recovery
attempt with a fresh, smaller context. Never retry with the same full payload.

Context tests must cover simulated 4,096-token and 8,192-token limits, oversized
questions, all three tool results, and at least ten follow-ups. Include Chinese
and long process or file names. Assert that each turn fits its selected budget,
preserves scope, and falls back cleanly when it cannot fit. An 8K simulation is
not evidence that Apple's installed model offers an 8K window.

### Failure States

| State | User sees | App behavior |
| --- | --- | --- |
| AI off | Enable choice or a rule-based report. | No session, model request, or model prewarming. |
| Device or region not eligible | A clear limit and the report route. | No cloud fallback or repeated retry. |
| Apple Intelligence off | The system setting that needs attention. | Do not change it for the user. |
| Model not ready | A readiness message. | Do not promise a download percentage the API does not provide. |
| Unsupported language | A localized explanation and report route. | Do not silently answer in a different language. |
| No evidence or partial access | Known facts and the specific gap. | Do not infer the missing values. |
| Context full | A bounded retry with fresh, compact context. | Keep the subject, time, and trusted instructions. |
| Refusal or unsafe request | A short boundary and useful supported actions. | Keep Apple's guardrails enabled. |
| Busy, cancelled, timed out, or resource constrained | Clear status and a report route. | Stop new work and release app-owned resources. |
| Invalid or unsupported answer | The rule-based report. | Do not publish the generated diagnosis. |

## 8. Rules For Each Diagnostic Area

These rules apply to both Siri reports and model answers. They are P0. Reuse
current analysis where it fits; add tested Swift rules where evidence has no
shared interpretation yet. The model is not a substitute for that work.

### CPU And General Slowdowns

Use a live reading plus a short recent window when available. The default
slowdown report should consider the last five minutes and show the actual
coverage. Compare CPU load, pressure, paging, disk work, and thermal limits.

In [ProcessSample.swift](../Sources/MacPerfMonitorCore/Models/ProcessSample.swift),
`cpuPercent` measures one core, so a process can exceed 100%. Whole-machine CPU
uses a different scale. Label both scales and any averaging window. Match the
UI's chosen basis when testing that the answers agree with the app.

Separate sustained load from a short spike. A top consumer is a measured fact;
"this caused the slowdown" is a stronger claim. Tie causal wording and certainty
to approved findings, not a confidence score invented by the model.

### Memory

Use physical footprint for process rankings. Add pressure, recent growth,
compression, and valid swap-in or swap-out rates where present. Reuse the
[memory taxonomy](memory-taxonomy.md) and [adaptive alert rules](adaptive-alerts.md).

Do not equate used RAM with harmful pressure. Do not call an app a memory leak
because it is large. Report helper coverage and unreadable footprints. Explain
that process totals need not equal the system's full memory breakdown.

### Disk Space And Disk Work

Use the selected volume's capacity and the last complete scan for its scope.
Keep volume capacity separate from a folder's scanned size. Show scan age,
access failures, skipped areas, and changes in volume usage during the scan.

Reuse [DiskMapReconciliation.swift](../Sources/MacPerfMonitorCore/DiskMap/DiskMapReconciliation.swift).
Its purgeable figure overlaps other categories. Preserve unaccounted bytes,
shared blocks, and cases where scanned bytes exceed physical usage. A count of
local snapshots does not measure their size. Do not invent that size.

If no usable scan exists, show capacity facts and offer Start Scan. Preserve the
last complete result after a failed or cancelled scan. Full Disk Access does not
unlock every protected data vault. Do not promise that it does.

Use the existing scanner's rules for links, clones, hard links, and cloud file
placeholders. Reading metadata must not download cloud file contents. Large or
old files are candidates for review, not proof that deletion is safe.

Disk throughput, IOPS, service time, and busy share describe different facts.
High throughput alone does not prove a slow or failing disk. Offer the existing
Disk and Reclaim views for review; expose no AI or Siri deletion action.

### Network

Reuse [NetworkInfo.swift](../Sources/MacPerfMonitorCore/Models/NetworkInfo.swift)
for adapter state, link speed, error counters, and Wi-Fi radio readings. Compare
counter changes over time, not just totals since boot. Respect access limits on
SSID and BSSID, and leave those identifiers out of prompts by default.

Per-process network data currently gives a combined rate. When tracking is off,
the stored field can be zero. Carry tracking state into evidence so that this
means unavailable, not no traffic. Do not invent separate app upload and download
rates when the source has only a combined value.

[NetworkScanner.swift](../Sources/MacPerfMonitorCore/System/NetworkScanner.swift)
provides device and port discovery. It is not a connection-quality test. Add a
small `NetworkProbeService` for S18, separate from that scanner:

- Offer a fixed check profile for router reachability, DNS lookup, and a small
   connection test to a named external target.
- Show targets and the expected network use before approval. Respect the current
   route, including VPN and proxy policy. Never bypass them to obtain a result.
- Cap a run at 30 seconds and 1 MiB of transferred data. Stop on cancellation.
- Return typed timings, failures, timestamps, and the tested route or its limits.
- Treat a blocked probe as inconclusive, not proof that the network is broken.
- Do not scan a subnet or ports, change DNS, or launch a sustained speed test.
- Do not let the model supply a hostname, URL, port range, or command.

Choose and approve the public test target before shipping. Network tests must
not send prompts, reports, or history. A small probe can narrow down a path or
DNS issue, but it cannot establish maximum bandwidth or blame an ISP by itself.

### GPU, Energy, And Thermals

Use only supported readings. Identify missing GPU or sensor coverage and Macs
without a battery. Distinguish measured watts from relative energy-impact
estimates. Reuse the app's thermal verdict and battery estimates; do not invent
throttling, battery life, or hardware damage from one reading.

### Earlier Events And Comparisons

Query stored data, not plotted chart points or today's process list. Preserve
sample resolution, tracked-process coverage, restarts, sleep gaps, and missing
fields in older records. Follow the [chart data rules](dashboard-chart-standard.md).

Compare like metrics over explicit windows. Do not add unrelated peaks as if
they happened together. Say "among recorded processes" when history did not
capture every process. A missing interval must remain missing.

Capture evidence before starting inference. Mark any inference-related load in
later readings so the answer does not mistake its own work for the original
problem. Do not hide the app's or system model service's measured resource use.

## 9. Engineering Plan

### Keep One Source Of Facts

| Layer | Work |
| --- | --- |
| Core evidence | Define the query protocol, typed facts, freshness, coverage, bounded aggregates, and rule-based reports. Keep Apple AI frameworks out of the core and CLI. |
| App data adapter | Read from the sampler's owning queue and the existing history services. Supply immutable facts to the core service without creating another sampler. |
| App actions | Route navigation and approved changes through current owners. Keep these actions separate from model tools. |
| App Intents | Add entities, enums, queries, results, discovery, annotations, and dependency registration in the app layer. |
| Model coordinator | Gate availability, build a small context, call the system model, check the answer, and return it to Ask. |
| Ask view | Own conversation state, consent, progress, evidence links, and accessible controls. Do not own another sampler or history database. |

[SamplerModel.swift](../Sources/MacPerfMonitor/ViewModels/SamplerModel.swift)
has separate scan, recording, and UI publication rates. Its `latest` property is
not an always-fresh service for background callers. Add a queue-safe read path
and short leases through the existing owner. Carry each source's real capture
time and validity, including pending rate baselines after launch or wake.

Reuse the history APIs exposed by that model and the core persistence layer.
Avoid new copies of the full process list or scan tree on every tick. Share
identical in-flight reads when safe, and cancel work that has no remaining caller.

Extend the existing route behind
[WindowRouterHost.swift](../Sources/MacPerfMonitor/App/WindowRouterHost.swift)
with typed destinations and selected intervals. Navigation must still work when
the menu bar item is off. A query lease must prevent premature exit, then restore
the normal quit-when-idle behavior when it ends.

### Scans, Jobs, And Stored Reports

[DiskMapModel.swift](../Sources/MacPerfMonitor/ViewModels/DiskMapModel.swift)
currently owns scans in the UI and cancels them when the main window closes.
Preserve that policy for this release. S17 opens the real window before starting
the scan. Closing it must mark the job cancelled, not leave Siri waiting.

Expose only a small scan summary to background queries. If the full tree is not
loaded, read a bounded saved summary or report that it is unavailable. Do not
load a large tree just to answer a voice query. Tab changes may keep a scan
running as they do today; closing the window must still release its memory.

Jobs must have explicit ownership, cancellation, expiry, and failure states.
After an app restart, mark unfinished jobs as interrupted. Do not silently resume
a scan or external probe. Keep current monitoring and recording choices intact.

Keep conversation state in memory. Only an explicit Save Report action may
create a durable answer artifact. Use a versioned format and the app's existing
local storage conventions. Saved reports must support deletion and removal from
Spotlight. Clear All App Data must include these new records.

Imported reports must not resolve a foreign process ID as a process on this Mac.
Treat them as report data, never as executable actions. Validate format, size,
origin, entity references, and allowed fields before import.

### Build, Package, And Test The Real App

The project builds an SPM executable and assembles its own app bundle in
[Scripts/bundle.sh](../Scripts/bundle.sh). It also renames the executable inside
the bundle. Adding intent types to Swift code is not enough to prove discovery.

- Verify the SDK's metadata extraction and resource steps in the final bundle.
   Keep bundle identity, executable name, localization, and metadata consistent.
- Make missing App Intents metadata a release failure. Check a clean install,
   an upgrade, Spotlight discovery, and intent execution without Xcode attached.
- Keep Developer ID signing, notarization, helper identity, and Sparkle updates
   working. Validate the actual pkg and updated app, not just the SPM executable.
- Prefer the supported metadata pipeline with current packaging. If it cannot
   work reliably, use a thin Xcode app wrapper around the existing package.
   Record that decision in milestone M0; do not rewrite the core or CLI.
- Add an Xcode UI Testing target for App Intents Testing [A8]. Apple's framework
   runs out of process through the real app infrastructure. Plain `swift test`
   cannot replace this gate.
- Keep ordinary builds and tests usable without Apple Intelligence or signing
   secrets. Use availability guards and compile-time guards where older SDKs need them.

The current [CI workflow](../.github/workflows/ci.yml) runs on macOS 15 without
signing. Preserve its baseline checks. Add a macOS 27 job or a controlled Mac for
system tests, plus an eligible Mac for real-model checks. Do not weaken the
public CI checks or expose signing credentials to untrusted pull requests.

## 10. Performance Requirements

These are proposed acceptance targets, not measurements of the current build.
Establish the baseline in M0. Use an M1 Mac with 8 GB RAM and a newer supported
Mac, with fixed app settings and a repeatable workload.

| ID | Target |
| --- | --- |
| PERF-01 | With AI off, no model sessions, requests, prewarming, or new AI polling timers. |
| PERF-02 | When Ask is idle, added app footprint at most 5 MiB and mean CPU at most 0.1 percentage points above the same baseline. |
| PERF-03 | Warm rule-based queries finish within 1 second at the 95th percentile. Cold queries finish or report a gap within 8 seconds. |
| PERF-04 | Ask shows progress within 200 ms. A warm model answer completes within 15 seconds at the 95th percentile. Stop a cold or stalled turn at 30 seconds. |
| PERF-05 | Stop responds within 1 second. Cancel work and release app-owned session resources when Ask closes or AI switches off. |
| PERF-06 | Each answer uses one model response at a time, at most three tool calls, and a bounded context. No inference on each sample. |
| PERF-07 | No lost recorded samples or blocked sampler work caused by the feature in a ten-minute controlled test. Track latency and system pressure too. |
| PERF-08 | After closing Ask, app footprint returns to within 10 MiB of its prior baseline within 30 seconds under the same workload. |

Show the factual report while the model works. Do not stream unverified diagnoses
into the answer. If streaming is used, show only checked content or progress.

At critical memory pressure or serious thermal pressure, do not start inference.
Use the rule-based report instead. Handle pressure changes during a turn without
blocking monitoring. Low Power Mode must not trigger background model warmup.

Measure the app and the system model service separately. Releasing a session
does not guarantee that macOS immediately removes a shared model from memory.
Record peak memory, CPU, GPU, and energy during active use before setting a final
active-use ceiling. Approval of that ceiling is an M0 exit requirement.

Use [performance-budget.md](performance-budget.md) as prior design guidance,
not proof that the current release still matches its historical measurements.

## 11. Acceptance And Evaluation

### Release Tests

| Gate | Pass condition |
| --- | --- |
| QA-01: Catalogue | All S01 through S22 actions have success, invalid-input, denied-access, stale-data, and cancellation tests where those states apply. No placeholder results. |
| QA-02: System routes | App Intents Testing discovers and invokes the signed app's definitions. Test result chaining, entity lookup, transfer, indexing, and view annotations. |
| QA-03: Siri | Every ready-to-use voice journey passes on the chosen macOS 27 build. Test at least five paraphrases per journey and report the route used. |
| QA-04: Lifecycle | Test warm app, cold launch, window closed, menu bar off, recording off, wake, locked Mac, helper failure, and app upgrade. No extra sampler or stuck lease. |
| QA-05: Facts | Every shown numeric value, unit, rank, timestamp, and evidence link matches a pinned fixture. Cover CPU scales, missing rate baselines, and partial process coverage. |
| QA-06: Diagnosis | CPU, RAM, disk-full, network-slow, and general-slowdown cases produce the supported findings or a clear evidence gap. No invented causal diagnosis. |
| QA-07: History | Correct results with sparse history, no recording, expired data, older schemas, sleep gaps, restarted apps, reused PIDs, and mixed retained detail. |
| QA-08: Privacy | No app-initiated inference traffic, prompt logging, silent exports, or private indexing without consent. Revocation and data deletion remove the app's exposed data. |
| QA-09: Safety | Malicious file names, process names, questions, and imported reports cannot change tool scope or invoke an action. Denied requests leave the app working. |
| QA-10: Model states | Test AI off, ineligible device or region, model not ready, unsupported language, refusal, context overflow, timeout, cancellation, and pressure fallback. |
| QA-11: Compatibility | The app runs on macOS 15 without newer frameworks. Test model paths on macOS 26 and 27, and keep Shortcuts working when AI or Siri is off. |
| QA-12: UX and release | VoiceOver, keyboard use, long labels, evidence navigation, consent, signed installation, update, and every performance gate pass. |

Keep unit tests in the existing
[core tests](../Tests/MacPerfMonitorCoreTests) and
[app tests](../Tests/MacPerfMonitorTests) where they fit. Use a fake clock, source
fixtures, and a fake model for deterministic tests. Add the separate system test
host only for behavior that needs it.

Use an isolated test app identity and data directory. System tests must not quit
the user's running app, alter their recording choices, index real files, or run
network checks without approval. Test-only intents must not ship in release builds.

App Intents Testing proves the app-side system route, not all of Siri's language
understanding. Run real Siri smoke tests too. Record the OS, SDK, locale, and
Siri state. If a needed Apple capability is unavailable, record a blocked gate
rather than a passing mock test.

### Model Quality

Build at least 80 versioned cases with known evidence and expected findings.
Include normal systems, combined causes, stale scans, missing access, and cases
with too little evidence. At least 20 cases must challenge safety or attribution.
Run each case at least three times on each supported major model environment.

Score facts and links separately from prose. Require 100% valid numeric facts,
entity references, and allowed actions. Require at least 95% of answers to use
only supported explanations across the evaluation set. Any severe unsafe action
or disclosure is a release blocker, regardless of the average score.

Review uncertain cases by hand. Do not let a second model serve as the only
judge. A disclaimer does not excuse a false explanation. Keep recorded test
outputs redacted and local unless a tester explicitly shares them.

### Languages And Product Outcome

Localize intent metadata, phrases, consent, errors, and UI through
[Localizations/Localizable.xcstrings](../Localizations/Localizable.xcstrings).
Cover the app's English, Simplified Chinese, German, and French interfaces.
Check model and Siri language support separately on each target OS. Test
unsupported locales and mixed-language names without silently switching language.

Retain the existing localization, catalog-compilation, and string-coverage checks.
Get language review for public phrases and safety text before release.

In an opt-in usability test, at least eight of ten participants must answer
three of the four core questions within one minute per task. Use controlled
CPU, RAM, disk, and network cases. Count a correct evidence-gap answer as success
when the fixture has no defensible diagnosis. Collect no production usage telemetry.

## 12. Delivery And Decisions

### Milestones

| Milestone | Deliverable and exit gate | Rough effort |
| --- | --- | --- |
| M0: Prove platform support | Signed-bundle discovery, search/open schemas, core voice routes, model access, and a real system-test host. Approve the route matrix, probe target, and active-use resource ceiling. | 3 to 5 engineering days. |
| M1: Shared evidence | Typed service, freshness and coverage, bounded reads, rule-based reports, diagnostic rules, and fixture tests. | 5 to 8 days. |
| M2: Complete Siri | All catalogue actions, queries, entities, consent, discovery, annotations, packaging, and app-side system tests. | 7 to 12 days. |
| M3: Opt-in answers | Ask UI, model coordinator, read tools, output checks, language handling, and the evaluation set. | 7 to 12 days. |
| M4: Release qualification | Real Siri and model tests, privacy review, performance, accessibility, translations, installation, and upgrade checks. | 5 to 8 days. |

Planning range: 27 to 45 engineering days, roughly six to nine weeks for one
engineer with review support. This is not a delivery commitment. Apple platform
limits, access to test hardware, and language review can change the schedule.

M2 can be tested and delivered without M3. The combined feature is complete only
after both parts pass their gates. Keep inference behind an opt-in setting and
a build-time switch for rollback. Keep intent IDs stable when disabling the model.

### Risks And Decisions To Close

| Risk or decision | Proposed response |
| --- | --- |
| Siri cannot directly understand a custom monitoring action. | Test the App Shortcut route. Record any required named Shortcut or handoff. Ask the product owner to approve a scope change rather than claim full schema support. |
| SPM packaging fails to publish working metadata. | Prove the supported build steps in M0 or select a thin Xcode app wrapper. Preserve the package's data layer and CLI. |
| The on-device model is weak at causal reasoning. | Keep diagnoses in tested Swift rules. Limit generation to supported explanations and fall back to facts. |
| Inference worsens the slowdown being investigated. | Capture evidence first, enforce pressure gates, measure total cost, and keep the report path available. |
| Disk or network evidence is incomplete. | Show the gap and offer only the explicit scan or check needed to narrow it. |
| Apple changes APIs, model behavior, or Siri rollout. | Pin the tested OS and SDK in release evidence. Re-run gates after updates. Do not treat beta documentation as proof of shipped support. |
| Public network target and active model cost remain unproven. | Choose them in M0 with privacy review and measurements. Do not leave either decision to a generated prompt. |

The proposed product defaults are: macOS 15 stays supported, on-device answers
start at macOS 26, both privacy choices start off, and cloud or destructive
automation stays out of scope. Approve those defaults and the definition of Siri
coverage before implementation proceeds beyond M0.

### Definition Of Done

Both feature paths work from the distributed app. All P0 requirements and QA
gates pass, with evidence for real system integration and real model behavior.
There are no silent permission changes, cloud fallbacks, unbounded reads, or
placeholder intents. Update help, privacy text, support guidance, and release
notes to describe the verified behavior and its limits.

An unavailable required platform capability blocks the affected completion
claim. It must not become an undocumented exception to "fully implemented."

## Apple References

Reviewed on 2026-09-15. These sources describe platform capabilities, not a
successful integration test for this app. Recheck them against the release SDK.

- [A1: What's new in macOS 27](https://developer.apple.com/macos/whats-new/)
- [A2: App schema domains](https://developer.apple.com/documentation/appintents/app-schema-domains)
- [A3: System and in-app search](https://developer.apple.com/documentation/appintents/app-schema-domain-system-and-in-app-search)
- [A4: Generating content with Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [A5: Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
- [A6: Apple Intelligence and Siri AI](https://developer.apple.com/documentation/appintents/apple-intelligence-and-siri-ai)
- [A7: Providing contextual cues to Siri](https://developer.apple.com/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri)
- [A8: Testing your App Intents code](https://developer.apple.com/documentation/appintentstesting/testing-your-app-intents-code)
- [A9: Languages and locales with Foundation Models](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)
- [A10: Deprecated search schema and its replacement](https://developer.apple.com/documentation/appintents/appschema/systemintent/search)
- [A11: System open schema](https://developer.apple.com/documentation/appintents/appschema/systemintent/open)