# Lovejoy

A native macOS menu bar utility that maps Nintendo Switch **Joy-Con** inputs to system-wide
keyboard, mouse, and **mouse scroll** events — the feature JoyMapper doesn't have.

## Why native Swift?

| Option | Verdict |
|---|---|
| **Swift + SwiftUI + IOKit HID + CGEvent** *(chosen)* | Direct first-class APIs for HID, event injection, and menu bar apps. Smallest binary, lowest overhead. |
| Electron | Needs `node-hid` + `robotjs` native modules; `robotjs` can't do pixel-accurate `CGEventCreateScrollWheelEvent2` scrolls, which is the whole point. Ships 120 MB for a background utility. |
| Go | Needs cgo to reach `IOHIDManager` and `CGEvent` — lots of bridging, no benefit. |
| Rust / Tauri | Same cgo-equivalent pain plus an unwanted webview. |

## Building

Requires macOS 13+ and Swift 5.9+ (ships with Xcode 15 / Command Line Tools).

```bash
./scripts/build-app.sh
open build/Lovejoy.app
```

For a universal binary:

```bash
ARCHS="arm64 x86_64" ./scripts/build-app.sh
```

For dev iteration without bundling:

```bash
swift run
```

Note: `swift run` launches without an `.app` bundle, so the Accessibility permission may
not persist between runs. Use the build script for real testing.

## First-run setup

1. **Pair a Joy-Con.** Hold the tiny sync button on the side of a Joy-Con until the four
   LEDs blink, then add it from *System Settings → Bluetooth*. It will appear as
   "Joy-Con (L)" or "Joy-Con (R)".
2. **Grant Accessibility.** On first launch macOS will prompt. Go to *System Settings →
   Privacy & Security → Accessibility* and enable `Lovejoy`.
3. **Open the menu bar icon** (gamecontroller symbol) to see connected devices and pick
   a profile. Click *Open Mapping Editor…* to customize bindings.

## Built-in profiles

- **Scrolling** — A/B/X/Y mapped to scroll down/up, with D-pad scroll on the left Joy-Con.
  R/ZR are left/right click. Sticks drive the mouse cursor.
- **Gaming** — WASD on the D-pad, R/ZR left/right click, A=Space, B=Return, X=E, Y=Q.
- **Presentation** — A/B page right/left, X/Y page up/down. +/Home = space/esc.

## Project layout

```
Sources/Lovejoy/
├── App/                # App entry, AppDelegate, activation policy
├── HID/                # IOHIDManager wrapper, Joy-Con protocol, report parser
├── Mapping/            # Profile model, profile store (JSON), mapping engine
├── Output/             # CGEvent keyboard, mouse, scroll injectors
├── UI/                 # Menu bar popover, mapping editor window
└── Resources/
    └── Info.plist      # LSUIElement=true, Bluetooth usage strings
```

Profiles persist to `~/Library/Application Support/Lovejoy/profiles.json`.

## How the scroll feature works

The headline differentiator is `CGEvent(scrollWheelEvent2Source:units:.pixel,…)`, which
synthesizes pixel-granular scroll events identical to what a trackpad produces — so they
behave correctly in every app, including those that ignore line-based scrolls. When a
button bound to scroll is held, `MappingEngine` starts a `DispatchSource` timer on the
main queue that ticks at ~60 Hz (configurable per binding), emitting a fresh scroll event
each tick for smooth continuous scrolling. Release the button, timer cancels.

## License

MIT.
