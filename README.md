# Rise

**Micro-breaks for people who forget they have a body.**

Native macOS OLED full-screen break coach for desk workers. Eyes every 20 minutes. Stretch every 40. Bands or a walk every 90. Soft warning → dim takeover → checklist → Done reward.

```
  menu bar
       │
       ▼
  ┌──────────────────────────────┐
  │  Eyes + Posture starting  8  │   soft warning pill
  │  Every 20 minutes            │
  │        [ Delay 5 min ]       │
  └──────────────────────────────┘
       │
       ▼  screen dims (OLED black)
  ┌──────────────────────────────┐
  │  Eyes + Posture Reset        │
  │  About 40 seconds            │
  │                              │
  │  1  Gaze                 20s │
  │     Look ~20 ft away…        │
  │  2  Blink                ×10 │
  │  …                           │
  │         [ Done ]             │
  └──────────────────────────────┘
       │
       ▼
     ✓  Nice work · Break complete
```

> Drop a Product Hunt–ready `docs/demo.gif` when you have one. The flow above *is* the product.

---

## Why

Your chair is fine. Your monitor height is fine. The problem is **you haven't moved in 47 minutes** and your neck is filing a formal complaint.

- Static posture loads the same tissues until they complain
- Banner notifications get dismissed mid-sentence
- Timers in other apps are easy to ignore forever

Rise doesn't ask. It takes the screen over gently, walks you through a short checklist, and gets out of the way. You stay human between Slack threads.

---

## Features

- **Three physio-informed layers** — eyes, stretch, bands/walk
- **Soft warning pill** with delay options (no ambush)
- **OLED full-screen coach** — pure black, scannable steps, Done reward
- **Menu bar** — start Eyes / Stretch / Bands anytime
- **Quiet lunch + work hours** — optional scheduler silence windows
- **Login item** — opens at login via LaunchAgent
- **Native Swift** — AppKit + SwiftUI, not a Tk window from 2009

---

## The three layers

| | Every | Time | What |
|---|-------|------|------|
| **A** | 20 min | ~30–45 s | 20-20-20 eyes + posture reset |
| **B** | 40 min | ~90–120 s | Stand: neck → chest → mid-back → hip flexors → wrists |
| **C** | 90 min | 3–5 min | Resistance band mini-circuit *or* a real walk |

Full protocol: [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

---

## Install (macOS)

### Easy (app)

```bash
git clone https://github.com/ethandey/rise-mac.git
cd rise-mac
bash scripts/install.sh
```

That builds **Rise.app**, installs it to **`/Applications/Rise.app`**, starts the menu bar agent at login, and uses:

`~/Library/Application Support/Rise` for config and logs.

Or build only and drag the app yourself:

```bash
bash scripts/package-app.sh
open dist/          # Rise.app + Rise-1.1.0.zip
# Drag Rise.app → Applications, then open it once
```

**Requirements:** macOS 13+, Xcode Command Line Tools (`xcode-select --install`) to rebuild.

### What you get

- Native **Rise.app** with a Tahoe-style sunrise icon  
- Menu bar coach (no Dock icon — accessory app)  
- Home + office places, café soft mode when away  
- Active-time clocks (no nag mid-video / mid-walk)

---

## Usage

Menu bar icon near the clock:

| Action | What it does |
|--------|----------------|
| Modes → Eyes / Change / Walk | Start a break now |
| Set Home Here / Set Office Here | Pin current location |
| Standing desk (per place) | Sit/stand switch layer |

CLI:

```bash
bin/rise --menubar          # menu bar only
bin/rise --layer A          # single break
bin/rise --layer B
bin/rise --layer C
```

---

## Uninstall

```bash
bash scripts/uninstall.sh
```

Removes the login item and `/Applications/Rise.app`. Leaves Application Support prefs so a reinstall keeps settings.

---

## Built with

- **Swift** — full-screen overlay + menu bar (`native/`)
- **Python** — optional schedule daemon (`bin/desk_health.py`)
- **launchd** — login start, crash recovery

---

## Contributing

PRs welcome — especially movement cues, accessibility, and “this broke on my Mac” reports.

---

## License

[MIT](LICENSE) © 2026 Ethan Dey

---

*Your spine has been in a stand-up all day. Rise is the adjournment.*
