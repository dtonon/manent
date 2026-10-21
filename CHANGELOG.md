# Changelog

Notable changes to Manent. The format follows [Keep a Changelog](https://keepachangelog.com); entries under Unreleased become the next release's notes.

## [Unreleased]

- Fix the web build, which failed in the audio decoder build hooks
- Let the GitHub release workflows attach their Linux and Windows artifacts

Manent learns to listen. Record voice notes, have them transcribed on your device, and play them back from an inline player, all stored and synced with the same encryption as everything else.

- Record voice notes in a full-screen recorder with a live level meter, pause and resume, a confirmation before discarding, and the screen kept awake while recording
- Transcribe on the device with whisper: downloadable models, language choice, a prompt built from your own tags so hashtags come out spelled right, and transcription of imported audio as soon as a model is present
- Show elapsed time, a progress bar and a Cancel button while a note is transcribing, and a Waiting state for notes queued behind it
- Keep transcripts apart from captions, each with its own edit, copy, re-transcribe and remove actions, and count tags found in transcripts as note tags
- Play audio notes inline with a real waveform, a draggable cursor, the duration, and a per-note playback speed on voice notes
- Normalize recordings to a standard level and trim the silence at both ends
- Decode mp3, Ogg Vorbis, Ogg Opus and WAV for waveforms and transcription
- Filter by Voice notes and Audio in the search panel; voice notes carry a mic icon on the player
- Group file note menus into Caption and Transcript submenus and move the filename into the details block
- Turn an audio note into a text note with Remove audio file, keeping transcript and caption
- Save a recording automatically if the app goes to the background, and stop any playing audio when the recorder opens

General improvements:

- Crop long notes to two thirds of the viewport with a Read more button
- Add a GitHub Linux release pipeline producing tar.gz, deb and rpm packages
- Replace the Linux AppImage with a plain tar.gz bundle
- Standardize the release pipeline (just release / publish / ship, with undo and changelog helpers)
- Name all release artifacts manent-<version>-<platform>-<arch>
- Attach the web bundle to releases
- Sign macOS builds with a stable self-signed identity so privacy grants survive updates (one re-prompt on the first update)

Fixes:

- Fix sync from relays that require authentication, by upgrading NDK to 0.10.1: the subscription is re-sent once the relay accepts the login, so notes stored only on such a relay are no longer missed on a fresh login or a full re-sync. If an account looked incomplete after logging in on a new device, a full re-sync now recovers the notes those relays hold

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
