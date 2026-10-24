# RodentGym

**See what your Magic Mouse and Magic Trackpad send, and what macOS actually delivers.**

RodentGym is a small native macOS utility for diagnosing pointer problems. Right-click doing nothing, clicks going missing, a mouse that suddenly behaves like it has one button: RodentGym shows each step between your finger and the app, and flags the step where the click is lost.

![RodentGym showing a Magic Mouse and Magic Trackpad](docs/screenshot.png)

## What it shows

For every connected Magic Mouse and Magic Trackpad (and optionally a MacBook's built-in trackpad):

- **Live touches** on a drawing of the device at the sensor's real proportions. Touches that count as a secondary click are highlighted.
- **Secondary-click zones** from your current settings, including the left/right split, left-handed mode and trackpad corner clicks.
- **What the hardware sends**: the raw HID button reports, before macOS processes them.
- **What macOS delivers**: the click events that actually reach apps.
- **Device details**: model, firmware, connection, battery, colour code, and the settings the driver is applying right now (not just what System Settings shows).

When the hardware reports a click and macOS never delivers it, RodentGym flags it as **DROPPED**, plays a sound and logs it with the memory state at that moment. Clicks that arrive as the wrong button are flagged as **remapped**. Changes to secondary-click settings are logged as they happen.

Everything goes to `~/Library/Logs/RodentGym.log`, so you can line up intermittent problems with whatever else the Mac was doing at the time.

## Requirements

- macOS 14 Sonoma or later (developed on macOS 27)
- Xcode Command Line Tools (`xcode-select --install`)

## Build and run

```sh
git clone https://github.com/gofastercloud/RodentGym.git
cd RodentGym
./build.sh            # builds ./build/RodentGym.app and installs it to ~/Applications
open ~/Applications/RodentGym.app
```

Other options:

```sh
./build.sh --no-install   # build only
./build.sh --screenshot   # rebuild docs/screenshot.png with anonymised demo data
```

The app is ad-hoc signed for local use. No Xcode project is needed: it's a single Objective-C file built with `clang`.

## How it works

| Layer | Source | What it tells you |
|---|---|---|
| Touches | `MultitouchSupport.framework` (private) | Where fingers are, per device |
| Button reports | `IOHIDManager` | What the hardware says was pressed |
| Click events | Listen-only `CGEventTap` on the login session | What macOS delivered to apps |
| Device details | IORegistry (`MultitouchPreferences`, `VersionNumber`, `BatteryPercent`, `ColorID`) | Model, firmware, battery, colour, effective settings |

A button report is matched against the click event that follows it within a configurable window (400 ms by default). Hot-plugging is handled through IOKit notifications.

## Reading the results

| Log symbol | Meaning | What to do |
|---|---|---|
| ✓ | Click delivered normally | Nothing |
| ≠ | Delivered as a different button, or a setting changed | Check finger placement, or what changed the setting |
| ✗ DROPPED | Hardware reported it, macOS never delivered it | Look at the memory figures on the line; quit heavy apps; restart; report to Apple if it continues |

If a Magic Mouse card says **Secondary click: Off**, the mouse is in one-button mode. Use the **Mouse Settings…** button to turn on *Secondary click › Click Right Side*. Resetting the mouse preference files turns this off.

## Privacy

RodentGym only listens. It never blocks, changes or generates input. It watches mouse buttons only, never the keyboard. Nothing leaves your Mac, and the log stays in your Library folder.

Watching mouse click events doesn't normally need a permission prompt. If click events show as unavailable, allow RodentGym under **System Settings › Privacy & Security › Input Monitoring**.

## Limitations

- Touch data comes from Apple's **private** MultitouchSupport framework, which isn't a supported API and could change in any macOS update.
- Accessories report a numeric colour code, but Apple doesn't publish the mapping. Choose the finish for each code once in Settings.
- The trackpad corner area for secondary clicks is drawn approximately.
- Model names are known for the Lightning-era Magic Mouse 2 and Magic Trackpad 2 and the first generation. Other models show their product ID.

## Licence

MIT. See [LICENSE](LICENSE).

RodentGym isn't affiliated with or endorsed by Apple. Magic Mouse and Magic Trackpad are trademarks of Apple Inc.
