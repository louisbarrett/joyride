# Joyride — Joy-Con Input Mapper

## Overview

A macOS application that connects Nintendo Switch Joy-Con controllers via Bluetooth and maps their inputs to mouse and keyboard events. Inspired by JoyMapper (App Store), but adds the key missing feature: mapping buttons to **mouse scroll up/down**.

## Core Problem

JoyMapper is solid but does not support mapping Joy-Con buttons to mouse scroll wheel events. This is a blocker for use cases like:
- Scrolling documents/pages hands-free
- Controlling media or presentations
- Accessibility and ergonomic workflows

## Target Platform

- macOS (primary)
- Joy-Con controllers (Left, Right, or both) via Bluetooth HID

## Key Features

### Must-Have
- [ ] Connect Left and/or Right Joy-Con via Bluetooth
- [ ] Map any Joy-Con button to a keyboard key or key combo
- [ ] Map any Joy-Con button to a mouse click (left, right, middle)
- [ ] **Map any Joy-Con button to mouse scroll up or scroll down**
- [ ] Map Joy-Con analog sticks to mouse cursor movement
- [ ] Save and load mapping profiles
- [ ] Menu bar / system tray app (runs in background)

### Nice-to-Have
- [ ] Multiple profiles (e.g. "Scrolling", "Gaming", "Presentation")
- [ ] Per-app profile switching (different mappings for different frontmost apps)
- [ ] Gyroscope/motion input support
- [ ] Turbo / repeat mode for held buttons
- [ ] Deadzone and sensitivity configuration for analog sticks
- [ ] Visual button state display (for setup/debugging)

## Technical Approach

### Bluetooth / HID Layer
Joy-Cons communicate over Bluetooth as HID devices. Options:
- **IOKit HID** — macOS native, low-level, full access to HID reports
- **hidapi** — cross-platform C library wrapping IOKit, easier to use
- **GameController.framework** — Apple's high-level API; simpler but may abstract away button identity in ways that limit remapping

Recommended: `IOKit HID` or `hidapi` for maximum control over raw input reports.

### Input Injection Layer
To synthesize keyboard and mouse events:
- **CGEventCreateKeyboardEvent / CGEventCreateMouseEvent** — Core Graphics event injection, works system-wide
- **CGEventCreateScrollWheelEvent** — used specifically for scroll wheel simulation
- Requires **Accessibility permission** (Privacy & Security → Accessibility)

### App Architecture
- Swift + SwiftUI (macOS native, menu bar app)
- Separate HID polling thread → event queue → main thread for UI
- Mapping config stored as JSON in `~/Library/Application Support/Joyride/`

### Scroll Implementation (Key Differentiator)
```swift
// Scroll down example
let scrollEvent = CGEvent(
    scrollWheelEvent2Source: nil,
    units: .pixel,
    wheelCount: 1,
    wheel1: -10, // negative = scroll down
    wheel2: 0,
    wheel3: 0
)
scrollEvent?.post(tap: .cghidEventTap)
```
Button hold → repeat scroll events on a timer for continuous scrolling.

## Joy-Con Button Map (Right Joy-Con)

| Button | HID Bit |
|--------|---------|
| A      | 0x08    |
| B      | 0x04    |
| X      | 0x02    |
| Y      | 0x01    |
| R      | shoulder|
| ZR     | trigger |
| +      | plus    |
| Stick  | click   |
| Home   | home    |

(Left Joy-Con mirrors with D-Pad, L/ZL, minus, etc.)

## Permissions Required

- **Bluetooth** — to connect Joy-Cons
- **Accessibility** — to inject keyboard/mouse/scroll events system-wide
- No App Store distribution initially (Accessibility permission blocks sandboxing)

## Project Structure (Proposed)

```
joyride/
├── PROJECT.md
├── Joyride.xcodeproj/
├── Joyride/
│   ├── App/
│   │   ├── JoyrideApp.swift        # App entry, menu bar setup
│   │   └── AppDelegate.swift
│   ├── HID/
│   │   ├── JoyConManager.swift     # Bluetooth discovery & connection
│   │   ├── JoyConDevice.swift      # HID report parsing per device
│   │   └── HIDReportParser.swift   # Button/stick state extraction
│   ├── Mapping/
│   │   ├── MappingProfile.swift    # Codable profile model
│   │   ├── MappingEngine.swift     # Button event → HID output dispatch
│   │   └── ProfileStore.swift      # Load/save JSON profiles
│   ├── Output/
│   │   ├── KeyboardInjector.swift  # CGEvent keyboard synthesis
│   │   ├── MouseInjector.swift     # CGEvent mouse click synthesis
│   │   └── ScrollInjector.swift    # CGEvent scroll wheel synthesis
│   └── UI/
│       ├── MenuBarController.swift
│       ├── MappingEditorView.swift
│       └── DeviceStatusView.swift
└── JoyrideTests/
```

## Open Questions

- Debounce strategy for scroll: fixed pixel delta per tick vs. accelerating scroll on hold?
- Should stick-to-cursor use raw delta or acceleration curve?
- Distribute as direct download (no sandbox) or find App Store workaround?

## Reference

- [Nintendo Switch Joy-Con Bluetooth HID protocol](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering)
- [hidapi](https://github.com/libusb/hidapi)
- Apple `CGEventCreateScrollWheelEvent2` documentation
