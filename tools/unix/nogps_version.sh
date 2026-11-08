#!/bin/bash
# Versions of NonGPS Maps, see "Versions" in .claude/rules/nogps-workflow.md.
#   upstream                 After an upstream merge: write the version of the merged Organic Maps into
#                            nogps_upstream_version.txt, in the android_name format of version.sh.
#   ios_plist <plist> <line> Put the versions of this commit into the built Info.plist of an iOS target, and the
#                            version line into the file <line>.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPSTREAM_FILE="$ROOT/tools/unix/nogps_upstream_version.txt"

case "${1:-}" in
  upstream)
    # The newest Organic Maps commit in our history; version.sh counts the commits of its day the same way.
    BASE=$(git -C "$ROOT" merge-base HEAD upstream/master)
    COUNT_AND_DATE=( $(TZ=UTC0 git -C "$ROOT" log "$BASE" --max-count=128 --pretty=format:%cd --date=iso-local \
                         | cut -d' ' -f 1 | sed 's/-/./g' | sort | uniq -c | tail -1) )
    echo "${COUNT_AND_DATE[1]}-${COUNT_AND_DATE[0]}" > "$UPSTREAM_FILE"
    cat "$UPSTREAM_FILE"
    ;;
  ios_plist)
    # With GENERATE_INFOPLIST_FILE, Xcode takes the two versions from MARKETING_VERSION and CURRENT_PROJECT_VERSION
    # and drops them from a source plist, so they go into the built one. Xcode signs the bundle again only when a
    # declared output changes: the line file changes with every version.
    PLIST="$2"
    LINE_FILE="$3"
    cd "$ROOT"
    VERSION=$(bash tools/unix/version.sh ios_version)
    BUILD=$(bash tools/unix/version.sh android_code)  # yyMMddNN, as the Android versionCode.
    HASH=$(git describe --match= --always --abbrev=8 --dirty 2>/dev/null || echo 00000000)
    UPSTREAM=$(cat "$UPSTREAM_FILE")
    set_key() {
      if [ "$(/usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null)" != "$2" ]; then
        plutil -replace "$1" -string "$2" "$PLIST"
      fi
    }
    set_key CFBundleShortVersionString "$VERSION"
    set_key CFBundleVersion "$BUILD"
    set_key NoGpsGitHash "$HASH"
    set_key NoGpsUpstreamVersion "$UPSTREAM"
    LINE="$VERSION ($BUILD, $HASH), Organic Maps $UPSTREAM"
    if [ "$(cat "$LINE_FILE" 2>/dev/null)" != "$LINE" ]; then
      printf %s "$LINE" > "$LINE_FILE"
    fi
    ;;
  *)
    echo "Usage: $0 upstream | ios_plist <plist> <line>" >&2
    exit 1
    ;;
esac
