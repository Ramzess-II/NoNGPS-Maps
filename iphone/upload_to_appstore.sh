#!/usr/bin/env bash
# Archives and uploads the release into the AppStore.
# Assumes that Xcode is signed in to the team: it creates the distribution profiles of the app and
# its extensions itself (-allowProvisioningUpdates), so none is kept in credentials/.

set -euxo pipefail

SCRIPT_DIR="$( cd "$(dirname "$0")" && pwd -P )"

IOS_BUILD=$($SCRIPT_DIR/../tools/unix/version.sh ios_build)
IOS_VERSION=$($SCRIPT_DIR/../tools/unix/version.sh ios_version)

BUILD_DIR="$SCRIPT_DIR/build"
mkdir -p "$BUILD_DIR"
ARCHIVE_PATH="$BUILD_DIR/OM-$IOS_VERSION-$IOS_BUILD.xcarchive"
IPA_PATH="$BUILD_DIR"
rm -rf "$ARCHIVE_PATH"


# Build release archive.
xcodebuild archive \
    -workspace "$SCRIPT_DIR/../xcode/omim.xcworkspace" \
    -configuration Release \
    -scheme OMaps \
    -destination generic/platform=iOS \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    MARKETING_VERSION="$IOS_VERSION" \
    CURRENT_PROJECT_VERSION="$IOS_BUILD"


# Upload the dSYMs to Sentry, so the crash reports have readable C++ frames. The token is in credentials/sentry.env, see
# docs/nogps/crash-reports.md; without it the build is still uploaded.
SENTRY_ENV="$SCRIPT_DIR/../credentials/sentry.env"
[ -f "$SENTRY_ENV" ] && source "$SENTRY_ENV"
if [ -n "${SENTRY_AUTH_TOKEN:-}" ] && command -v sentry-cli > /dev/null; then
  sentry-cli --org nongps --project nongps-maps-ios debug-files upload "$ARCHIVE_PATH/dSYMs"
else
  echo "WARNING: SENTRY_AUTH_TOKEN or sentry-cli is missing: the dSYMs are not uploaded to Sentry" >&2
fi


# Create a plist with upload options.
PLIST="$BUILD_DIR/export.plist"
cat > "$PLIST" <<EOM
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>upload</string>
  <key>method</key>
  <string>app-store-connect</string>
  <key>teamID</key>
  <string>VTWF79TU37</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
EOM

# Upload build to the AppStore.
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$PLIST" \
    -allowProvisioningUpdates


echo "Build was successfully uploaded! Please don't forget to tag it with release notes using:"
TAG="$IOS_VERSION-$IOS_BUILD-ios"
echo "git tag -a $TAG"
echo "git push origin $TAG"
