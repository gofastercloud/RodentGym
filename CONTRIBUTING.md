# Contributing to RodentGym

Thanks for taking a look. RodentGym is a small project and every contribution matters, whether it's a typo fix, a clearer sentence in the help, support for a device model it doesn't know, or a whole new tool.

You don't need to ask before opening a small pull request. For anything bigger, open an issue or a [discussion](https://github.com/gofastercloud/RodentGym/discussions) first so we can agree on the approach before you put the time in.

## Ways to help

- **Report a bug.** [Open an issue](https://github.com/gofastercloud/RodentGym/issues/new/choose). A Hardware Self-Test report (Copy Report in the Self-Test window) or a few lines from `~/Library/Logs/RodentGym.log` makes a big difference.
- **Tell us about your device.** If RodentGym shows the wrong colour, an unknown model, or a product ID instead of a name, the device report template asks for exactly what's needed to add it.
- **Share a reading from faulty hardware.** The stall and lost-stroke detection haven't been checked against genuinely faulty devices yet. If you have a mouse or trackpad with a known fault, a Self-Test report is gold.
- **Improve the help.** Everything in the Help window comes from [`Resources/Help.md`](Resources/Help.md). Its format is explained at the top of the file.
- **Write code.** See below.

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
- **Privacy first.** RodentGym listens; it doesn't change input. No network access, no keyboard monitoring, and no new permission prompts unless the user turns a feature on. If a change needs to write a setting, it should only happen when the user asks for it.
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
