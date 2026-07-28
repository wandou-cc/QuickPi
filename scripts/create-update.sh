#!/bin/sh

set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SPARKLE_VERSION="2.9.4"
SPARKLE_SHA256="cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"
MACHINE_ARCH=$(uname -m)
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_ROOT/resources/Info.plist")
OUTPUT_DIRECTORY="$PROJECT_ROOT/release/native-$MACHINE_ARCH"
ARCHIVE_NAME="Quick-Pi-$APP_VERSION-$MACHINE_ARCH.zip"
ARCHIVE_PATH="$OUTPUT_DIRECTORY/$ARCHIVE_NAME"
APPCAST_PATH="$OUTPUT_DIRECTORY/appcast-$MACHINE_ARCH.xml"
CACHE_DIRECTORY="$PROJECT_ROOT/.cache/sparkle-$SPARKLE_VERSION"
SPARKLE_ARCHIVE="$CACHE_DIRECTORY/Sparkle-for-Swift-Package-Manager.zip"
TOOLS_DIRECTORY="$CACHE_DIRECTORY/tools"

case "$MACHINE_ARCH" in
  arm64|x86_64)
    ;;
  *)
    echo "Unsupported macOS architecture: $MACHINE_ARCH" >&2
    exit 1
    ;;
esac

if [ ! -f "$ARCHIVE_PATH" ]; then
  echo "Update archive not found; run scripts/package-mac.sh first: $ARCHIVE_PATH" >&2
  exit 1
fi

mkdir -p "$CACHE_DIRECTORY" "$TOOLS_DIRECTORY"
if [ ! -f "$SPARKLE_ARCHIVE" ] || [ "$(shasum -a 256 "$SPARKLE_ARCHIVE" | awk '{print $1}')" != "$SPARKLE_SHA256" ]; then
  curl --http1.1 -fL --retry 5 --retry-delay 2 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip" \
    -o "$SPARKLE_ARCHIVE"
fi

ACTUAL_SHA256=$(shasum -a 256 "$SPARKLE_ARCHIVE" | awk '{print $1}')
if [ "$ACTUAL_SHA256" != "$SPARKLE_SHA256" ]; then
  echo "Sparkle archive checksum mismatch" >&2
  exit 1
fi

unzip -oq "$SPARKLE_ARCHIVE" -d "$TOOLS_DIRECTORY"
WORK_DIRECTORY=$(mktemp -d "${TMPDIR:-/tmp}/quickpi-appcast.XXXXXX")
trap 'rm -rf "$WORK_DIRECTORY"' EXIT
cp "$ARCHIVE_PATH" "$WORK_DIRECTORY/$ARCHIVE_NAME"

"$TOOLS_DIRECTORY/bin/generate_appcast" \
  --account dev.pi.quick \
  --download-url-prefix "https://github.com/wandou-cc/QuickPi/releases/download/v$APP_VERSION/" \
  --link "https://github.com/wandou-cc/QuickPi/releases/tag/v$APP_VERSION" \
  --maximum-deltas 0 \
  -o "$WORK_DIRECTORY/appcast.xml" \
  "$WORK_DIRECTORY"
cp "$WORK_DIRECTORY/appcast.xml" "$APPCAST_PATH"

echo "$ARCHIVE_PATH"
echo "$APPCAST_PATH"
