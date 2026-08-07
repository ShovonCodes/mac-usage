<div align="center">

<img src="Assets/screenshots/app-icon.png" width="110" alt="Mac Usage app icon">

# Mac Usage

**A minimal, extendable macOS menu bar system monitor, inspired by iStat Menus.**

CPU · Memory · Battery · Network · Disk · Temperature · Fans

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)
![Zero dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![No Xcode project](https://img.shields.io/badge/build-SwiftPM%20only-lightgrey)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

<img src="Assets/screenshots/overview.png" width="400" alt="The Mac Usage panel: CPU history chart, memory pressure and usage rings, battery level and health rings, network speeds, temperatures, and fan RPM">

</div>

Click the gauge icon in the menu bar and everything that matters is one
panel: live CPU history, memory pressure, battery health, network
throughput, every temperature sensor your Mac has, and fan speeds.
Hover any card for the full story.

## Highlights

- **📊 CPU**: stacked user/system history chart with the current load and
  CPU temperature in the corner. Hover: every logical core as its own
  bar, grouped into performance and efficiency clusters on Apple
  Silicon, plus the usage breakdown and the five hungriest processes.
- **🧠 Memory**: pressure and usage rings, iStat-style. Hover:
  App/Wired/Compressed/Free breakdown and a top-processes list that
  matches Activity Monitor's numbers (it uses the same footprint metric).
- **🔋 Battery**: level ring with time remaining, health ring. Hover: a
  24-hour level history (hover a bar for that hour), charge details,
  max capacity, and cycle count.
- **🌐 Network**: live upload/download. Hover: a five-minute activity
  chart with per-direction peaks, Wi-Fi name, local and public IPs.
- **💽 Disk**: how full the boot volume is, with live read and write
  rates. Hover: used/free/total and a throughput chart. Mounted disk
  images are excluded, so opening a .dmg does not read as disk activity.
- **🌡️ Temperature**: every SMC sensor on your machine, grouped and
  color-coded from cool teal to alarming red; toggle raw sensor names on
  when you want the hardware's identity.
- **🌀 Fans**: live RPM with each fan's min/max range (fanless Macs
  correctly report "No fans detected").
- **🚨 Threshold alerts**: the menu bar icon grows a red badge when CPU
  passes 90%, memory pressure 80%, CPU temperature 90°, or battery drops
  below 10% while discharging; the panel explains why.
- **📟 Menu bar readouts**: a live CPU graph, memory percentage and
  network rates sit next to the icon, so the common checks need no
  click at all. Each one can be switched off to give the width back,
  or the whole strip can be, leaving just the icon.
- **⚙️ Settings**: hide cards you don't care about, drag to reorder
  them, start at login, and a privacy switch for the public-IP lookup.

<div align="center">
<table>
  <tr>
    <td align="center">
      <img src="Assets/screenshots/memory.png" alt="Memory hover panel: App/Wired/Compressed/Free breakdown and top processes with app icons">
      <br><sub><b>Memory details</b>: breakdown + Activity-Monitor-accurate processes</sub>
    </td>
    <td align="center">
      <img src="Assets/screenshots/battery.png" alt="Battery hover panel: 24-hour level history chart, charge details, health and cycle count">
      <br><sub><b>Battery details</b>: 24 h history, charge, health, cycles</sub>
    </td>
  </tr>
  <tr>
    <td align="center">
      <img src="Assets/screenshots/temperature.png" alt="Temperature hover panel: a color-coded grid of every SMC sensor, grouped by CPU and battery">
      <br><sub><b>Temperature details</b>: all 30+ sensors, heat-mapped</sub>
    </td>
    <td align="center">
      <img src="Assets/screenshots/settings.png" width="342" alt="Settings page: launch at login, public IP switch, and draggable card visibility toggles">
      <br><sub><b>Settings</b>: reorder cards by dragging, toggle what you see</sub>
    </td>
  </tr>
</table>
</div>

## Install (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/ShovonCodes/mac-usage/main/bootstrap.sh | bash
```

That fetches the latest code, builds the app, wraps it into a real
`MacUsage.app` bundle, installs it into `/Applications`, and launches it.
A gauge icon appears in the menu bar; click it to open the stats panel.
Quit from the panel's Quit button.

The installer asks whether the app should start automatically at login.
Press Enter for yes, or answer `n`. You can change your mind any time in
the app: gear icon → "Launch at login".

After installing:

- Spotlight finds it: ⌘Space → "Mac Usage".
- It behaves like any other installed app. No terminal needed again.

Prefer not to pipe curl into bash? Clone and run the installer yourself. It's the same
thing:

```bash
git clone https://github.com/ShovonCodes/mac-usage.git
cd mac-usage
./install.sh
```

### Requirements

- macOS 13 (Ventura) or newer
- Xcode Command Line Tools (`xcode-select --install` if you don't have
  them). These include the Swift compiler and Swift Package Manager, so
  there is nothing else to install

No Xcode project, no dependencies, just plain Swift Package Manager.

## Update

Run the install command again. It always fetches the latest code, rebuilds,
and replaces the installed app in place. There is no separate updater.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/ShovonCodes/mac-usage/main/uninstall.sh | bash
```

Quits the app, deletes it, removes the login item, and clears preferences.

Manual alternative: quit the app, drag `/Applications/MacUsage.app` to the
Trash, and (if you enabled start-at-login) remove it from
System Settings → General → Login Items.

## Privacy

Everything is read locally from the kernel, IOKit, and the SMC. The app
makes exactly **one** kind of network request: the public-IP lookup for
the network panel (api.ipify.org, cached for 10 minutes, only while the
panel is open). The "Fetch public IP" switch in Settings turns it off
entirely. No analytics, no update pings, nothing else.

## Behavior

- The menu bar shows the icon plus whichever readouts you leave on.
- Hovering a card expands a detail panel beside the main one.
- Panel open: stats refresh every **2 seconds**.
- Panel closed: the menu bar readouts keep refreshing every **2 seconds**,
  since they are on screen. Everything behind them (sensors, fan speeds,
  process lists) drops to **15 seconds**. Switch the menu bar readouts off
  and that first group drops to 15 seconds too.
- The menu bar readouts are three kernel calls per refresh, no
  subprocesses, which is why they can stay live this cheaply.
- No Dock icon; the app lives entirely in the menu bar.
- No admin rights needed for anything, including SMC fan/temperature
  reads.

## Developing

Edit the source, then re-run `./install.sh`. It rebuilds and replaces the
installed app in one step.

To try a build *without* touching the installed copy (you'll get a second
gauge icon in the menu bar next to the installed one):

```bash
swift build -c release && .build/release/MacUsage &
```

Kill that test copy with `pkill -f '.build/release/MacUsage'`. The
installed app keeps running.

## Contributing

Contributions are welcome. Fork, build with `./install.sh`, and raise a
PR. The codebase follows one simple pattern, so adding a new stat card is
four small steps:

1. Create a reader in `Sources/MacUsage/Readers/`, e.g. `DiskSpaceReader.swift`,
   with a `readCurrentUsage()`-style method returning a model struct.
2. Add the model struct to `Models/StatModels.swift`.
3. In `StatsStore.swift`: add a `@Published` property and call your reader
   inside `refreshAllStats()`.
4. In `StatsPanelView.swift`: add a `StatSectionCard` section rendering it.

Good next candidates: disk usage & I/O, Bluetooth device batteries, power
draw, per-core CPU.

If Mac Usage is useful to you, a ⭐ on the repo helps others find it.

## License

[MIT](LICENSE)
