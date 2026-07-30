# Manent

A private, encrypted space for your notes and files — built on [Nostr](https://njump.me).

Think of it as your personal "Saved Messages": write notes, attach images and files, edit them anytime, and access everything across your devices. A simple and clear chronological order, zero fuss. No plaintext data at rest or in transit.

![](assets/screenshot.jpg)

## Features

- **Notes** — Write, edit, and delete text notes
- **Attachments** — Store any file type
- **Images** - Crop, roate and compress images
- **Video** - Play video files and gifs
- **Camera** - Capture photo and video from the app
- **End-to-end encrypted** — Everything (notes, files, metadata) is encrypted with NIP-44 before leaving your device
- **Tags** - Organize your notes with inline tags
- **Search** - Search and filter your notes by tags
- **Sync via Nostr** — Your data lives on your own relays; files (larger than 32KB) are stored on Blossom servers
- **Multi-platform** — Web, Android, Linux, macOS (iOS and Windows builds untested)

## Login methods

- **Bunker (NIP-46)** — Connect via QR code or `bunker://` URL
- **Android Signer (NIP-55)** — Delegate signing to Amber, your key never leaves the signer app
- **nsec** — Paste your private key directly

## Built with

- [Flutter](https://flutter.dev) — cross-platform UI
- [NDK](https://pub.dev/packages/ndk) — Dart Nostr Development Kit
- NIP-44 encryption, NIP-46 remote signing, NIP-65 outbox relays, Blossom file storage

## Known issues

### macOS build fails on Xcode 26

Xcode 26's clang errors when the deployment target is inferred from multiple sources simultaneously. Fix: patch Flutter's `DebugMacOSFramework` to pass an explicit `-mmacosx-version-min` flag.

In `$(flutter sdk-path)/packages/flutter_tools/lib/src/build_system/targets/macos.dart`, inside `DebugMacOSFramework.build()`, add before the `clang(...)` call:

```dart
final String deploymentTarget =
    environment.defines['MACOSX_DEPLOYMENT_TARGET'] ?? '10.15';
```

Then add `'-mmacosx-version-min=$deploymentTarget'` to the clang args list, and delete `$(flutter sdk-path)/bin/cache/flutter_tools.snapshot` to force a rebuild of the Flutter tools.

This patch is overwritten by `flutter upgrade` and must be reapplied until Flutter adds native Xcode 26 support.

### Linux build

Building the Linux AppImage (`just build_linux`) needs libmpv's headers and `appimagetool`:

- **Fedora:** `sudo dnf install mpv-devel`
- **Debian/Ubuntu:** `sudo apt install libmpv-dev`
- **appimagetool:** download the [AppImage](https://github.com/AppImage/appimagetool/releases) and put it on your `PATH`.

The `media_kit` video player links against libmpv. `flutter_distributor`'s AppImage maker bundles libmpv together with its entire ffmpeg stack, but on distros where ffmpeg is split across packages (e.g. Fedora's `ffmpeg-free` + RPM Fusion `libavcodec-freeworld`) it captures a mismatched mix of `libav*` libraries. That inconsistent set aborts inside libmpv on playback (`m_config_cache_from_shadow: Assertion 'group_index >= 0' failed`). `build_linux` therefore runs `scripts/strip_bundled_mpv.sh`, which removes the bundled media stack so the AppImage uses the system libmpv instead.

**Runtime dependency:** because of the above, the AppImage requires libmpv to be installed on the target machine — `mpv-libs` (Fedora) or `libmpv2` (Debian/Ubuntu).
