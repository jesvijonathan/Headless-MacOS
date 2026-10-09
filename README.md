# Headless

**Run a MacBook with no built-in screen, cleanly.** One tiny, event-driven macOS agent for
lid-less / panel-less MacBooks driving an external monitor. It keeps the built-in display
disabled, gives you manual brightness control for the Touch Bar, keyboard and monitor,
controls the fans, and adds headless-friendly toggles. It works from the Control Strip, the menu bar, global
shortcuts and a CLI.

![Main Touch Bar row](docs/touchbar-main.png)
![Desktop stats](docs/touchbar-stats.png)

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
| **Monitor brightness** | Software dimming (gamma) for monitors without DDC, with a 12% floor so your only screen never goes black. Apple's Control Strip brightness button and the brightness keys drive it too. |
| **Desktop stats** | When Finder or the screensaver is frontmost, the Touch Bar shows time · CPU · GPU · memory (GB and %) · temperature · fan RPM · network (or battery when unplugged/charging). Switching to any app gives the Touch Bar back. Tap the clock for the controls. |
| **Display modes** | Resolution and refresh-rate switching, including HiDPI modes. |
| **Fan control** | Auto (macOS), Smart, Custom RPM, or Max. Runs from boot as a small root daemon. Smart eases from minimum at 60 °C to maximum at 90 °C (≈1370 RPM at 65 °C, 2700 at 75 °C, 5370 at 85 °C on an M1 13"): it reacts fast to heat, cools down gently, ignores jitter, and goes to maximum if the sensors fail. |
| **Mouse scroll direction** | Reverses wheel-mouse scrolling while the trackpad keeps natural scrolling, replacing tools like Scroll Reverser. Needs Accessibility permission. |
| **Keep awake** | Prevents system sleep on AC power (like `caffeinate -s`); displays may still sleep. |
| **Night Shift, Sleep display, Lock** | One tap or one shortcut. |
| **From boot** | Runs in the login-window session too, so the display, brightness and awake state are applied before you sign in. |

### Touch Bar

Apple's Control Strip brightness button drives the missing built-in panel and does nothing,
so Headless puts its own button in that slot. Tap it for the controls; the gauge button
there shows the stats (✕ returns to the controls). To bring Apple's button back, untick "Replace Control Strip Brightness Button"
in the menu. Uninstalling also restores it. Each brightness control gets its own
full-width page. Tap the end icons for ±10%.

![Touch Bar brightness page](docs/touchbar-touchbar.png)
![Monitor page](docs/touchbar-monitor.png)
![Display modes page](docs/touchbar-display.png)
![Fans page](docs/touchbar-fans.png)

### Shortcuts (⌃⌥⌘ +)

| key | action | key | action |
|---|---|---|---|
| `=` / `-` | monitor brightness ±10% | `T` | show Touch Bar controls |
| `↑` / `↓` | Touch Bar brightness ±10% | `H` | re-apply display settings |
| `→` / `←` | keyboard backlight ±10% | `L` / `S` | lock / sleep display |
| `A` | keep awake | `N` | Night Shift |
| `F` | fans: Auto → Smart → Max | | |

### CLI

```sh
H=/Applications/Headless.app/Contents/MacOS/Headless
$H status                      # displays, levels, toggles
$H touchbar 70 | keyboard 40 | monitor 60
$H headless on|off | awake on|off | nightshift toggle | mousescroll reverse|natural
$H modes ; $H mode 3           # list / switch display modes
$H fan [auto|smart|max|<rpm>]  # fan mode;  $H fan curve 55 85  # smart curve
$H lock | sleep-display | show [touchbar|keyboard|monitor|display|fans|stats]
```

These work well from Shortcuts.app ("Run Shell Script").

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/<you>/headless && cd headless
make install        # builds, then sudo-installs /Applications/Headless.app + a LaunchAgent
```

### Fresh Mac / clean install

```sh
xcode-select --install          # once: compiler tools
git clone https://github.com/<you>/headless && cd headless
make install                    # agent + fan daemon, from boot, done
```

To carry your levels, toggles and fan mode over, run `make save-config` on the old Mac and
commit `config/`. `make install` restores them, but only on a machine that has no settings
yet, so it never overwrites live ones.

Try it without installing: `make run`. Run the Smart fan-mode tests: `make test`. Remove it with `make uninstall`. Your settings in
`~/Library/Application Support/Headless/settings.plist` are kept.

The LaunchAgent (`/Library/LaunchAgents/dev.jesvi.headless.plist`) loads in both the
**LoginWindow** and **Aqua** sessions. Before login, it only applies state. After login, it
becomes the full app.

Fan control runs in a separate root LaunchDaemon (`dev.jesvi.headless.fand`), because SMC
writes need root. It starts at boot and listens on `/var/run/dev.jesvi.headless.fand.sock`.
Anyone can read status, but only administrators can change modes. When it stops, or after
uninstalling, the fans go back to macOS. In any mode it jumps to max fan speed if macOS
reports a serious thermal state. Don't run it alongside another fan controller such as
Macs Fan Control, because they'll fight. Smart mode reads sensors every 3 s, and fixed modes
re-assert every 15 s. Auto does no work at all.

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
- **Fans:** fan control needs Apple Silicon (built and tested on M1). Smart mode uses the
  90th percentile of the CPU/GPU die sensors.
- **Accessibility permission** (for mouse scroll reversal) is tied to the app's signature.
  Builds are ad-hoc signed, so after a rebuild and reinstall, untick and re-tick Headless in
  System Settings → Privacy & Security → Accessibility.
- **Private APIs:** Headless uses SkyLight, DFRBrightness, CoreBrightness, DFRFoundation and
  undocumented SMC keys.
  A macOS update may break something; please open an issue.

Tested on MacBookPro17,1 (M1, Touch Bar) running macOS 27. Machines without a Touch Bar get
the menu bar, shortcuts and CLI.

## How it works

The agent is [`Sources/Headless.m`](Sources/Headless.m), Objective-C with no dependencies. The
fan daemon is [`Sources/fand`](Sources/fand), Swift, and its SMC access comes from
[Stats](https://github.com/exelban/stats) under the MIT license.

- `SLSConfigureDisplayEnabled` (SkyLight) turns the built-in panel off for the session, like
  [clamless](https://github.com/TCXM/clamless).
- `CGDisplayRegisterReconfigurationCallback` plus IOKit power notifications replace polling.
- `DFRBrightnessClient` and `BrightnessSystemClient` set Touch Bar and keyboard levels.
- Private `NSTouchBar` system-tray APIs add the Control Strip item, re-registered when
  ControlStrip relaunches (seen through KVO on `NSWorkspace.runningApplications`).
- A 15-minute timer with a 2-minute tolerance is the only periodic work, as a safety net.

### Performance

Measured on an M1 MacBook Pro running macOS 27:

| | agent (`Headless`) | fan daemon |
|---|---|---|
| Memory (footprint) | ~19 MB (an empty menu-bar app is ~11 MB) | ~9 MB |
| CPU when idle | 0.00 s per minute: no timers, only events | 0 in Auto; one SMC pass every 3–6 s in Smart |
| CPU with the stats bar showing | ~0.5% (one 2 s tick: a few syscalls, ≤9 SMC reads, a partial redraw) | — |

How it gets there:
- Secondary Touch Bar pages are built on first use.
- The stats row is a single view that redraws only the values that changed.
- Sensors are read from a hot set of the 8 hottest, rescanned every minute, and SMC key info is cached.
- The GPU service handle is kept, and network and battery are only read when shown.
- Binaries are built with LTO and dead-code stripping, and their symbols are stripped.

Logs: `log stream --predicate 'subsystem == "dev.jesvi.headless"'`

## License

[MIT](LICENSE)
