# TempMonitor 🔥

A native macOS app (SwiftUI + Metal) that shows and monitors CPU and GPU temperatures.

- Live CPU and GPU gauges, hottest sensor, session min/max, and a 2-minute history sparkline
- A full-window **Metal** fire background that grows hotter, taller and faster with temperature
- Every individual sensor listed, colour-coded
- A menu bar readout (🔥 CPU 52° GPU 47°) that stays while the app runs
- °C / °F, update interval 0.5–5 s
- **History recording**: every reading is logged while the app is open, with CSV export and optional auto-save on quit
- Works on **Apple Silicon** (M1–M4: SMC `Tp/Te/Tg/Tf` keys plus IOHID sensors) and **Intel** (SMC `TC*/TG*` keys)

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`). The full Xcode app is not needed.

```bash
cd ~/Desktop/Projects/TempMonitor
./build.sh              # builds both versions
./build.sh arm64        # Apple Silicon only
./build.sh x86_64       # Intel only
./build.sh universal    # both versions plus a combined universal app
```

Output:

| Version | App | Zip |
|---|---|---|
| Apple Silicon | `dist/arm64/TempMonitor.app` | `dist/TempMonitor-arm64.zip` |
| Intel | `dist/x86_64/TempMonitor.app` | `dist/TempMonitor-x86_64.zip` |

The apps are ad-hoc signed. If you copy them to another Mac, right-click → **Open** the first time, or run
`xattr -dr com.apple.quarantine TempMonitor.app`.

## Recording history

The red **REC** pill in the header shows that recording is on and how long it has run. Click it to pause or resume.
The ⬇︎ menu next to it, the **File** menu (⌘S) and the menu bar item all let you:

- **Export History as CSV…**: saves to `~/Documents/TempMonitor/` by default
- **Export Graph as PNG… / PDF…** (⇧⌘S for PNG): a chart of the whole session with CPU and GPU lines, peak markers and avg/max/min stats, in your chosen °C/°F
- **Auto-save CSV + Graph When Quitting**: writes `TempMonitor_<start time>.csv` and a matching `.png` there automatically
- **Clear History**, and switch recording on or off (the setting is remembered)

CSV columns: `timestamp, elapsed_s, cpu_avg_C, gpu_avg_C`, then one column per sensor (always in °C).
The file opens directly in Numbers or Excel. History is kept in memory for up to ~500,000 samples
(about 5.8 days at a 1 s interval).

## Layout

```
Sources/
  TempMonitorApp.swift      app entry, window, menu bar item
  ContentView.swift         dashboard UI (cards, ring gauges, sparklines, sensor grid)
  FlameBackground.swift     MTKView + Metal shader (compiled at runtime)
  TemperatureMonitor.swift  polling, statistics, history
  SensorHub.swift           sensor discovery and classification
  Theme.swift               colours and units
  HistoryRecorder.swift     session recording and CSV export
  GraphRenderer.swift       PNG / PDF chart export (Core Graphics)
  C/sensors.h, smc.c, hid.c AppleSMC + IOHID access (Swift bridging header)
Resources/
  Info.plist, AppIcon.icns, AppIcon-1024.png, AppIcon.iconset/
Tools/make_icon.py          regenerates the icon (python3 + numpy + Pillow)
```

## Notes

- The app is not sandboxed, because reading the SMC needs direct IOKit access. It does not need root.
- Apple doesn't document sensor keys and they vary by chip. The app enumerates every SMC key at launch
  and keeps those that return plausible temperatures. On Apple Silicon, the CPU value is the average of the
  P-core and E-core cluster sensors.
- The architecture is detected at runtime, so the Intel build also reads correct sensors under Rosetta.
