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
- **Voice notes** - Record voice notes with a live level meter and pause/resume; recordings are normalized and trimmed of silence
- **Transcription** - Transcribe voice notes and imported audio on your device with whisper: downloadable models, language choice, and a prompt built from your own tags so hashtags come out right (not available on web)
- **Audio** - Play audio inline with a real waveform, a draggable cursor and a per-note playback speed; mp3, Ogg Vorbis, Ogg Opus and WAV are decoded for waveforms and transcription
- **End-to-end encrypted** — Everything (notes, files, metadata) is encrypted with NIP-44 before leaving your device
- **Tags** - Organize your notes with inline tags
- **Search** - Search and filter your notes by tags and kind (text, images, videos, voice notes, audio, files, sensitive)
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
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) via [whisper_ggml_plus](https://github.com/dtonon/whisper_ggml_plus) — on-device speech to text; models are downloaded from Hugging Face on first use

Building needs a C toolchain (Xcode, NDK, gcc/clang or MSVC): the mp3, Vorbis and Opus decoders used for waveforms and transcription are compiled from source through Dart build hooks.

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

`just build_linux` produces a plain tar.gz of the Flutter release bundle, the same output as the GitHub pipeline (`just gh_build_linux`). Beyond the standard Flutter toolchain it needs the dev headers for libmpv and libepoxy (`media_kit_video`) and FFmpeg (`fc_native_video_thumbnail`):

- **Fedora:** `sudo dnf install mpv-devel libepoxy-devel ffmpeg-free-devel`
- **Debian/Ubuntu:** `sudo apt install libmpv-dev libepoxy-dev libavformat-dev libavcodec-dev libavutil-dev libswscale-dev`

The full list, including the generic Flutter desktop dependencies, is in `.github/workflows/linux-release.yml`.

`just package_linux` additionally wraps the bundle into `.deb` and `.rpm` packages, same as the GitHub pipeline; it needs [fpm](https://fpm.readthedocs.io) (`gem install fpm`; building the `.deb` on Fedora also needs `dnf install dpkg`).

**Runtime dependency:** the app links the system libmpv and FFmpeg libraries, so the target machine needs `mpv-libs` (Fedora) or `libmpv2` (Debian/Ubuntu), which pulls in the FFmpeg libraries with it.
