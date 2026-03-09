# Nope-Sleep Mac

Provided BY: [WayneTechLab.com](https://WayneTechLab.com)

Nope-Sleep Mac is a macOS menu bar utility that keeps a Mac awake, manages sleep and shutdown schedules, exposes power profiles, and gives you a desktop control surface when you want a full app experience.

Supported OS: macOS 13 or newer

GitHub repo: [WayneTechLab/Nope-Sleep-Mac](https://github.com/WayneTechLab/Nope-Sleep-Mac)

Wiki: [Nope-Sleep Mac Wiki](https://github.com/WayneTechLab/Nope-Sleep-Mac/wiki)

## Quick Install

### Option 1: Install from GitHub in Terminal

Latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/WayneTechLab/Nope-Sleep-Mac/main/install-from-github.sh | zsh -s -- WayneTechLab/Nope-Sleep-Mac
```

Install a specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/WayneTechLab/Nope-Sleep-Mac/main/install-from-github.sh | zsh -s -- WayneTechLab/Nope-Sleep-Mac v1.1.0
```

Install system-wide into `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/WayneTechLab/Nope-Sleep-Mac/main/install-from-github.sh | sudo zsh -s -- WayneTechLab/Nope-Sleep-Mac
```

### Option 2: Standard Drag-and-Drop Install

1. Download `Nope-Sleep Mac-1.1.0.dmg` from the latest GitHub release.
2. Open the DMG.
3. Drag `Nope-Sleep Mac.app` into `Applications`.
4. Launch the app from `Applications`.
5. Enable `Launch at Boot` from the menu if you want it to start automatically.

Release page: [Latest Releases](https://github.com/WayneTechLab/Nope-Sleep-Mac/releases/latest)

## Clean Install From Source

Build the app:

```bash
./build.sh
```

Output:
`./build/Nope-Sleep Mac.app`

Install locally:

```bash
./install.sh
```

Install into `/Applications` with admin rights:

```bash
sudo ./install.sh
```

## Package for Distribution

Create a drag-install DMG:

```bash
./package-dmg.sh
```

Output:
`./dist/Nope-Sleep Mac-1.1.0.dmg`

Create a terminal-install archive:

```bash
./package-terminal.sh
```

Output:
`./dist/Nope-Sleep Mac-1.1.0-terminal.tar.gz`

Install that archive on another Mac:

```bash
tar -xzf "Nope-Sleep Mac-1.1.0-terminal.tar.gz"
cd "Nope-Sleep Mac-1.1.0-terminal"
./terminal-install.sh
```

System-wide install from the unpacked archive:

```bash
sudo ./terminal-install.sh
```

## Updates

Nope-Sleep Mac checks GitHub Releases automatically on launch and on a timer while it is running.

When an update is available:

1. The menu item changes to `Install Update vX.Y.Z`.
2. The desktop experience shows the new version in the `Update` card.
3. Clicking the update action opens the latest release installer.

Version is shown in:

1. The first line of the menu dropdown.
2. The menu bar icon hover tooltip.
3. The desktop experience `Version` card.
4. Copied diagnostics and status output.

## Desktop Experience

The menu bar stays icon-only for a compact toolbar footprint.

Open the full desktop surface from the menu:

1. Click the moon icon in the menu bar.
2. Select `Open N.S.M. Desktop Experience`.
3. Close the window to return to menu-bar-only mode.

The desktop UI includes:

1. Aero-glass styled control surface
2. Live resource monitor
3. Update/install action
4. Event history view
5. Version and provider branding

## Feature Set

1. Menu bar app with icon-only toolbar presence
2. Full desktop mode with glass UI
3. Universal Apple Silicon and Intel builds
4. Launch at boot toggle
5. LaunchAgent fallback
6. Background service toggle
7. Sleep prevention toggle
8. Sleep timer presets
9. Shutdown timer presets
10. Scheduled shutdown at exact date/time
11. Scheduled wake/power-on at exact date/time
12. Scheduled protection enable and disable at exact date/time
13. Auto-restore protection after wake
14. Service watchdog with restart throttling
15. Mini resource monitor
16. Power profiles: Diamond, Power+, Battery+, Off-Grid, Restore Connectivity
17. Event history logging
18. Service log rotation
19. GitHub-backed installer and update path
20. Provider and version branding in app UX

## Release Workflow

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

Build, sign, and upload the DMG plus terminal archive to GitHub Releases:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
GITHUB_REPO="WayneTechLab/Nope-Sleep-Mac" \
UPLOAD_TO_GITHUB=1 \
./release.sh
```

Optional environment variables:

1. `VERSION` default `1.1.0`
2. `BUILD_NUMBER` default `1`
3. `SIGN_DMG` set `1` or `0`
4. `GITHUB_REPO` set `owner/repo`
5. `GITHUB_TAG` default `vVERSION`
6. `UPLOAD_TO_GITHUB` set `1` or `0`

## Logs and Diagnostics

Event log:
`~/Library/Application Support/NopeSleepMac/events.log`

Service log:
`~/Library/Application Support/NopeSleepMac/service.log`

Verify sleep assertions:

```bash
pmset -g assertions | grep -i "N.S.M."
```

## macOS Limits

1. Idle sleep and display sleep can be blocked while assertions are active.
2. Manual sleep and lid-close behavior still remain under macOS control.
3. Wake and power scheduling uses `pmset` and may require admin authentication.
