<!--
RodentGym Help. The app renders this file in its Help window, one topic per "# " heading.

Format, kept deliberately small:
  # Title | sf.symbol.name | One-line summary
  ## Subheading
  Paragraphs separated by blank lines
  - Bullet
  > Tip, shown as a callout
  | Term | Description            (two-column rows, e.g. shortcuts)
Inline: **bold**, `key or code`, [link text](url)
-->

# Welcome | computermouse | What RodentGym does and where to start

RodentGym shows what your Magic Mouse and Magic Trackpad report to the Mac, and what macOS actually delivers to apps. When the two don't match, it tells you.

It's built for the frustrating problems: right-click that does nothing, clicks that go missing now and then, a gesture that seems to have stopped working, a trackpad that feels off.

## Where to start

- **Something isn't clicking?** Watch the main window while you click. Each card shows the touches and button reports from one device, and the bar below shows what macOS delivered.
- **Intermittent trouble?** Leave RodentGym running. Dropped clicks are flagged and logged, and the **Latency Monitor** keeps the last two minutes on one timeline.
- **Suspect the hardware?** Run the **Hardware Self-Test** for dead zones, phantom touches and the haptic engine.

> RodentGym only listens. It never blocks, changes or creates input. The one exception is the Magic Mouse split, and only when you move it yourself.

# The main window | rectangle.3.group | Device cards, the delivery bar and the log

## Device cards

Each connected Magic Mouse and Magic Trackpad gets a card, and so does a MacBook's built-in trackpad while the lid is open. The drawing uses the sensor's real proportions and the device's own colour, and shows your fingers live.

- **Blue dots** are ordinary touches. **Orange dots** are touches that count as a secondary (right) click with your current settings.
- **The orange area** is where a secondary click happens. On a Magic Mouse it follows the split, and swaps sides for left-handed use. On a trackpad it shows the corner you chose, or notes that secondary click uses two fingers.
- **Trails and ripples.** Each finger leaves a short trail, and every click ripples out from where it happened: blue for left, orange for right, red with a ✕ when the click was dropped.
- **Battery.** Level, and whether the device is charging, charged, plugged in or on battery.
- **Sends.** The raw button reports from the device, before macOS processes them.

Under the drawing are the model, firmware, connection, colour, and the settings the driver is applying right now. They come from the driver rather than System Settings, so they show what's really in effect.

## macOS delivers

The bar under the cards shows the click events macOS hands to apps. A healthy click lights **Sends** on the card, then **macOS delivers** a moment later.

## The log

| ✓ | The click went through normally. Successful clicks include their latency.
| ≠ | Something didn't match or changed: the mouse sent Right and macOS delivered Left, or a setting changed.
| ✗ DROPPED | The device reported a click and macOS never delivered it.
| · | Information: startup, devices connecting and disconnecting, a click with no button report.

Everything is also written to `~/Library/Logs/RodentGym.log`. Choose **Devices › Open Log File** to read it.

# Fixing common problems | stethoscope | What the usual findings mean

## Right-click does nothing, and the card says "Secondary click: Off"

The mouse is in one-button mode, which is Apple's default. Turn on **Secondary click › Click Right Side** in [Mouse settings](x-apple.systempreferences:com.apple.Mouse-Settings.extension). Resetting or deleting mouse preferences switches it off again.

## Right-clicks arrive as left-clicks (≠ in the log)

Your finger is landing on the primary side of the split, or another finger is resting on the mouse. Watch the dots while you click. If the split is in the wrong place for the way you hold the mouse, drag it (see **Settings**).

## Clicks are DROPPED

The mouse sent the click, so the hardware did its job. Something in macOS discarded it. Open the **Latency Monitor** and look at what was happening around the drop. Quit heavy apps, restart if it keeps happening, and if drops continue on an idle Mac, report it to Apple with Feedback Assistant and include the log lines.

## Lag, stutter or dropouts

Check the **Latency Monitor**. Steady latency with stalls in the touch report rate, or weak Bluetooth signal, points to the wireless link: move closer, and away from USB 3 hubs and 2.4 GHz equipment. Latency that jumps only when the Mac is busy points to the Mac.

## Trackpad clicks show "no button report"

Some trackpads don't send a separate button report for every click. RodentGym matches the click to the trackpad you're touching instead. These clicks have no latency figure.

# Latency Monitor | waveform.path.ecg | Click latency, report rate and signal on one timeline

Three graphs share a two-minute timeline, so you can see whether problems line up. Open it from **Devices › Latency Monitor** or press `⌘D`. It records from the moment RodentGym starts, so recent history is already there when you open it.

- **Click latency.** For each click, the time from the Mac receiving the button report to the click reaching apps. A few milliseconds is normal. Dropped clicks show as a red ✕ with a line through every graph.
- **Touch report rate.** How many touch frames per second each device sends while you touch it, with jitter. A steady line is healthy. Red ▲ marks are stalls, frames that arrived far later than usual.
- **Bluetooth signal.** Signal strength for each Bluetooth device, if you turn it on in Settings. Above −60 dBm is excellent. Below −80 dBm is poor and can cause lag and dropouts.

Dotted lines mark devices connecting and disconnecting. The tiles underneath summarise the median and 95th-percentile latency, dropped clicks, report rate and signal.

> Latency is measured from when the Mac receives the button report, so time spent travelling over Bluetooth isn't included.

# Hardware Self-Test | checkmark.seal | Dead zones, phantom touches and haptics

Three short checks for faults in the device itself. Open it from **Devices › Hardware Self-Test** or press `⌘E`. Choose the device in the toolbar, then pick a test.

## Surface Coverage

Wipe one finger slowly over the whole surface, row by row, until it's green. Areas still red at the end didn't respond. If a patch never lights up however you wipe it, that part of the sensor isn't working.

**Lost** counts strokes the sensor dropped partway across the surface. A few during fast wipes near the edges are normal. Many in the middle are not.

## Phantom Touch

Take your hands away for 10 seconds. A healthy device reports nothing. Contacts that appear on their own usually mean moisture, dirt, a nearby charger or metal object, or a failing sensor. Clean and dry the surface and try again before drawing conclusions.

## Haptics

On a Force Touch trackpad the click you feel is made by a haptic engine. Rest one finger on the trackpad and play three taps through it. The Magic Mouse and the first Magic Trackpad click mechanically, so this test doesn't apply to them.

## Reports

**Copy Report** puts every result on the clipboard as plain text, with each device's model, firmware and serial number and the Latency Monitor's summary, ready to paste into an Apple support case.

# Gesture Trainer | hand.draw | Practise the gestures you have switched on

A checklist of every gesture you have switched on for each device. Open it from **Gym › Gesture Trainer** or press `⌘T`. Do a gesture with the pointer over the practice pad and it's ticked off. The banner names what was recognised, with details such as how far you pinched or how quickly you double-clicked.

- **App gestures** are captured on the pad: clicks, tap to click, Force Click, scroll, pinch, rotate, smart zoom, swipe between pages and three-finger drag.
- **System gestures** are recognised from the raw touches: Mission Control, App Exposé, full-screen swipes, squeeze, spread, Notification Centre and three-finger tap. macOS still acts on them, because RodentGym never blocks input, so come back to the trainer to see the result.
- **Gestures you've switched off** show as off. The toolbar buttons open Trackpad and Mouse settings.

# Force Sensor | gauge.with.dots.needle.67percent | How hard you press, graphed live

A scrolling graph of click pressure from a Force Touch trackpad. Open it from **Gym › Force Sensor** or press `⌘J`, then press on the trackpad with the pointer over the graph.

- The graph has three bands: **Touch** (before the click), **Click** and **Force Click**. Left clicks draw blue and right clicks orange.
- A **dashed** line means the click arrived with no force data. That's normal for a Magic Mouse, which has no force sensor.
- If presses never reach the Force Click band, check that Force Click is on in [Trackpad settings](x-apple.systempreferences:com.apple.Trackpad-Settings.extension).

# Cheese Stack | gamecontroller | A falling-block click workout

Intermittent problems are hard to reproduce on demand, so RodentGym includes a game that uses every input, quickly and often. Open it from **Gym › Cheese Stack** or press `⌘G`.

- **Steer** with the pointer. **Left-click** rotates anticlockwise and **right-click** rotates clockwise.
- **Scroll** to drop the piece, and **flick** quickly (or middle-click) to slam it down.
- Keys work too: arrows to move, `Z` and `X` to rotate, `Space` to slam, `P` to pause.

The **Left** and **Right** tiles light up as each click arrives. If you click and a tile stays dark, that click didn't reach the game. **Dropped clicks** counts the clicks RodentGym caught going missing while you played.

# Settings | gearshape | Window, devices, Bluetooth and the mouse split

Open Settings from **RodentGym › Settings…** or press `⌘,`.

## Magic Mouse split

Where the right-click area starts, measured across the mouse from the left (from the right when left-handed). Apple's default is 55%, and System Settings has no control for it. Drag the dashed line on the mouse in the main window, or use the slider. The change applies straight away and is saved, so it survives reconnecting and restarting. **Reset to 55%** puts it back.

## Bluetooth signal

Off until you turn it on. The first time, macOS asks whether RodentGym may use Bluetooth. RodentGym only reads the signal strength of devices that are already connected; it never scans, pairs or connects. If you said no, Settings shows a button to [Privacy & Security › Bluetooth](x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth).

## Everything else

- **Keep RodentGym above other windows** keeps it visible while you click in other apps.
- **Built-in trackpad.** Automatic shows a MacBook's own trackpad whenever the lid is open. Always show keeps the card, marked when the lid is closed.
- **Dropped clicks.** Play a sound, and choose whether to log every click or only problems.
- **Detection window.** How long RodentGym waits for a reported click to arrive before calling it dropped. The default is 400 ms. Raise it if you see false drops while the Mac is very busy.
- **Device colours.** Each accessory reports a colour code, which RodentGym decodes. If a device is drawn in the wrong finish, override it here.

# Keyboard shortcuts | command | Everything on the keyboard

| `⌘D` | Latency Monitor
| `⌘E` | Hardware Self-Test
| `⌘T` | Gesture Trainer
| `⌘J` | Force Sensor
| `⌘G` | Cheese Stack
| `⌘K` | Reset counters
| `⌘L` | Open the log file
| `⇧⌘M` | Mouse settings
| `⇧⌘T` | Trackpad settings
| `⇧⌘R` | Rescan devices
| `⌘,` | Settings
| `⌘?` | This help

# Privacy and permissions | lock.shield | What RodentGym can see, and what it asks for

RodentGym only listens. It watches mouse buttons and touches, never the keyboard. It needs no Accessibility permission, makes no network connections, and nothing leaves your Mac. The log is readable only by you.

- **Input Monitoring.** Watching click events doesn't normally need permission. If the **macOS delivers** lights say "Unavailable", allow RodentGym under [Privacy & Security › Input Monitoring](x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent) and reopen it.
- **Bluetooth.** Requested only if you turn on signal monitoring in Settings.
- **The mouse split** is the only setting RodentGym changes, and only when you move it.

# Limitations | info.circle | Worth knowing before you rely on the results

- Touch data comes from Apple's private MultitouchSupport framework. A future macOS update could change or break it.
- Click latency starts when the Mac receives the button report, so Bluetooth air time isn't included.
- Stall and lost-stroke detection are heuristics, and haven't yet been checked against known-faulty hardware.
- Colour codes aren't documented by Apple. RodentGym's table matches real devices, but a rare model could be decoded wrongly. Settings can override it.
- The trackpad's corner click area is drawn approximately, because Apple doesn't publish its size.
- If a device doesn't appear, choose **Devices › Rescan Devices**.

# Support RodentGym | heart | Free, open source, and happy to have help

RodentGym is free and open source under the MIT licence, built and looked after in spare time.

- **Found a bug or have an idea?** Open an issue or start a discussion on [GitHub](https://github.com/gofastercloud/RodentGym). A Self-Test report or a few lines from the log helps a lot.
- **Want to help build it?** Pull requests are welcome, from typo fixes to new device support. The README explains how to build it.
- **Saved you an afternoon?** If you'd like to, you can [sponsor the project on GitHub](https://github.com/sponsors/gofastercloud). It's never expected, and always appreciated.
