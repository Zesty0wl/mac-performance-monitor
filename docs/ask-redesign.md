# Ask About This Mac: Redesign

Date: 2026-09-30

Status: Built on `feature/ask-redesign` (September 2026). Replaces Part B of the
[AI integration PRD](ai-integration-prd.md) and the preview it describes.

## Goal

Help someone who is new to Macs answer a specific question about their own
machine, in plain language, and hand them to the right chart when they want to
look closer. "Why is my Mac slow?", "Why is the fan loud?", "Is something using
too much memory?", "How is my battery doing?"

Ask is the calm front door. It stays simple and friendly. The main window, where
people land when they follow a chart link, is where the detail lives.

## Principles

1. **Swift gathers and judges; the model decides and explains.** Everything
   with a right answer (reading history, comparing with what is normal for this
   Mac, arithmetic, spotting spikes and growth, choosing chart links) is done in
   Swift and unit-tested. The model does two narrow jobs: pick which parts of
   the Mac a question is about, and explain the facts Swift found.
2. **Facts are ready to read.** Swift hands the model finished phrases such as
   "busy for 40 of the last 60 minutes, about twice as much as usual". The model
   never calculates.
3. **The app owns the links.** Every area Swift checked gets a chart card,
   whether or not the model mentions it.
4. **Friendly first.** Short answers, everyday words, one suggested next step.
   Technical terms are explained in a few words or avoided.
5. **Nothing leaves the Mac.** Apple's on-device model only.

## Why the old preview did not deliver

The preview was built for a 4,096-token model it did not trust. It planned
checks as hand-written JSON, labelled every fact with a letter, and rejected
any answer containing a number it could not match. That produced stiff, hedged
answers or outright refusals, and it needed optional downloaded models (Qwen,
DeepAnalyze) with their own worker process, MLX and llama.cpp runtimes.

A prototype against the macOS 27 model (September 2026) settled the new shape:

| Approach | Result |
| --- | --- |
| Model calls data tools when it wants | Called none, invented both answers |
| Tool use forced on | Looped calling tools, never answered |
| Model picks areas, Swift gathers, model explains | Correct and friendly, 8 to 12 seconds |

## Platform

- macOS 27 or later. Ask is hidden on earlier systems.
- Apple's on-device model (`SystemLanguageModel.default`). On macOS 27 it
  reports an 8,192-token context (AFM 3 Core Advanced), enough for the
  instructions, three area summaries and several follow-ups.
- When Apple Intelligence is off, not ready, or the language is unsupported,
  the area tiles and their Swift summaries still work; only typed questions
  need the model. The window says why, in one sentence, with a way to fix it.
- Private Cloud Compute (32K context, reasoning) needs a managed entitlement
  that Apple grants for App Store apps. It is not used. The model sits behind
  one small interface so it could be added if that changes.

## What someone sees

One window, **Ask About This Mac**, opened from the toolbar, the menu bar
panel, the Ask menu and Siri ("Ask Mac Performance Monitor").

1. **A one-line verdict** at the top, from Swift: "Your Mac is running
   smoothly" or "Your Mac is busier than usual: Xcode is using a lot of the
   processor."
2. **Area tiles**: Processor, Memory, Graphics, Neural Engine, Network,
   Storage, Battery, Heat. Each shows a plain status (Calm, Busy,
   Worth a look) and one short line. Clicking a tile shows that area's summary
   straight away and, with the model available, a short explanation.
3. **Starter questions** as buttons: "Why is my Mac slow?", "Why is the fan
   loud?", "What's using my battery?", "Is anything using too much memory?"
4. **A question box**: "Ask anything about your Mac".
5. **Answers** as cards: the explanation streams in, then chart cards
   ("See it on a chart: Processor, last hour") that open Explorer at that time
   with the right charts and apps selected, a "What I looked at" disclosure
   with the underlying facts, and two or three follow-up questions.

No settings page, token counts, model names or evidence IDs in the main flow.
A single switch in Settings turns Ask off.

## How a question is answered

1. **Plan (model, guided generation).** From the question and the current
   time, produce up to three areas, a time description ("last hour", "around
   10am today", "yesterday afternoon") and an optional app name.
2. **Resolve (Swift).** Turn the time description into an exact interval,
   clamp it to recorded history, match the app name against recorded processes,
   and add the overall check when a question is too vague to plan from.
3. **Gather (Swift).** Build an `AreaBrief` for each area over that interval.
4. **Explain (model, tools off).** Stream a short answer written only from the
   briefs. A follow-up keeps the conversation in the same session; older briefs
   are trimmed first when the context fills.
5. **Present (app).** Chart cards and facts come from the briefs, not from the
   model's text.

## Area briefs

An `AreaBrief` is built in Core from recorded history and the live sample. It
holds:

- a status (calm, busy, unusual, needs attention, or unknown);
- ready-to-read lines about now and the interval;
- what is normal for this Mac, from its own history at the same time of day
  over the last week, when there is enough of it;
- the apps responsible, ranked by average use over the interval;
- notable events: spikes, sustained load, steady memory growth, alerts;
- gaps: not recorded, tracking off, sensor unavailable;
- a chart link: Explorer lanes, time range and processes to select.

| Area | Main sources |
| --- | --- |
| Processor | Total CPU, load, per-process CPU |
| Memory | Pressure, app memory, compression, swap, per-process footprint and growth |
| Graphics | GPU utilization and power, per-process GPU |
| Neural Engine | Neural Engine activity and power |
| Network | Throughput in and out, per-app network when tracking is on |
| Storage | Disk throughput and busy time, startup disk free space and its trend |
| Battery and Energy | Charge, battery power, per-process energy impact |
| Heat | Thermal pressure, die temperatures, fan speed |
| Overall | The worst status among the others, and why |

Each brief also carries **Things that help**: safe next steps written in Swift
for that area and status, so the model picks advice from a known list. Only an
app (or the app a helper belongs to) is ever suggested for quitting; a busy part
of macOS gets patience and, if it lasts hours, a restart. Processes are
classified by where they live on disk: app bundles, macOS system locations, or
background processes.

Memory pressure's middle band is Busy, not Worth a look: macOS compressing
memory is coping. Worth a look needs pressure of 50 or more, growing swap, or
pressure well above this Mac's own normal.

Briefs are the product's knowledge. When an answer is wrong, the fix is almost
always in a brief, and briefs are tested without the model.

## Cost

Ranking apps is the expensive read: a busy Mac records hundreds of thousands
of per-process rows an hour. The start page's tiles show no apps, so they skip
it and share one read of system history across all eight parts (about 1.5
seconds on a Mac with a 3 GB history). A vague question builds every part
without apps, then ranks apps only for the two parts that stood out. A typical
answer takes 8 to 16 seconds, most of it the model.

## What the model still gets wrong

The on-device model is small. In testing it follows the facts well but
sometimes moves a fact to the wrong part, calls a busy part "not normal", or
adds a harmless extra step such as restarting the Mac. The rules that matter
most are enforced in Swift rather than in the prompt: statuses, numbers,
advice lists, chart links, and the "nothing needs doing" line when every part
checked is calm. The facts behind every answer are under "What I looked at".

## Testing

- Core unit tests build briefs from fixed histories: busy build, memory growth,
  idle Mac, full disk, no recording, battery drain, thermal throttling.
- A plan-resolution test suite checks time descriptions and app matching.
- A real-model evaluation (`--ask-eval`) runs scripted questions against
  fixture briefs on an eligible Mac and prints the plans and answers for review.
  It is run by hand after model or prompt changes, not in CI.

## Removed

The preview's report topics and App Shortcuts, the JSON investigation loop,
the answer validator, the Qwen and DeepAnalyze downloads, the inference worker
process, the MLX, swift-transformers and llama.cpp dependencies, and the Metal
toolchain step they needed. Previously downloaded model files are deleted once
on first launch of the new version.
