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

# A release without the DSN sends no crash reports, see docs/nogps/crash-reports.md.
if ! grep -Eq '^#define SENTRY_DSN_IOS "https://' "$SCRIPT_DIR/../private.h"; then
  echo "ERROR: SENTRY_DSN_IOS of private.h is empty: the release would send no crash reports" >&2
  exit 1
fi


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
# docs/nogps/crash-reports.md. Without the token or sentry-cli the script stops before the App Store upload.
SENTRY_ENV="$SCRIPT_DIR/../credentials/sentry.env"
# No tracing around the token.
set +x
if [ -f "$SENTRY_ENV" ]; then
  source "$SENTRY_ENV"
fi
if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "ERROR: SENTRY_AUTH_TOKEN is missing, see docs/nogps/crash-reports.md" >&2
  exit 1
fi
set -x
if ! command -v sentry-cli > /dev/null; then
  echo "ERROR: sentry-cli is not in PATH ($PATH): brew install getsentry/tools/sentry-cli" >&2
  exit 1
fi
sentry-cli debug-files upload --org nongps --project nongps-maps-ios "$ARCHIVE_PATH/dSYMs"


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
