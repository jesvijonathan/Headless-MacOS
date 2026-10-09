# Headless

**Run a MacBook with no built-in screen, cleanly.** One tiny, event-driven macOS agent for
lid-less / panel-less MacBooks driving an external monitor. It keeps the built-in display
disabled, gives you manual brightness control for the Touch Bar, keyboard and monitor, and
adds headless-friendly toggles. It works from the Control Strip, the menu bar, global
shortcuts and a CLI.

![Main Touch Bar row](docs/touchbar-main.png)

## Why

A MacBook whose panel is removed or broken still thinks it has a screen, and macOS keeps
re-enabling it after wake or replug. Without the panel's ambient light sensor, the Touch Bar
also sits at minimum brightness and the keyboard backlight never adjusts. The usual fixes
are a pile of launch agents polling every few seconds. Headless replaces them with one
process that **never polls**. It reacts to display reconfiguration, wake, unlock,
ControlStrip restarts and Touch Bar power events, and idles at 0% CPU.

## Features

| | |
|---|---|
| **Built-in display off** | Disabled within ~0.5 s whenever it comes back while an external display is active. Backs off if something keeps re-enabling it. |
| **Touch Bar brightness** | Manual level, held across wake and ControlStrip restarts (no ambient sensor needed). |
| **Keyboard backlight** | Manual level, restored on launch/wake only, so macOS idle dimming still works. |
| **Monitor brightness** | Software dimming (gamma) for monitors without DDC, with a 12% floor so your only screen never goes black. |
| **Display modes** | Resolution and refresh-rate switching, including HiDPI modes. |
| **Keep awake** | Prevents system sleep on AC power (like `caffeinate -s`); displays may still sleep. |
| **Night Shift, Sleep display, Lock** | One tap or one shortcut. |
| **From boot** | Runs in the login-window session too, so the display, brightness and awake state are applied before you sign in. |

### Touch Bar

A sliders button in the Control Strip opens the panel. Each brightness control gets its own
full-width page. Tap the end icons for ±10%.

![Touch Bar brightness page](docs/touchbar-touchbar.png)
![Monitor page](docs/touchbar-monitor.png)
![Display modes page](docs/touchbar-display.png)

### Shortcuts (⌃⌥⌘ +)

| key | action | key | action |
|---|---|---|---|
| `=` / `-` | monitor brightness ±10% | `T` | show Touch Bar controls |
| `↑` / `↓` | Touch Bar brightness ±10% | `H` | re-apply display settings |
| `→` / `←` | keyboard backlight ±10% | `L` / `S` | lock / sleep display |
| `A` | keep awake | `N` | Night Shift |

### CLI

```sh
H=/Applications/Headless.app/Contents/MacOS/Headless
$H status                      # displays, levels, toggles
$H touchbar 70 | keyboard 40 | monitor 60
$H headless on|off | awake on|off | nightshift toggle
$H modes ; $H mode 3           # list / switch display modes
$H lock | sleep-display | show [touchbar|keyboard|monitor|display]
```

These work well from Shortcuts.app ("Run Shell Script").

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/<you>/headless && cd headless
make install        # builds, then sudo-installs /Applications/Headless.app + a LaunchAgent
```

Try it without installing: `make run`. Remove it with `make uninstall`. Your settings in
`~/Library/Application Support/Headless/settings.plist` are kept.

The LaunchAgent (`/Library/LaunchAgents/dev.jesvi.headless.plist`) loads in both the
**LoginWindow** and **Aqua** sessions. Before login, it only applies state. After login, it
becomes the full app.

## Limitations

- **Lock screen and login window UI:** there, macOS hands the Touch Bar to `loginwindow`,
  which shows only Apple's fixed keys, and global hotkeys are blocked by secure input.
  Headless keeps enforcing your settings underneath, but its buttons can't appear on those
  screens.
- **Before macOS starts:** the Apple-logo boot screen, FileVault pre-boot unlock and Recovery
  all run before macOS does, so nothing can run there.
- **Monitor brightness** is software dimming, which reduces contrast at low levels. If your
  monitor supports DDC, a DDC tool such as MonitorControl gives true backlight control.
  Don't dim with both tools at once, or they'll fight over the gamma table.
- **Private APIs:** Headless uses SkyLight, DFRBrightness, CoreBrightness and DFRFoundation.
  A macOS update may break something; please open an issue.

Tested on MacBookPro17,1 (M1, Touch Bar) running macOS 27. Machines without a Touch Bar get
the menu bar, shortcuts and CLI.

## How it works

Everything is in [`Sources/Headless.m`](Sources/Headless.m), about 1,200 lines of Objective-C
with no dependencies.

- `SLSConfigureDisplayEnabled` (SkyLight) turns the built-in panel off for the session, like
  [clamless](https://github.com/TCXM/clamless).
- `CGDisplayRegisterReconfigurationCallback` plus IOKit power notifications replace polling.
- `DFRBrightnessClient` and `BrightnessSystemClient` set Touch Bar and keyboard levels.
- Private `NSTouchBar` system-tray APIs add the Control Strip item, re-registered when
  ControlStrip relaunches (seen through KVO on `NSWorkspace.runningApplications`).
- A 15-minute timer with a 2-minute tolerance is the only periodic work, as a safety net.

Logs: `log stream --predicate 'subsystem == "dev.jesvi.headless"'`

## License

[MIT](LICENSE)
