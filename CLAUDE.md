# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MacUsage is a macOS menu bar system monitor (iStat Menus-inspired) written in Swift/SwiftUI. Plain Swift Package Manager executable, no Xcode project, no dependencies, macOS 13+.

## Commands

```bash
swift build -c release          # build (no tests exist)
./install.sh                    # the dev loop: build → assemble .app → install to /Applications → relaunch
./install.sh 2>&1 | grep -E "error|✓"   # quieter variant
```

- `install.sh` generates the Info.plist, ad-hoc codesigns, and pkills the old instance. The bundle version string lives in `install.sh`, not in any plist in the repo.
- To try a build **without** replacing the installed app: `swift build -c release && .build/release/MacUsage &` (second gauge icon appears); kill with `pkill -f '.build/release/MacUsage'`.
- `open` occasionally fails with LaunchServices error -600 right after a rapid kill/replace. Just retry it.
- End users install via `curl -fsSL .../bootstrap.sh | bash` (clones to a temp dir, runs install.sh) and remove via `uninstall.sh`. Installer prompts read from `/dev/tty`, not stdin, because stdin carries the piped script.
- Convention in this repo: Claude commits, the user pushes.

## Architecture

Data flows one way: **Readers → StatsStore → SwiftUI views**.

- `Readers/*.swift`: one class per data source, each returning plain structs from `Models/StatModels.swift`. To add a stat: new reader, new model struct, a `@Published` property + call in `StatsStore.refreshAllStats()`, a card in `StatsPanelView`.
- `StatsStore` (@MainActor) owns **two** refresh timers. Fast lane (`refreshFastStats`: CPU, memory, network speed, all pure syscalls) runs at 2 s while the panel is open **or** the menu bar strip is on, else 15 s. Slow lane (`refreshSlowStats`: everything touching SMC, a subprocess or the network) is 2 s panel-open, 15 s otherwise. The split exists so the strip can stay live without dragging the SMC to a 2 s beat. Cheap readers run on the main thread; anything that talks to a kernel driver or spawns a subprocess runs in `Task.detached` and publishes back on main. Expensive readers are additionally gated: memory process list (`top`, ~0.5 s CPU) every 6 s and only while the panel is open; network info every 10 s, panel-open only.
- `MenuBarStrip.swift`: draws the status item image (glyph + live readouts) as one NSImage. Stays a **template image** unless alerting, so macOS recolors it for light/dark menu bars; that is why it is monochrome and why every draw takes its color from the caller. The status item is `variableLength` so switching segments off returns menu bar width. `AppDelegate.refreshStatusItem` rebuilds it once per `StatsStore.menuBarTick`, a single signal rather than one subscription per published value.
- `MacUsageApp.swift`: AppDelegate owns an `NSStatusItem` plus a hand-rolled borderless, **non-activating** `NSPanel` instead of SwiftUI's `MenuBarExtra`. Reason: MenuBarExtra positions its window edge-aligned and can only be corrected after it's visible (flicker). The panel frame is computed centered under the icon *before* `orderFront`. Left click toggles the panel; right click builds a transient `NSMenu` (attach, `performClick`, detach, since a permanent menu would swallow left clicks).
- `DetailPanelController`: second floating panel that appears beside the main one when a card is hovered, top-aligned. Dismissal is not per-view hover state: a 0.15 s timer watches the global pointer and closes only when it leaves both windows' frames (inset −8 px, 2 missed ticks). Card hover only ever *expands* (`onHover { if $0 … }`).
- Panel size changes flow through notifications: views report size via the `SizeReporter` modifier → `AppDelegate.panelContentSizeChanged` → `resizePanel` keeps the top edge pinned. `AppDelegate.panelWillHide` tells views to collapse hover state (they never get `onDisappear`; the hosting view stays alive between opens).

### Non-activating window consequences (recurring trap)

The panel never becomes the "active" window, so AppKit/SwiftUI behave unusually. Known consequences:
- `.help()` tooltips are slow/flaky → charts implement custom hover (e.g. battery history).
- It cannot take keyboard focus at all, so a text field in the panel is inert. This is why Settings is a real window (`SettingsWindow.swift`) rather than a page inside the panel.
- Two former workarounds are **gone**, and should not come back: a hand-drawn `SettingSwitch` (system switches rendered gray) and a raw `DragGesture` card reorder (system drag sessions were unreliable). Both existed only because Settings lived in the panel; in a normal window `Toggle` and `List.onMove` work. Anything new that needs a real control belongs in the Settings window, not the panel.

### Data-source notes (hard-won, don't regress)

- Memory top-processes uses `top -l 1 -o mem` because its footprint metric matches Activity Monitor; `ps` rss ranks compressed-heavy processes wrong, and `proc_pid_rusage` can't see most pids without root.
- Memory pressure = 100 − sysctl `kern.memorystatus_level`. Memory breakdown "App" = internal − purgeable.
- SMC (fans + temperatures) via `SmcConnection`, no root needed; sensor keys are discovered by scanning at startup, not hard-coded (differs per Mac model). Fan keys: `F#Ac/Mn/Mx`.
- Battery history seeds 24 h from `pmset -g log` on first read (~2 s, kept off-main); live samples merge in hourly buckets.
- Battery health: System Settings' "Maximum Capacity" is powerd's model output, published in **no** public API, and every registry ratio reads several points higher (Nominal/Design, Raw/Design). Read it via `system_profiler SPPowerDataType -json` (~0.2 s, cached hourly in `BatteryReader`); registry ratio is only the pre-first-fetch fallback.
- Per-core CPU: `host_processor_info` already returns per-core ticks; `CpuUsageReader` keeps them instead of only summing. **Core order is not the sysctl order**: sysctl calls the fastest cluster `perflevel0`, but the kernel reports cores slowest-cluster-first. Verified on M1 by pinning four userInteractive threads: indices 4-7 hit 98%, 0-3 stayed idle, so 0-3 are Efficiency and 4-7 Performance. `CpuTopology` walks perflevels backwards for this reason. Intel has no perflevels, so cores come back unlabelled.
- Disk I/O from each `IOBlockStorageDriver`'s `Statistics` dict (`Bytes (Read)`/`Bytes (Write)`, counters since boot, no root). **Skip virtual devices**: a mounted .dmg publishes an identical driver, so filter on the provider's `Protocol Characteristics` → `Physical Interconnect` == `"Virtual Interface"`. Same spirit as the network reader's virtual-interface skip.
- Disk free space uses `volumeAvailableCapacityForImportantUsage`, not the plain available-capacity key: it counts purgeable space and so matches Finder and System Settings. The plain key reads several GB lower.
- Network speed from `NET_RT_IFLIST2` 64-bit interface counters, skipping virtual interfaces (`lo/utun/awdl/llw/gif/stf/bridge/ap`).
- Wi-Fi SSID: CoreWLAN returns nil without location permission → falls back to parsing `ipconfig getsummary`.
- The public-IP lookup (api.ipify.org, 10-min cache, panel-open only) is **the app's only network request** and is disabled by the `fetchPublicIP` default. Keep it that way, the README promises it.
- Launch-at-login uses `SMAppService` through `LoginItemManager`; scripts flip it by running the installed binary with `--set-login on|off` (handled at the top of `applicationDidFinishLaunching`, exits before any UI).

### Persistence

`HistoryStore` keeps a 24 h record at one row per minute in `~/Library/Application Support/MacUsage/history.json` (**not** the defaults domain, so `uninstall.sh` deletes it separately). Live 2 s samples stay in memory only; 2 s over a day would be 43,200 rows per series and nothing reads that detail. Writes are atomic (write sibling, rename) and an unparseable file is discarded rather than repaired, because graphs are not worth blocking launch over. On launch the last 15 min seed the live CPU/network charts so they are not blank; those come back sparse at 1-minute resolution, which time-bucketed charts draw honestly.

All settings are `@AppStorage` in the `com.macusage.app` defaults domain (wiped by `uninstall.sh`): `showCpuCard` … `showFansCard`, `cardOrder` (comma-separated `ExpandableSection` raw values; parser drops unknowns and appends missing so new cards appear for old installs), `fetchPublicIP`, `showsTemperatureSensorNames`, `showMenuBarStrip`, `menuBarShowCpu`/`Memory`/`Network`/`Temperature`, `showDiskCard`, `showsPerCoreUsage`. Menu bar keys default to **on** (temperature off), so they are read via `MenuBarSettings`, which checks `object(forKey:)` for absence rather than `bool(forKey:)` (that returns false for unset keys and would silently invert every default).

## Subagents

`.claude/agents/macos-internals-prober.md`: before building any new stat card, delegate the "can we read X without root, and what does it cost?" question to this agent. It compiles and runs throwaway probes outside the repo and returns a verdict with the exact working API call. Don't spend main-session context spelunking IOKit/SMC/sysctl by hand; several documented APIs silently fail unprivileged, and the agent's prompt carries the list of dead ends already paid for.

## Gotchas

- Swift language mode 5: regex literals must use extended delimiters `#/…/#`, bare `/…/` does not parse.
- CPU clock speed (iStat shows it) is not readable without root on Apple Silicon, so it is deliberately omitted.
- Fanless Macs legitimately show "No fans detected".
- Comment style is deliberate: banner comments explaining *why* at the top of each file/section, written for someone new to macOS internals. Match it.
