# iss — Instant Space Switcher

This repository now includes a Swift/Xcode setup with three components:

- `ISSApp` (macOS app, SwiftUI)
- `ISSDaemon` (launchd daemon registered via `SMAppService`)
- `issctl` (CLI that talks to daemon over XPC)

The original `iss.c` and `Makefile` are still present as a legacy path.

## Architecture

1. `ISSApp` registers the daemon with `SMAppService.daemon(plistName:)`.
2. The daemon checks and prompts for its own accessibility permission using `AXIsProcessTrustedWithOptions`.
3. The daemon hosts a Mach service (`com.instant-swipe.issd`) via `NSXPCListener`.
4. The CLI (`issctl`) connects with `NSXPCConnection` and sends `left`/`right` switch commands.
5. The app provides UI buttons to install/uninstall the CLI in `~/.local/bin/issctl`.

The daemon performs synthetic Dock swipe posting using CoreGraphics events.

## Generate Xcode Project

This repo uses XcodeGen to keep project config in source control.

```bash
brew install xcodegen
./generate_xcodeproj.sh
```

Then open `iss.xcodeproj` in Xcode.

## Build

```bash
xcodebuild -project iss.xcodeproj -scheme ISSApp -configuration Debug build
```

## Run

1. Launch `ISSApp`.
2. Click `Install Daemon`.
3. Click `Request Daemon Permission` and approve in System Settings if prompted.

The app now shows daemon freshness ("up to date" vs "stale or unreachable") by comparing SHA-256 of the running daemon executable with SHA-256 of the expected daemon binary in the current app bundle.
If freshness is stale after a rebuild or app move, click `Install/Update Daemon` and re-grant Accessibility for the current daemon path.
`Install/Update Daemon` now performs a launchd bootout and kickstart so the newly registered daemon binary is restarted immediately.

The Swift daemon also includes the same "can switch" boundary check as the legacy C version, so it will not post synthetic swipes when already at the leftmost/rightmost desktop.
4. (Optional) Click `Install CLI`.

## CLI Usage

```bash
issctl left
issctl right
```

## Notes

- `SMAppService` installation may require explicit approval under Login Items, depending on system policy.
- The daemon launchd plist is at `Resources/com.instant-swipe.issd.plist`.
- Uses public frameworks (`ApplicationServices`, `ServiceManagement`, XPC) with private event field indices for gesture metadata.
