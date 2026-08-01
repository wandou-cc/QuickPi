#!/bin/sh

set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PI_VERSION="0.82.1"
MACHINE_ARCH=$(uname -m)
DEVELOPER_DIRECTORY="/Applications/Xcode.app/Contents/Developer"
SWIFT="$DEVELOPER_DIRECTORY/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
MODULE_CACHE="$PROJECT_ROOT/.build/module-cache"

if [ ! -x "$SWIFT" ]; then
  echo "Xcode Swift toolchain not found: $SWIFT" >&2
  exit 1
fi

case "$MACHINE_ARCH" in
  arm64)
    PI_ARCH="arm64"
    PI_SHA256="ca5b660ee0dbf2b4169f69753cf60f4e0edddff4a49427cdd34660e41280249f"
    ;;
  x86_64)
    PI_ARCH="x64"
    PI_SHA256="a28cd67f9397a5ad99f9387713bf1c134b747d4b6cb25e00db4f7d009ee9f8c2"
    ;;
  *)
    echo "Unsupported macOS architecture: $MACHINE_ARCH" >&2
    exit 1
    ;;
esac

ARCHIVE_NAME="pi-darwin-$PI_ARCH.tar.gz"
CACHE_DIRECTORY="$PROJECT_ROOT/.cache/pi-$PI_VERSION"
ARCHIVE_PATH="$CACHE_DIRECTORY/$ARCHIVE_NAME"
RUNTIME_DIRECTORY="$PROJECT_ROOT/.build/pi-runtime-$PI_ARCH"
OUTPUT_DIRECTORY="$PROJECT_ROOT/release/native-$MACHINE_ARCH"
APP_PATH="$OUTPUT_DIRECTORY/Quick Pi.app"
STAGING_APP_PATH="$OUTPUT_DIRECTORY/.Quick Pi.app.staging"
CONTENTS_PATH="$STAGING_APP_PATH/Contents"
FRAMEWORKS_PATH="$CONTENTS_PATH/Frameworks"
LICENSES_PATH="$CONTENTS_PATH/Resources/Licenses"
ASSET_CATALOG_PATH="$PROJECT_ROOT/.build/QuickPiAssets.xcassets"
ICONSET_PATH="$ASSET_CATALOG_PATH/AppIcon.appiconset"
ASSET_OUTPUT_PATH="$PROJECT_ROOT/.build/QuickPiAssets"
ASSET_INFO_PATH="$PROJECT_ROOT/.build/QuickPiAssets.plist"
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_ROOT/resources/Info.plist")
UPDATE_ARCHIVE_PATH="$OUTPUT_DIRECTORY/Quick-Pi-$APP_VERSION-$MACHINE_ARCH.zip"

mkdir -p "$CACHE_DIRECTORY"
if [ ! -f "$ARCHIVE_PATH" ] || [ "$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')" != "$PI_SHA256" ]; then
  curl --http1.1 -fL --retry 5 --retry-delay 2 \
    "https://github.com/earendil-works/pi/releases/download/v$PI_VERSION/$ARCHIVE_NAME" \
    -o "$ARCHIVE_PATH"
fi

ACTUAL_SHA256=$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$PI_SHA256" ]; then
  echo "Pi archive checksum mismatch" >&2
  exit 1
fi

rm -rf "$RUNTIME_DIRECTORY"
mkdir -p "$RUNTIME_DIRECTORY"
tar -xzf "$ARCHIVE_PATH" -C "$RUNTIME_DIRECTORY" --strip-components=1
if [ ! -x "$RUNTIME_DIRECTORY/pi" ]; then
  echo "Official Pi archive does not contain an executable named pi" >&2
  exit 1
fi

env \
  DEVELOPER_DIR="$DEVELOPER_DIRECTORY" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
  "$SWIFT" build \
  --disable-sandbox \
  --package-path "$PROJECT_ROOT" \
  -c release \
  --product QuickPi \
  -Xswiftc -warnings-as-errors \
  -Xswiftc -Wwarning \
  -Xswiftc ImplementationOnlyDeprecated

rm -rf "$STAGING_APP_PATH" "$ASSET_CATALOG_PATH" "$ASSET_OUTPUT_PATH" "$ASSET_INFO_PATH"
mkdir -p \
  "$CONTENTS_PATH/MacOS" \
  "$CONTENTS_PATH/Resources/plan-mode" \
  "$CONTENTS_PATH/Resources/ProviderIcons" \
  "$CONTENTS_PATH/Resources/pi-runtime/theme" \
  "$FRAMEWORKS_PATH" \
  "$LICENSES_PATH" \
  "$ICONSET_PATH" \
  "$ASSET_OUTPUT_PATH"
cp "$PROJECT_ROOT/.build/release/QuickPi" "$CONTENTS_PATH/MacOS/QuickPi"
cp "$PROJECT_ROOT/resources/Info.plist" "$CONTENTS_PATH/Info.plist"
/usr/libexec/PlistBuddy -c \
  "Set :SUFeedURL https://github.com/wandou-cc/QuickPi/releases/latest/download/appcast-$MACHINE_ARCH.xml" \
  "$CONTENTS_PATH/Info.plist"
cp "$PROJECT_ROOT/resources/quick-pi-extension.js" "$CONTENTS_PATH/Resources/quick-pi-extension.js"
cp "$PROJECT_ROOT/resources/quick-pi-questionnaire.js" "$CONTENTS_PATH/Resources/quick-pi-questionnaire.js"
ditto "$PROJECT_ROOT/Sources/QuickPi/Resources/ProviderIcons" "$CONTENTS_PATH/Resources/ProviderIcons"
if [ ! -f "$RUNTIME_DIRECTORY/examples/extensions/plan-mode/index.ts" ] || \
   [ ! -f "$RUNTIME_DIRECTORY/examples/extensions/plan-mode/utils.ts" ]; then
  echo "Official Pi archive does not contain the plan-mode extension" >&2
  exit 1
fi
cp "$RUNTIME_DIRECTORY/examples/extensions/plan-mode/index.ts" "$CONTENTS_PATH/Resources/plan-mode/index.ts"
cp "$RUNTIME_DIRECTORY/examples/extensions/plan-mode/utils.ts" "$CONTENTS_PATH/Resources/plan-mode/utils.ts"
cp "$RUNTIME_DIRECTORY/pi" "$CONTENTS_PATH/Resources/pi-runtime/pi"
cp "$RUNTIME_DIRECTORY/package.json" "$CONTENTS_PATH/Resources/pi-runtime/package.json"
cp "$RUNTIME_DIRECTORY/photon_rs_bg.wasm" "$CONTENTS_PATH/Resources/pi-runtime/photon_rs_bg.wasm"
ditto "$RUNTIME_DIRECTORY/export-html" "$CONTENTS_PATH/Resources/pi-runtime/export-html"
cp "$RUNTIME_DIRECTORY/theme/dark.json" "$CONTENTS_PATH/Resources/pi-runtime/theme/dark.json"
cp "$RUNTIME_DIRECTORY/theme/light.json" "$CONTENTS_PATH/Resources/pi-runtime/theme/light.json"
cp "$RUNTIME_DIRECTORY/theme/theme-schema.json" "$CONTENTS_PATH/Resources/pi-runtime/theme/theme-schema.json"
cp "$PROJECT_ROOT/LICENSE" "$CONTENTS_PATH/Resources/LICENSE.txt"
cp "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$CONTENTS_PATH/Resources/THIRD_PARTY_NOTICES.md"
ditto "$PROJECT_ROOT/licenses" "$LICENSES_PATH"
if [ ! -d "$PROJECT_ROOT/.build/release/Sparkle.framework" ]; then
  echo "Swift build did not produce Sparkle.framework" >&2
  exit 1
fi
ditto "$PROJECT_ROOT/.build/release/Sparkle.framework" "$FRAMEWORKS_PATH/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS_PATH/MacOS/QuickPi"

sips -z 16 16 "$PROJECT_ROOT/resources/icon.png" --out "$ICONSET_PATH/icon_16x16.png" >/dev/null
sips -z 32 32 "$PROJECT_ROOT/resources/icon.png" --out "$ICONSET_PATH/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$PROJECT_ROOT/resources/icon.png" --out "$ICONSET_PATH/icon_32x32.png" >/dev/null
sips -z 64 64 "$PROJECT_ROOT/resources/icon.png" --out "$ICONSET_PATH/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$PROJECT_ROOT/resources/icon.png" --out "$ICONSET_PATH/icon_128x128.png" >/dev/null
sips -z 256 256 "$PROJECT_ROOT/resources/icon.png" --out "$ICONSET_PATH/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$PROJECT_ROOT/resources/icon.png" --out "$ICONSET_PATH/icon_256x256.png" >/dev/null
sips -z 512 512 "$PROJECT_ROOT/resources/icon.png" --out "$ICONSET_PATH/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$PROJECT_ROOT/resources/icon.png" --out "$ICONSET_PATH/icon_512x512.png" >/dev/null
cp "$PROJECT_ROOT/resources/icon.png" "$ICONSET_PATH/icon_512x512@2x.png"
cp "$PROJECT_ROOT/resources/AppIcon.appiconset/Contents.json" "$ICONSET_PATH/Contents.json"
DEVELOPER_DIR="$DEVELOPER_DIRECTORY" xcrun actool \
  --compile "$ASSET_OUTPUT_PATH" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$ASSET_INFO_PATH" \
  "$ASSET_CATALOG_PATH" >/dev/null
cp "$ASSET_OUTPUT_PATH/AppIcon.icns" "$CONTENTS_PATH/Resources/AppIcon.icns"
rm -rf "$ASSET_CATALOG_PATH" "$ASSET_OUTPUT_PATH" "$ASSET_INFO_PATH"

chmod 755 "$CONTENTS_PATH/MacOS/QuickPi" "$CONTENTS_PATH/Resources/pi-runtime/pi"
codesign --force --deep --sign - "$STAGING_APP_PATH"
codesign --verify --deep --strict "$STAGING_APP_PATH"
rm -rf "$APP_PATH"
mv "$STAGING_APP_PATH" "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$UPDATE_ARCHIVE_PATH"

du -sh "$APP_PATH"
echo "$APP_PATH"
echo "$UPDATE_ARCHIVE_PATH"
