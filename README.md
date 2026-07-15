# Mac Usage

A minimal, extendable macOS menu bar system monitor — inspired by iStat Menus.
Click the gauge icon in the menu bar to see live CPU usage, memory usage,
fan speeds, and temperatures.

## Requirements

- macOS 13 (Ventura) or newer
- Xcode Command Line Tools (`xcode-select --install` if you don't have them)

No Xcode project, no dependencies — plain Swift Package Manager.

## Install (one command)

```bash
git clone https://github.com/ShovonCodes/mac-usage.git
cd mac-usage
./install.sh
```

That builds the app, wraps it into a real `MacUsage.app` bundle, installs it
into `/Applications`, and launches it. A gauge icon appears in the menu bar;
click it to open the stats panel. Quit from the panel's Quit button.

After installing:

- Spotlight finds it: ⌘Space → "Mac Usage".
- It behaves like any other installed app — no terminal needed again.
- To start it automatically at every login: `./install.sh --login`
  (or answer `y` when the installer asks).

Re-run `./install.sh` any time to update the installed copy — for example
after pulling new code or editing the source.

## Developing (run without installing)

```bash
./run.sh
```

Builds a release binary and launches it directly from `.build/` — quicker
for a change-and-test loop. To just build without launching:
`swift build -c release` (binary lands at `.build/release/MacUsage`).

## Behavior

- Menu bar shows only an icon — all stats live in the click-to-open panel.
- Panel open: stats refresh every **2 seconds**.
- Panel closed: a light background refresh every **15 seconds** keeps the
  data warm so the panel never opens empty.
- No Dock icon; the app lives entirely in the menu bar.

## How it works

| File | Job |
|---|---|
| `MacUsageApp.swift` | Entry point; puts the app in the menu bar |
| `StatsPanelView.swift` | The dropdown panel UI |
| `StatsStore.swift` | Owns readers + the adaptive refresh timer |
| `Readers/CpuUsageReader.swift` | CPU % from kernel tick counters |
| `Readers/MemoryUsageReader.swift` | RAM usage from kernel VM statistics |
| `Readers/SmcConnection.swift` | Low-level channel to the SMC chip (IOKit) |
| `Readers/FanAndTemperatureReader.swift` | Fan RPM + temp sensors on top of SMC |
| `Models/StatModels.swift` | Plain data structs the UI renders |

Fan and temperature data come from the SMC (System Management Controller).
Sensor key names differ across Mac models, so at startup the app scans all
available SMC keys and keeps the ones that look like CPU/GPU/battery
temperature sensors — this makes it work on both Intel and Apple Silicon
without hard-coded sensor lists. Reading the SMC needs no admin rights.

Note: fanless Macs (MacBook Air) will show "No fans detected" — that's correct.

## Adding a new stat (the extension pattern)

1. Create a reader in `Sources/MacUsage/Readers/`, e.g. `NetworkSpeedReader.swift`,
   with a `readCurrentUsage()`-style method returning a model struct.
2. Add the model struct to `Models/StatModels.swift`.
3. In `StatsStore.swift`: add a `@Published` property and call your reader
   inside `refreshAllStats()`.
4. In `StatsPanelView.swift`: add a `StatSectionCard` section rendering it.

Good next candidates: battery/voltage, network up/down speed, disk I/O,
per-process top consumers.

## Uninstall

Quit the app, then delete `/Applications/MacUsage.app`. If you enabled
start-at-login, also remove it from System Settings → General → Login Items.
