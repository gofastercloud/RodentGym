# Changelog

## 0.6.0 — unreleased

- **Keyboard Tester** (Devices › Keyboard Tester, ⌘B): press every key on a Magic Keyboard, an older Apple Wireless Keyboard or the Mac's own keyboard and watch it light up. Flags chatter (a key re-pressing within 30 ms), keys held down for more than four seconds, and the highest rollover. Draws the keyboard at its real shape (compact or with numeric keypad; ANSI, ISO or JIS; Touch ID, lock or eject key) with labels from your current input source, follows the layout of the keyboard you're typing on, and has a caps lock light. Left and right modifiers are told apart. Shortcuts are paused while it's in front so ⌘Q is safe to test. Keys are read only from its own window, with no permission, and never logged. **Copy Report** lists anything that didn't work.
- **Keyboards are never opened.** The click watcher used to open every Apple HID device that matched, which included a Bluetooth Magic Keyboard (its key data was ignored). It now opens pointing devices one at a time and skips anything that is a keyboard or keypad.

## 0.5.0 — 2026-10-25

- **Adjustable Magic Mouse split:** drag the dashed line between the primary and secondary click areas on the mouse, or use the slider in Settings. The new split is applied to the driver straight away and saved to the mouse's preferences, so it survives reconnecting and restarting. Reset to 55% puts back Apple's default. This is the only setting RodentGym changes, and only when you move it.
- **New Help:** a native window with a searchable topic sidebar, rewritten from scratch and rendered from `Resources/Help.md`. The same file builds the help page on the website.
- **Latency Monitor:** memory pressure removed, to keep it focused on the devices.
- **Screenshots:** every window can be rendered with its title bar and toolbar from anonymised demo data, in light and dark (`./build.sh --screenshot`).
- **Website** at [gofastercloud.github.io/RodentGym](https://gofastercloud.github.io/RodentGym/), plus contributing guide, code of conduct, security policy, and issue templates.

## 0.4.0 — 2026-10-25

- **Latency Monitor** (Devices › Latency Monitor, ⌘D): click latency (kernel HID report to delivered click), touch report rate with jitter and stalls, and Bluetooth signal on one two-minute timeline, with memory pressure shaded behind and dropped clicks, connects and disconnects marked across all three. It records from launch. Tiles summarise median and 95th-percentile latency, drops, report rate, signal and memory, and a Liquid Glass readout shows the latest click.
- **Bluetooth signal, opt-in** (Settings › Bluetooth): RSSI for connected Bluetooth devices every 2 seconds, on each device card and in the Latency Monitor. Bluetooth permission is requested only when you turn it on; if it's refused, Settings links to Privacy & Security. Poor signal is logged.
- **Hardware Self-Test** (Devices › Hardware Self-Test, ⌘E): Surface Coverage (dead zones and lost strokes), Phantom Touch (contacts while idle) and Haptics (three patterns through a Force Touch trackpad's haptic engine), with results per device and **Copy Report** for support cases.
- Click log lines now include latency, and device connects and disconnects are logged.

## 0.3.0 — 2026-10-25

- **Live visualisation on the device drawings:** a glowing, tapered trail follows each finger and fades over about half a second (blue, or orange in a secondary-click area). Every click sends out an eased double ripple: blue for left, orange for right. A dropped click gets a red ripple with a ✕ where it happened. Redrawing now runs on a display link at the screen's refresh rate (up to 120 Hz), and only while something is moving. With Reduce Motion on, ripples become simple fades.
- **Battery and charging:** each Magic device's card shows a battery glyph, percentage and status (Charging, Charged, Plugged in, On battery or Low battery) from macOS's accessory power sources. It updates the moment a cable is connected or removed, and logs charging changes and low battery.
- The serial number or Bluetooth address moved from the card's model line to its details line.

## 0.2.0 — 2026-10-25

- **Built-in trackpad, automatically:** on a MacBook, the built-in trackpad appears whenever the lid is open and hides when it's closed, with lid changes logged. It's named after the Mac (for example "MacBook Pro (14-inch, M5)"). Settings › Built-in trackpad offers Automatic, Always show or Never show.
- **Force Sensor** (Gym › Force Sensor, ⌘J): a 10-second scrolling graph of click pressure from a Force Touch trackpad, split into touch, click and Force Click bands. Left clicks draw blue, right clicks orange, and clicks with no force data (a Magic Mouse, say) draw dashed. It also shows a Liquid Glass live readout, peak pressure, click and Force Click counts, average peak per button, and your click-pressure and Force Click settings, with pause and clear in the toolbar.

## 0.1.0 — 2026-10-25

First release.

- **Diagnostics:** live touches, raw HID button reports and delivered click events for every Magic Mouse and Magic Trackpad (and optionally the built-in trackpad), with dropped and remapped click detection, a glass alert and a log at `~/Library/Logs/RodentGym.log`.
- **Device details:** model, firmware, connection, battery, decoded colour (`ColorID`) and the settings each driver is applying, with secondary-click zones drawn for left- and right-handed use and trackpad corners.
- **Gesture Trainer:** a checklist of the gestures you have switched on, ticked off as you do them. App gestures are captured on a practice pad and system gestures are recognised from raw touches.
- **Cheese Stack:** a falling-block click workout that counts every input and any clicks dropped during play.
- **Design:** native AppKit with Liquid Glass on macOS 26 and later (unified toolbar, sidebar, alerts and overlays), light and dark mode, SF Symbols, standard menus and settings form, VoiceOver support, and Reduce Motion support.
- Hardened-runtime signing; listen-only input monitoring; no network access.
