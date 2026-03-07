# Nope-Sleep Mac (N.S.M.)

Nope-Sleep Mac is a production-oriented macOS menu bar utility for sleep control, scheduling, startup automation, and operational diagnostics.

Supported OS: macOS 13 or newer.

## 20 Production Features

1. Menu bar app with short status title (`N.S.M.`)
2. Universal builds for Apple Silicon and Intel Macs
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
20. GitHub release installer for installing on another Mac from Terminal

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

## Create Terminal Install Archive

```bash
./package-terminal.sh
```

Archive output:
`./dist/Nope-Sleep Mac-1.0.0-terminal.tar.gz`

Install on another Mac from Terminal:

```bash
tar -xzf "Nope-Sleep Mac-1.0.0-terminal.tar.gz"
cd "Nope-Sleep Mac-1.0.0-terminal"
./terminal-install.sh
```

If you want a system-wide install into `/Applications`:

```bash
sudo ./terminal-install.sh
```

## Install From GitHub On Any Mac

Once the repo is on GitHub and the release asset is uploaded, install directly from Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install-from-github.sh | zsh -s -- OWNER/REPO
```

Install a specific release tag:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install-from-github.sh | zsh -s -- OWNER/REPO v1.0.0
```

If you want the app installed system-wide into `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install-from-github.sh | sudo zsh -s -- OWNER/REPO
```

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

`./install.sh` is for source installs from this repo. `./terminal-install.sh` is for prebuilt installs from the packaged archive.

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

Build, sign, and upload to GitHub Releases with `gh`:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
GITHUB_REPO="OWNER/REPO" \
UPLOAD_TO_GITHUB=1 \
./release.sh
```

Optional environment variables:
- `VERSION` (default `1.0.0`)
- `BUILD_NUMBER` (default `1`)
- `SIGN_DMG` (`1` or `0`)
- `GITHUB_REPO` (`owner/repo`)
- `GITHUB_TAG` (default `vVERSION`)
- `UPLOAD_TO_GITHUB` (`1` or `0`)

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
