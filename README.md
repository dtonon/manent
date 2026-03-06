# Manent

A private, encrypted space for your notes and files — built on [Nostr](https://njump.me).

Think of it as your personal "Saved Messages": write notes, attach images and files, edit them anytime, and access everything across your devices. A simple and clear chronological order, zero fuss. No plaintext data at rest or in transit.

![](assets/screenshot.jpg)

## Features

- **Notes** — Write, edit, and delete text notes
- **Images & files** — Attach and preview images; store any file type
- **End-to-end encrypted** — Everything (notes, files, metadata) is encrypted with NIP-44 before leaving your device
- **Synced via Nostr** — Your data lives on your own relays; files (larger than 32KB) are stored on Blossom servers
- **Multi-platform** — Web, Android, Linux, macOS (iOS and Windows builds untested)

## Login methods

- **Bunker (NIP-46)** — Connect via QR code or `bunker://` URL
- **Android Signer (NIP-55)** — Delegate signing to Amber, your key never leaves the signer app
- **nsec** — Paste your private key directly

## Built with

- [Flutter](https://flutter.dev) — cross-platform UI
- [NDK](https://pub.dev/packages/ndk) — Dart Nostr Development Kit
- NIP-44 encryption, NIP-46 remote signing, NIP-65 outbox relays, Blossom file storage
