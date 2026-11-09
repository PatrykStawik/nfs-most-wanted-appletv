#!/bin/sh
# Archives the Apple TV app (Release) and uploads it to App Store Connect for TestFlight: tvos/tv.sh upload.
# The app record must exist in App Store Connect with the same bundle ID (BUNDLE_ID in tvos/local.env). The build
# number is the date and time, so each upload is newer than the last; VERSION (default 1.0) is the version shown.
# The upload contains your game files (about 3 GB): keep the app to internal testers who own the game; never external
# testing or the App Store.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
[ -f tvos/local.env ] && . tvos/local.env
: "${TEAM:?set TEAM in tvos/local.env}"
BUILD=${BUILD:-$(date +%Y%m%d%H%M)}
VERSION=${VERSION:-1.0}
ARCHIVE=out/tvos-archive/NFSMW.xcarchive
rm -rf out/tvos-archive
xcodebuild -project tvos/NFSMW.xcodeproj -scheme NFSMW -configuration Release -destination 'generic/platform=tvOS' \
    -allowProvisioningUpdates -archivePath "$ARCHIVE" -derivedDataPath out/tvos-dd-release \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" archive 2>&1 | grep -E "error:|stage_game:|ARCHIVE (SUCC|FAIL)"
[ -d "$ARCHIVE" ] || { echo "testflight.sh: no archive" >&2; exit 1; }
cat > out/tvos-archive/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist out/tvos-archive/export.plist \
    -exportPath out/tvos-archive/export -allowProvisioningUpdates > out/tvos-archive/export.log 2>&1 || true
grep -E "error|Upload|EXPORT|uploaded|succeeded|failed" out/tvos-archive/export.log || true
grep -q "EXPORT SUCCEEDED" out/tvos-archive/export.log || { echo "testflight.sh: the upload failed (out/tvos-archive/export.log)" >&2; exit 1; }
echo "testflight.sh: version $VERSION build $BUILD sent; App Store Connect processes it for a few minutes"
