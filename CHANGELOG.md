# Changelog

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
