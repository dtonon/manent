set dotenv-load

# Cloudflare credentials (set these as environment variables)
CF_ZONE_ID := env_var_or_default("CF_ZONE_ID", "")
CF_API_TOKEN := env_var_or_default("CF_API_TOKEN", "")
CF_HOST := env_var_or_default("CF_HOST", "")

dev_macos:
    flutter run -d macos

dev_android:
    flutter run -d Pixel

dev_web:
    export CHROME_EXECUTABLE=/Applications/Chromium.app/Contents/MacOS/Chromium
    flutter run -d chrome --web-port 8080

build_macos:
    flutter build macos --release

build_android:
    flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols/android

build_android_bundle:
    flutter build appbundle --release --obfuscate --split-debug-info=build/symbols/android

build_linux:
    dart pub global activate flutter_distributor
    export PATH="$PATH":"$HOME/.pub-cache/bin"
    flutter_distributor release --name linux --jobs release-linux-appimage

build_web:
    flutter build web --release

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
        --data '{"hosts": ["{{CF_HOST}}"]}' \
        | jq -r 'if .success then "✅ Cache purged successfully" else "‼️ Error: " + (.errors[0].message // "Unknown error") end'
