set dotenv-load

# Cloudflare credentials (set these as environment variables)
CF_ZONE_ID := env_var_or_default("CF_ZONE_ID", "")
CF_API_TOKEN := env_var_or_default("CF_API_TOKEN", "")
CF_HOST := env_var_or_default("CF_HOST", "")

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

build_linux:
    dart pub global activate flutter_distributor
    export PATH="$PATH":"$HOME/.pub-cache/bin"
    $HOME/.pub-cache/bin/flutter_distributor release --name linux --jobs release-linux-appimage
    # The AppImage maker bundles a mismatched mpv/ffmpeg stack that crashes
    # libmpv on video playback; strip it so it uses the system libmpv.
    # Runtime dependency: mpv-libs (Fedora) / libmpv2 (Debian/Ubuntu).
    ./scripts/strip_bundled_mpv.sh

build_windows:
    gh workflow run windows-release.yml --ref master
    @echo "\nFollow the build with: gh run watch"

fetch_windows:
    gh run download $(gh run list --workflow=windows-release.yml --status success -L1 --json databaseId -q '.[0].databaseId') -p 'manent-windows-*' -D dist/
    @echo "\nArtifacts saved in dist/manent-windows-*/"

build_web:
    flutter build web --release
    tar --format zip --options zip:compression=deflate,zip:compression-level=9 -cf dist/manent-web.zip -s '|^build/web|manent-web|' build/web


deploy_android: build_android
    @echo "\nDeploying application..."
    adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk

deploy_web target: build_web
    @echo "\nDeploying application..."
    rsync -av --delete --progress build/web/ {{target}}:~/manent/
    @just purge-web-cache

purge-web-cache:
    @echo "\nPurging Cloudflare cache... for zone {{CF_ZONE_ID}}"
    @curl -s -X POST "https://api.cloudflare.com/client/v4/zones/{{CF_ZONE_ID}}/purge_cache" \
        -H "Authorization: Bearer {{CF_API_TOKEN}}" \
        -H "Content-Type: application/json" \
        --data '{"purge_everything": true}' \
        | jq -r 'if .success then "✅ Cache purged successfully" else "‼️ Error: " + (.errors[0].message // "Unknown error") end'
