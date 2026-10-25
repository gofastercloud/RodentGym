# Contributing to RodentGym

Thanks for taking a look. RodentGym is a small project and every contribution matters, whether it's a typo fix, a clearer sentence in the help, support for a device model it doesn't know, or a whole new tool.

You don't need to ask before opening a small pull request. For anything bigger, open an issue or a [discussion](https://github.com/gofastercloud/RodentGym/discussions) first so we can agree on the approach before you put the time in.

## Ways to help

- **Test it on your hardware.** RodentGym has only been tried on a handful of devices. A test report from yours, even when everything works, tells us what we can safely claim. See [Testing](#testing) below.
- **Report a bug.** [Open an issue](https://github.com/gofastercloud/RodentGym/issues/new/choose). See [Reporting a problem](#reporting-a-problem) for what helps.
- **Tell us about your device.** If RodentGym shows the wrong colour, an unknown model, the wrong keyboard layout, or a product ID instead of a name, the device report template asks for exactly what's needed to add it.
- **Share a reading from faulty hardware.** The stall, lost-stroke and chatter detection haven't been checked against genuinely faulty devices yet. If you have a mouse, trackpad or keyboard with a known fault, a report is gold.
- **Improve the help.** Everything in the Help window comes from [`Resources/Help.md`](Resources/Help.md). Its format is explained at the top of the file.
- **Write code.** See below.

## Testing

The most useful thing right now is to hear how RodentGym behaves on hardware we don't have. Pick whatever you own, spend ten minutes, and send a [test report](https://github.com/gofastercloud/RodentGym/issues/new?template=test_report.yml). "Everything worked" is a useful result too.

### Tell us what you tested on

These are what change RodentGym's behaviour, so every report needs them:

| | Where to find it |
|---|---|
| **RodentGym version** | RodentGym › About RodentGym |
| **macOS version** | Apple menu › About This Mac |
| **Mac model and chip** | Apple menu › About This Mac, for example "MacBook Pro (14-inch, M5)" or an Intel iMac |
| **Device model and year** | The model line on the device's card, plus what Apple called it when you bought it, for example "Magic Mouse, USB-C, 2024" |
| **Connection** | Bluetooth, or a cable plugged in. Magic Trackpads and Magic Keyboards switch to USB when the cable is connected, so try both if you can. The card's connection tag shows which one is in use. |
| **Colour** | Silver or white, black or space grey, or one of the iMac colours |
| **Keyboard layout** | ANSI (US-style Return), ISO (tall Return, extra key beside left shift) or JIS, and your input source, for example "British" or "Japanese – Romaji" |
| **Settings that matter** | Secondary click on or off and which side, tap to click, Force Click, and "Use F1, F2, etc. keys as standard function keys" |

### What to try

You don't need to do all of it. Do the parts that match your hardware.

**Any Magic Mouse or trackpad**

- [ ] The card shows the right model, colour, firmware, connection and battery, and the charging status changes when you plug the cable in and out.
- [ ] Left and right clicks light **Sends** on the card and then **macOS delivers**, and the log shows a latency for each, for example `✓ Left click: Magic Mouse · 4.2 ms`. A line ending in "no button report; matched by touch" means button reports aren't reaching RodentGym. Please mention it if you see that.
- [ ] Unplug or switch off the device and turn it back on. The log shows it disconnecting and connecting, and the card comes back.
- [ ] Run the **Hardware Self-Test**: Surface Coverage, Phantom Touch, and Haptics on a Force Touch trackpad. Paste Copy Report into your report.
- [ ] Leave the **Latency Monitor** open for a few minutes of normal use. Does anything look wrong, such as stalls you can't explain or a report rate that seems off?

**Magic Mouse**

- [ ] Drag the split line. Does the new split take effect straight away, or only after the mouse reconnects? Does it survive a restart?
- [ ] With secondary click switched off in System Settings, the card should warn that every click is a left click.

**Magic Keyboard, Apple Wireless Keyboard or a MacBook keyboard**

- [ ] The keyboard tile shows the right model, layout (ANSI, ISO or JIS) and battery.
- [ ] In the **Keyboard Tester**, the drawing matches your keyboard: the shape of Return, the key beside left shift, the arrow keys, and the key at the top right. A screenshot of the tester next to a photo of your keyboard is perfect.
- [ ] Every key lights up. Tell us which ones didn't, especially F1–F12 with and without fn held, fn on its own, caps lock, and the 英数 and かな keys on JIS.
- [ ] Hold down six or more letters at once. What rollover does it show?
- [ ] Paste Copy Report from the tester into your report.

**MacBook built-in trackpad and keyboard**

- [ ] With the lid open both appear. Close the lid with an external display connected and they should disappear, then come back when you open it.

**Anything that seems wrong is worth reporting.** That includes the wording, the layout, and any device or reading that confused you.

## Reporting a problem

A good report lets someone who wasn't there see what you saw. Three things make the biggest difference:

1. **The details from [Tell us what you tested on](#tell-us-what-you-tested-on).** Most device problems only happen on one model, connection or macOS version.
2. **What you did, what you expected, and what happened instead.** Exact steps beat a summary. "Right-clicked about 20 times, two did nothing" is more useful than "right-click is flaky".
3. **Evidence.** A few lines from `~/Library/Logs/RodentGym.log` around the time it happened (Devices › Open Log File), a Copy Report from the Self-Test or Keyboard Tester, or a screenshot.

Before you post, remove anything you'd rather not share. Logs and reports can include your device names (such as "Sam's Magic Mouse") and serial numbers or Bluetooth addresses. Replace them with something like `XX-XX-XX-XX-XX-XX`. RodentGym never logs what you type.

One problem per issue, please. Two problems in one issue tend to get half-fixed.

### An example report

> **Title:** Right clicks from Magic Mouse sometimes arrive as left clicks after waking from sleep
>
> **Versions:** RodentGym 0.6.0, macOS 26.1, MacBook Air (13-inch, M3)
>
> **Device:** Magic Mouse 2 (Lightning), white, over Bluetooth. Secondary click: right side. Split at the default 55%.
>
> **What happened:** After the Mac wakes from sleep, the first few right clicks often do a left click instead. It settles down after a minute or so. RodentGym marks them as remapped.
>
> **Steps:**
> 1. Leave the Mac asleep for at least 10 minutes.
> 2. Wake it and right-click on the desktop five times.
> 3. Two or three of the five open nothing, and the log shows them as remapped.
>
> **Expected:** Five right clicks, five context menus.
>
> **Log lines:**
> ```
> 2026-11-02 08:14:03.112  · Magic Mouse connected
> 2026-11-02 08:14:09.481  ≠ Magic Mouse sent Right, macOS delivered Left
> 2026-11-02 08:14:11.907  ≠ Magic Mouse sent Right, macOS delivered Left
> 2026-11-02 08:14:14.260  ✓ Right click: Magic Mouse · 6.1 ms
> ```
>
> **Also tried:** It doesn't happen with the trackpad. Turning Bluetooth off and on makes no difference. I removed my device name from the log.

### Security problems

Please don't open a public issue. Use [private vulnerability reporting](https://github.com/gofastercloud/RodentGym/security/advisories/new) instead. [SECURITY.md](SECURITY.md) has the details.

## Building

You need macOS 14 or later and Apple's command line tools (`xcode-select --install`). There's no Xcode project.

```sh
./build.sh               # build, sign for local use, install to ~/Applications
./build.sh --no-install  # build only, into ./build
./build.sh --screenshot  # regenerate docs/images from anonymised demo data
```

`build.sh` compiles every file in `Sources/` with `clang -Wall -Wextra`. Please keep the build free of warnings.

## How the code is organised

| File | What's in it |
|---|---|
| `Sources/RodentGym.m` | The app: device discovery, the touch callback, button reports, click events and matching, the main window, menus, settings and the Magic Mouse split |
| `Sources/LatencyMonitor.m` | The Latency Monitor window and its recording |
| `Sources/SelfTest.m` | The Hardware Self-Test |
| `Sources/Keyboard.m` | Keyboard discovery (from the IORegistry only), the keyboard thumbnail and the Keyboard Tester |
| `Sources/KeyboardModels.inc`, `KeyboardLayouts.inc` | Apple keyboard models by product ID, and every layout's key positions. Run the app with `--keyboard-layouts <dir>` to draw them all and check your changes by eye. |
| `Sources/Bluetooth.m` | Opt-in Bluetooth signal monitoring |
| `Sources/GestureTrainer.m`, `ForceSensor.m`, `CheeseStack.m` | The gym |
| `Sources/Help.m` | The Help window, rendered from `Resources/Help.md` |
| `Sources/UI.m` | Shared drawing helpers, Liquid Glass wrappers, the window screenshot renderer |
| `Sources/Multitouch.h` | Types for Apple's private MultitouchSupport framework |
| `docs/` | The website (GitHub Pages) and screenshots |

## Guidelines

- **Native and dependency-free.** AppKit and Apple's frameworks only, in Objective-C with ARC. No package managers, no bundled libraries.
- **Follow the platform.** Semantic system colours so everything works in light mode, dark mode and with Increase Contrast. SF Symbols. Liquid Glass only on controls and overlays that float above content, never on the content itself. Respect Reduce Motion.
- **Accessible.** Custom-drawn views expose their content to VoiceOver. New controls get accessibility labels.
- **Privacy first.** RodentGym listens; it doesn't change input. No network access, and no new permission prompts unless the user turns a feature on. Keyboards are never opened or watched system-wide: the Keyboard Tester only reads keys pressed in its own window, and nothing that's typed is ever logged. If a change needs to write a setting, it should only happen when the user asks for it.
- **Plain, friendly wording.** Interface text and help use Australian English (colour, recognise), sentence case, and short sentences that say what happens.
- **Screenshots stay anonymous.** Demo mode never shows real device names or serial numbers. If you add a window, give it a demo state and add it to the window screenshots.

## Pull requests

1. Fork the repo and create a branch.
2. Make your change, build with `./build.sh`, and try it with real hardware if it touches input.
3. If the interface changed, run `./build.sh --screenshot` and include the updated images.
4. If you changed `Resources/Help.md`, run `python3 scripts/build_help_page.py` so the website's help page matches.
5. Open the pull request with a short description of what changed and how you tested it.

Small, focused pull requests are easier to review and get merged sooner.

## Code of conduct

Be kind and assume good intent. The full [code of conduct](CODE_OF_CONDUCT.md) applies to every space the project has.
