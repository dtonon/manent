#!/usr/bin/env bash
# Fail unless the app is signed with a certificate-based identity, so that
# macOS privacy grants survive across builds.
set -euo pipefail

APP="${1:?usage: $0 <path/to/App.app>}"

codesign --verify --deep --strict "$APP"
REQ="$(codesign -d -r- "$APP" 2>&1 | grep '^designated' || true)"
echo "$REQ"

if [[ "$REQ" != *"certificate leaf"* ]]; then
  echo "Signature is not certificate-based; run scripts/macos_signing_setup.sh first" >&2
  exit 1
fi
