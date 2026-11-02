# CoffeeCup

A menu bar keep-awake utility for macOS 13+ (built and tested on macOS 27.2), modelled on
[KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) but designed to never silently stop.

## Install

1. Download **CoffeeCup.zip** from the [latest release](../../releases/latest) and unzip it.
2. Drag **CoffeeCup.app** into your **Applications** folder.
3. The app isn't notarised by Apple, so the first launch is blocked. Either:
   - Open it once, then go to **System Settings → Privacy & Security**, scroll down and click
     **Open Anyway**; or
   - Run this in Terminal, then open it normally:
     ```bash
     xattr -dr com.apple.quarantine /Applications/CoffeeCup.app
     ```
4. A cup icon appears in the menu bar. Right-click it and tick **Start at Login**.

Works on Apple Silicon and Intel Macs running macOS 13 or later.

## Why KeepingYouAwake drifts

KeepingYouAwake spawns `/usr/bin/caffeinate` and trusts that child process to hold the
sleep assertion. If the child exits or powerd drops the assertion, the icon still says
"active" while nothing is preventing sleep.

## What CoffeeCup does differently

| Mechanism | Purpose |
|---|---|
| In-process `IOPMAssertionCreateWithName` (display + system idle sleep) | No child process to lose |
| Watchdog every 20s via `IOPMCopyAssertionsByProcess` | Confirms with powerd that our assertions still exist; rebuilds them if not |
| `IOPMAssertionDeclareUserActivity` each watchdog tick | Resets the idle timer like real input; stops screensaver/lock idle timers |
| `ProcessInfo.beginActivity(.userInitiated, …)` | Opts out of App Nap so the watchdog isn't throttled, plus backup assertions |
| Re-assert on wake, screen wake, session switch, display change | Covers the transitions where assertions are most often lost |

## Use

- **Left-click** the cup icon: toggle on/off.
- **Right-click** (or Control-click): menu with timed activation, Allow Display Sleep,
  Activate on Launch, Start at Login, Show Log, Quit.
- The menu shows the last time the assertions were verified with powerd and how many repairs
  the watchdog has made.

**External displays:** the assertions are system-wide, so they cover built-in, external,
mirrored and extended displays alike, and CoffeeCup re-asserts whenever displays are connected
or rearranged. (Closed-lid use still follows Apple's clamshell rules: power adapter plus
external display.)

Log: `~/Library/Logs/CoffeeCup/CoffeeCup.log`

Check what's holding the Mac awake at any time:

```bash
pmset -g assertions | grep CoffeeCup
```

## Build

Requires only the Command Line Tools (`xcode-select --install`).

```bash
./build.sh            # -> build/CoffeeCup.app (universal arm64 + x86_64)
./build.sh install    # also copies to /Applications and launches
./build.sh dist       # also creates build/CoffeeCup.zip for a release
```

"Start at Login" needs the app to live in /Applications.
