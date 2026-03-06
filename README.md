# Nope-Sleep Mac (N.S.M.)

Nope-Sleep Mac is a production-oriented macOS menu bar utility for sleep control, scheduling, startup automation, and operational diagnostics.

## 20 Production Features

1. Menu bar app with short status title (`N.S.M.`)
2. Drag-install `.dmg` packaging for `/Applications`
3. Launch at boot toggle from app menu
4. `SMAppService` startup registration on macOS 13+
5. LaunchAgent fallback for startup reliability
6. Service enable/disable toggle for background worker
7. Sleep prevention toggle (system + display assertions)
8. Sleep timer presets (`30m`, `1h`, `2h`, `4h`)
9. Shutdown timer presets (`15m`, `30m`, `1h`, `2h`)
10. Schedule shutdown at exact date/time
11. Schedule wake/power-on at exact date/time
12. Schedule protection enable and disable at exact date/time
13. One-click cancellation for all scheduled actions
14. Auto-restore protection after wake option
15. Service watchdog with restart throttling
16. Mini resource monitor (CPU, memory, disk, battery, Wi-Fi, Bluetooth, uptime)
17. Power profiles: Diamond, Power+, Battery+, Off-Grid, Restore Connectivity
18. Event history log with bounded in-memory buffering
19. Service log rotation to cap disk usage
20. One-click desktop experience window + self-test, status copy, and diagnostics export tooling

## Build

```bash
./build.sh
```

Build output:
`./build/Nope-Sleep Mac.app`

## Create Drag-Install DMG

```bash
./package-dmg.sh
```

DMG output:
`./dist/Nope-Sleep Mac-1.0.0.dmg`

## Install Like Standard macOS Software

1. Open `./dist/Nope-Sleep Mac-1.0.0.dmg`
2. Drag `Nope-Sleep Mac.app` into `Applications`
3. Launch from `Applications`
4. Enable `Launch at Boot` from the menu if desired

## Optional CLI Install

```bash
./install.sh
```

If `/Applications` needs admin rights:

```bash
sudo ./install.sh
```

## Production Release (Signed + Optional Notarization)

Build and sign:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./release.sh
```

Build, sign, and notarize:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-profile" \
./release.sh
```

Optional environment variables:
- `VERSION` (default `1.0.0`)
- `BUILD_NUMBER` (default `1`)
- `SIGN_DMG` (`1` or `0`)

## Logs

- Event log: `~/Library/Application Support/NopeSleepMac/events.log`
- Service log: `~/Library/Application Support/NopeSleepMac/service.log`

## Verify Sleep Assertions

```bash
pmset -g assertions | grep -i "N.S.M."
```

## Important macOS Limits

- Idle sleep and display sleep can be blocked while assertions are active.
- Manual sleep, lid-close behavior, and some system-driven shutdown paths remain under macOS control.
- Wake/power-on scheduling uses `pmset` and may require admin authentication.
