# Rise

Micro-breaks for people who forget they have a body.

Native macOS menu-bar coach for desk work. It counts time only while you’re actually at the keyboard, matches home and office, and stays soft when you’re out at a café.

---

## How it works

| | |
|---|---|
| **Where you are** | **Home** and **Office** share the same full desk routine. **Away** (café, etc.) uses soft popups only — no full-screen takeover. |
| **How clocks run** | Minutes accrue while you use the Mac. Idle pauses them. Walking away counts as the break; debt is not banked for when you return. |
| **What you get** | Short, scheduled resets: eyes, posture change, and a real walk when you’ve been at the desk long enough. |

Full detail: [docs/PROTOCOL.md](docs/PROTOCOL.md).

---

## Layers

| Layer | Active time | Duration | Style | What it is |
|-------|-------------|----------|--------|------------|
| **Eyes** | ~25 min | ~30 s | Soft pill | Far gaze, blinks, quick posture |
| **Change** | ~40 min | ~90 s | Firm at desk | Unload sitting/standing, light mobility |
| **Walk** | ~90 min | 3–5 min | Firm at desk | Leave the screen — walk or café-friendly move |
| **Switch** | ~30 min | ~30 s | Firm at desk | Sit ↔ stand (only if standing desk is on) |

| Place | Routine | Presentation |
|-------|---------|--------------|
| Home | Full desk layers | Firm full-screen when due |
| Office | Same as home | Firm full-screen when due |
| Away | Seated / café-friendly | Soft floating popup |

---

## Features

| | |
|---|---|
| Activity-aware clocks | Pause for video or AFK; credit real walks |
| Home & office | Same schedule; standing desk can differ per place |
| Café mode | Soft checklist when you’re not at a desk place |
| Menu bar | Next break, modes, places — no Dock icon |
| Login start | Opens with your session |
| Native Swift | AppKit + SwiftUI |

---

## Install

**Requirements:** macOS 13+, Xcode Command Line Tools (`xcode-select --install`) if you rebuild.

| Method | Commands |
|--------|----------|
| Install to Applications | `git clone https://github.com/ethandey/rise-mac.git && cd rise-mac && bash scripts/install.sh` |
| Package only | `bash scripts/package-app.sh` then open `dist/` and drag `Rise.app` to Applications |

After install:

| | |
|---|---|
| App | `/Applications/Rise.app` |
| Data | `~/Library/Application Support/Rise` |
| Uninstall | `bash scripts/uninstall.sh` |

---

## Usage

| Menu | What it does |
|------|----------------|
| **Next** | Countdown to the next break (active time) |
| **Modes** | Start Eyes, Change, or Walk now |
| **Set Home Here** | Pin home to your current location |
| **Set Office Here** | Pin office (same routine as home) |
| **Standing desk** | Per place; enables sit/stand switch |

```bash
bin/rise --menubar
bin/rise --layer A   # Eyes
bin/rise --layer B   # Change
bin/rise --layer C   # Walk
```

---

## Project layout

| Path | Role |
|------|------|
| `native/` | Swift app source |
| `assets/AppIcon/` | App icon (`.icns` + master PNG) |
| `docs/PROTOCOL.md` | Movement protocol |
| `scripts/install.sh` | Build, install, login item |
| `scripts/package-app.sh` | Build `Rise.app` + zip in `dist/` |

---

## License

[MIT](LICENSE) © 2026 Ethan Dey
