# Changelog

Notable changes to Manent. The format follows [Keep a Changelog](https://keepachangelog.com); entries under Unreleased become the next release's notes.

## [Unreleased]

- Add a GitHub Linux release pipeline producing tar.gz, deb and rpm packages
- Replace the Linux AppImage with a plain tar.gz bundle
- Standardize the release pipeline (just release / publish / ship, with undo and changelog helpers)
- Name all release artifacts manent-<version>-<platform>-<arch>
- Attach the web bundle to releases

## [2.0.1] - 2026-08-03

- Bundle Mozilla CA roots to fix TLS on pristine Windows installs
- Add a Windows release pipeline and in-app sync/network diagnostics
- Reconcile full relay history to heal sync holes
- Sort tag chips alphabetically

## [2.0.0] - 2026-07-30

- Search notes and filter by tags
- Use multiple Blossom servers with mirroring and retrieval failover
- Offer working Blossom servers when an upload is refused and stop resending files to servers that refuse them
- Capture sync failures and show them in the note contextual menu
- Add the sensitive kind to the filter and improve the mobile filter layout
- Fix double paste on desktop

## [1.6.0] - 2026-07-28

- Re-sign Android releases with a production certificate (existing users must reinstall)

## [1.5.0] - 2026-07-24

- Add dark theme with automatic switching
- Paste text from the clipboard even when the input is not focused
- Set the default crop area to the whole image

## [1.4.1] - 2026-07-09

- Fix Android signer login broken by Amber returning a hex pubkey
- Treat interrupted publishes as failed instead of pending
- Add a proper warning to the logout procedure
- Set up iOS building
- Fix scrolling in the bunker login view

## [1.4.0] - 2026-07-07

- Support video playback on Linux via media_kit
- Permit pasting with the mouse middle click
- Optimize the crop and compress pipeline, preserving the image format
- Fix Blossom uploads to http:// hosts on web

## [1.3.0] - 2026-04-03

- Add sensitive notes management
- Support NIP-42 relay auth
- Fix reconnecting after a network drop
- Fix scrolling to the last note when opening the app
- Fix sharing a screenshot on Android

## [1.2.0] - 2026-03-20

- Show dimensions and size for files, allow zooming an image while resizing
- Rename file comments to captions
- Improve resync when the connection is restored
- Show the login method in the profile
- Fix the issue where decryption was retried in a loop

## [1.1.0] - 2026-03-13

- Receive shared text and files on mobile, with a "Send to Manent" Android text selection action
- Append shared content to the active add/edit session
- Update the icon on all platforms

## [1.0.2] - 2026-03-08

- Add an info dialog
- Use the native file picker on mobile
- Fix saving files and single-tap menu on mobile web

## [1.0.1] - 2026-03-06

- Optimize the Android build
- Update the fallback Blossom server

## [1.0.0] - 2026-03-06

- Initial release
