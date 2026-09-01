# Reddit post: r/macosapps

## Title

> I made a free, open source performance monitor for Apple silicon Macs. It logs everything to a local database and can tell you which process is using the GPU, including which local AI models

Shorter alternative:

> Mac Performance Monitor: free, open source menu bar monitor that logs history and shows per-process GPU usage on Apple silicon

## Body

Hi all, I've been building a native menu bar performance monitor for the past year and it's at the point where I'd love more people to try it.

**What makes it different from Activity Monitor / iStat / Stats:**

- **It remembers.** Everything is logged to a local SQLite database, so instead of "my Mac feels slow right now" you can look at the pressure timeline for the last 7 days, see when swap started climbing, and which process was responsible.
- **Per-process GPU usage on Apple silicon, with no helper or root.** The GPU tab shows who is actually using the GPU, clock states, GPU and Neural Engine power, and it recognises AI runtimes (Ollama, llama.cpp, MLX, LM Studio, Core ML, Apple Intelligence) along with the model they're serving. Handy if you run local LLMs and want to know what they're really costing you.
- **Leak detection.** It flags processes whose memory footprint climbs steadily, and keeps a log of memory pressure events.
- **A Hardware tab** that draws your chip core by core (CPU clusters, GPU, Neural Engine, unified memory) and gives you a searchable tree of every bus and device on the machine.
- **Plain-language verdicts.** The dashboard opens with an actual sentence about how your Mac is doing, not just a wall of numbers.

**The boring but important stuff:**

- Free and open source (MIT), no telemetry, no analytics, nothing leaves your Mac
- Signed and notarized pkg, auto-updates via Sparkle
- Native Swift, and careful about its own footprint (a monitor that burns CPU defeats the point)
- Requires macOS 15+ on Apple silicon

Download and source: https://github.com/Zesty0wl/mac-performance-monitor

Happy to answer questions, and very open to feature requests and bug reports.

## First comment (post immediately after submitting)

The GPU tab, showing per-process usage and AI runtime detection, is the part I'm most proud of:

(attach `docs/images/gpu.png`)

## Screenshot plan

- Lead image: `docs/images/dashboard.png`. It reads as a polished system monitor even at thumbnail size, and the machine shown is genuinely stressed (59% pressure, 9.1 GB swap), which makes the app look useful rather than staged.
- First comment: `docs/images/gpu.png`. It's the most differentiated screenshot but too table-heavy to survive thumbnailing, so it does its work at full size in the comments where the local-LLM crowd will find it.
- If gallery posts are allowed: dashboard first, GPU second, processes or hardware third.

## Notes

- "past year" in the opening line is a guess; adjust if wrong.
