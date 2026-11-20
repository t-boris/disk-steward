#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
APP_NAME="Disk Steward"
SOURCE_BUNDLE="$REPO_ROOT/dist/$APP_NAME.app"
DEPLOY_TARGET="/Applications/$APP_NAME.app"

echo "==> Step 1: Running automated test suite..."
swift test

echo "==> Step 2: Building signed Release application bundle ($VERSION)..."
"$REPO_ROOT/scripts/build-app.sh"

echo "==> Step 3: Deploying to $DEPLOY_TARGET..."
if pgrep -x "DiskSteward" >/dev/null 2>&1; then
    echo "Stopping running Disk Steward instance prior to upgrade..."
    pkill -x "DiskSteward" || true
    sleep 1
fi

rm -rf "$DEPLOY_TARGET"
ditto "$SOURCE_BUNDLE" "$DEPLOY_TARGET"

echo "==> Step 4: Confirming deployed version and code signature..."
DEPLOYED_SHORT_VERSION="$(defaults read "$DEPLOY_TARGET/Contents/Info.plist" CFBundleShortVersionString)"
DEPLOYED_BUILD="$(defaults read "$DEPLOY_TARGET/Contents/Info.plist" CFBundleVersion)"
CLI_VERSION_OUTPUT="$("$DEPLOY_TARGET/Contents/MacOS/DiskSteward" --version)"

codesign --verify --deep --strict "$DEPLOY_TARGET"

echo "Deployed bundle:  $DEPLOY_TARGET"
echo "Info.plist:       $DEPLOYED_SHORT_VERSION (build $DEPLOYED_BUILD)"
echo "Binary --version: $CLI_VERSION_OUTPUT"

if [[ "$DEPLOYED_SHORT_VERSION" != "$VERSION" ]]; then
    echo "ERROR: Deployed Info.plist version ($DEPLOYED_SHORT_VERSION) does not match VERSION ($VERSION)!" >&2
    exit 1
fi

if [[ "$CLI_VERSION_OUTPUT" != *"$VERSION"* ]]; then
    echo "ERROR: Deployed binary --version output ($CLI_VERSION_OUTPUT) does not match VERSION ($VERSION)!" >&2
    exit 1
fi

echo "==> Release $VERSION successfully built, deployed, and verified!"
