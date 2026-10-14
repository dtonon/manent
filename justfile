set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load

# Cloudflare credentials (set these as environment variables)
CF_ZONE_ID := env_var_or_default("CF_ZONE_ID", "")
CF_API_TOKEN := env_var_or_default("CF_API_TOKEN", "")
CF_HOST := env_var_or_default("CF_HOST", "")

version := `sed -n 's/^version: \([^+]*\)+.*/\1/p' pubspec.yaml`

default:
    @just --list

# Analyze and run the tests
test:
    flutter analyze
    flutter test

# Print the code version and the latest tag
version:
    @echo "code: {{version}}"
    @echo "tag:  $(git describe --tags --abbrev=0 2>/dev/null || echo none)"

dev_macos:
    flutter run -d macos

dev_android:
    flutter run -d Pixel

dev_ios:
    open -a Simulator
    flutter run -d iPhone

dev_web:
    export CHROME_EXECUTABLE=/Applications/Chromium.app/Contents/MacOS/Chromium
    flutter run -d chrome --web-port 8080

build_macos:
    flutter build macos --release
    cp -R build/macos/Build/Products/Release/Manent.app dist/

# Second isolated instance (own bundle id → own data dir/prefs), handy for sync tests
test_instance_macos:
    rm -rf dist/Manent-Test.app
    cp -R build/macos/Build/Products/Release/Manent.app dist/Manent-Test.app
    plutil -replace CFBundleIdentifier -string com.dtonon.manent.test dist/Manent-Test.app/Contents/Info.plist
    plutil -replace CFBundleName -string Manent-Test dist/Manent-Test.app/Contents/Info.plist
    codesign --force --deep --sign - dist/Manent-Test.app
    open dist/Manent-Test.app

build_android:
    flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols/android
    cp -R build/app/outputs/flutter-apk/* dist/

build_android_bundle:
    flutter build appbundle --release --obfuscate --split-debug-info=build/symbols/android

build_ios:
    flutter build ipa --release --obfuscate --split-debug-info=build/symbols/ios
    cp build/ios/ipa/*.ipa dist/

# Runtime dependency: mpv-libs (Fedora) / libmpv2 (Debian/Ubuntu).
build_linux:
    flutter build linux --release
    tar -czf dist/manent-{{version}}-linux-x64.tar.gz -C $(ls -d build/linux/*/release/bundle) .
    @echo -e "\nArtifact saved in dist/manent-{{version}}-linux-x64.tar.gz"

# Same packaging as the github workflow; needs fpm (gem install fpm).
package_linux: build_linux
    #!/usr/bin/env bash
    set -euo pipefail
    BUNDLE_DIR=$(ls -d build/linux/*/release/bundle)
    PKG=build/linux-pkg
    rm -rf "$PKG"
    mkdir -p "$PKG"/usr/lib/manent "$PKG"/usr/bin \
      "$PKG"/usr/share/applications "$PKG"/usr/share/icons/hicolor/1024x1024/apps
    cp -r "$BUNDLE_DIR"/. "$PKG"/usr/lib/manent/
    ln -s ../lib/manent/manent "$PKG"/usr/bin/manent
    cp linux/packaging/manent.desktop "$PKG"/usr/share/applications/
    cp assets/icon.png "$PKG"/usr/share/icons/hicolor/1024x1024/apps/manent.png
    fpm -f -s dir -t deb -n manent -v "{{version}}" -a native \
      --description "Sync encrypted notes and files between devices via Nostr" \
      --url "https://github.com/dtonon/manent" \
      --depends libmpv2 --depends libsecret-1-0 \
      -p dist/manent-{{version}}-linux-x64.deb -C "$PKG" usr
    fpm -f -s dir -t rpm -n manent -v "{{version}}" -a native \
      --description "Sync encrypted notes and files between devices via Nostr" \
      --url "https://github.com/dtonon/manent" \
      --depends mpv-libs --depends libsecret \
      -p dist/manent-{{version}}-linux-x64.rpm -C "$PKG" usr
    echo -e "\nArtifacts saved in dist/manent-{{version}}-linux-x64.{deb,rpm}"

build_web:
    flutter build web --release
    tar --format zip --options zip:compression=deflate,zip:compression-level=9 -cf dist/manent-web.zip -s '|^build/web|manent-web|' build/web

gh_build_linux:
    gh workflow run linux-release.yml --ref master
    @echo -e "\nFollow the build with: gh run watch"

gh_fetch_linux:
    rm -rf dist/manent-linux-*
    gh run download $(gh run list --workflow=linux-release.yml --status success -L1 --json databaseId -q '.[0].databaseId') -p 'manent-linux-*' -D dist/
    @echo -e "\nArtifacts saved in dist/manent-linux-*/"

gh_build_windows:
    gh workflow run windows-release.yml --ref master
    @echo -e "\nFollow the build with: gh run watch"

gh_fetch_windows:
    rm -rf dist/manent-windows-*
    gh run download $(gh run list --workflow=windows-release.yml --status success -L1 --json databaseId -q '.[0].databaseId') -p 'manent-windows-*' -D dist/
    @echo -e "\nArtifacts saved in dist/manent-windows-*/"

# Build the local release artifacts as dist/manent-<version>-* (linux/windows come from CI on tag push)
dist: build_macos build_android
    #!/usr/bin/env bash
    set -euo pipefail
    rm -f dist/manent-{{version}}-*
    ditto -c -k --keepParent build/macos/Build/Products/Release/Manent.app dist/manent-{{version}}-macos.zip
    for apk in build/app/outputs/flutter-apk/app-*-release.apk; do
        abi=$(basename "$apk" | sed 's/^app-\(.*\)-release\.apk$/\1/')
        cp "$apk" "dist/manent-{{version}}-android-$abi.apk"
    done
    ls -1 dist/manent-{{version}}-*

# Bump the version and changelog, commit and tag (no push)
release VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    v="{{VERSION}}"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z"; exit 1; }
    [[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean"; exit 1; }
    ! git rev-parse -q --verify "refs/tags/v$v" >/dev/null || { echo "tag v$v exists"; exit 1; }
    grep -q '^## \[Unreleased\]' CHANGELOG.md || { echo "no Unreleased section in CHANGELOG.md"; exit 1; }
    [[ -n "$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f && /^- /' CHANGELOG.md)" ]] || { echo "no entries under Unreleased in CHANGELOG.md"; exit 1; }
    build=$(sed -n 's/^version: .*+//p' pubspec.yaml)
    sed -i '' "s/^version: .*/version: $v+$((build + 1))/" pubspec.yaml
    sed -i '' "s/^## \[Unreleased\]/## [Unreleased]\n\n## [$v] - $(date +%Y-%m-%d)/" CHANGELOG.md
    just test
    git add pubspec.yaml CHANGELOG.md
    git commit -m "Release v$v"
    git tag -a "v$v" -m "v$v"
    echo "Released v$v, push with: git push --follow-tags"

# Create the GitHub release for the current version with the local artifacts attached; `just publish draft` for a draft
publish MODE="":
    #!/usr/bin/env bash
    set -euo pipefail
    v="{{version}}"; tag="v$v"
    [[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean"; exit 1; }
    git rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "tag $tag not found, run: just release $v"; exit 1; }
    [[ -n "$(git ls-remote --tags origin "$tag")" ]] || { echo "tag $tag not on origin, run: git push --follow-tags"; exit 1; }
    notes="$(awk -v h="## [$v]" 'index($0,h)==1{f=1;next} /^## \[/{f=0} f' CHANGELOG.md)"
    just dist
    # The tag-triggered workflows may have created the release already to attach linux/windows artifacts
    if gh release view "$tag" > /dev/null 2>&1; then
        gh release edit "$tag" --title "$tag" --notes "$notes"
        gh release upload "$tag" dist/manent-"$v"-* --clobber
    else
        draft=""
        [[ "{{MODE}}" != "draft" ]] || draft="--draft"
        gh release create "$tag" dist/manent-"$v"-* --title "$tag" --notes "$notes" $draft
    fi

# Release, push and publish in one go; `just ship X.Y.Z draft` for a draft release
ship VERSION MODE="":
    just release {{VERSION}}
    git push --follow-tags
    just publish {{MODE}}

deploy_android: build_android
    @echo -e "\nDeploying application..."
    adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk

deploy_web target: build_web
    @echo -e "\nDeploying application..."
    rsync -av --delete --progress build/web/ {{target}}:~/manent/
    @just purge-web-cache

purge-web-cache:
    @echo -e "\nPurging Cloudflare cache... for zone {{CF_ZONE_ID}}"
    @curl -s -X POST "https://api.cloudflare.com/client/v4/zones/{{CF_ZONE_ID}}/purge_cache" \
        -H "Authorization: Bearer {{CF_API_TOKEN}}" \
        -H "Content-Type: application/json" \
        --data '{"purge_everything": true}' \
        | jq -r 'if .success then "✅ Cache purged successfully" else "‼️ Error: " + (.errors[0].message // "Unknown error") end'
