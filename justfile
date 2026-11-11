# Shortcuts for common NonGPS Maps tasks. Run `just` to list them.

set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

[private]
default:
    @just --list

# Build, install and start the Android debug app on the connected phone
[working-directory: 'android']
android:
    ./gradlew runGoogleDebug -Parm64

# Build the Android debug APK without installing it
[working-directory: 'android']
apk:
    ./gradlew assembleGoogleDebug -Parm64

# Build, install and start the iOS debug app: on the plugged-in iPhone, else a simulator; `sim` or a name to choose
[macos]
ios to="":
    #!/usr/bin/env bash
    set -euo pipefail
    read -r kind udid < <(xcrun devicectl list devices -q --json-output - | python3 -c '
    import json, subprocess, sys
    to = sys.argv[1]
    # (kind, udid, name, ready): a phone is ready when plugged in, a simulator when booted.
    phones = [("phone", d["hardwareProperties"]["udid"], d["deviceProperties"]["name"],
               d["connectionProperties"].get("transportType") == "wired")
              for d in json.load(sys.stdin)["result"]["devices"]
              if d["hardwareProperties"].get("reality") == "physical"
              and d["hardwareProperties"].get("deviceType") in ("iPhone", "iPad")]
    runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]
    sims = [("sim", s["udid"], s["name"], s["state"] == "Booted")
            for r, ss in sorted(runtimes.items()) if ".iOS-" in r for s in ss]
    if to in ("", "sim"):
        iphones = [s for s in sims if s[2].startswith("iPhone")]
        # The plugged-in phone, else a booted simulator, else the one of the newest iOS.
        found = [p for p in phones if p[3] and not to] + [s for s in iphones if s[3]] + iphones[::-1]
    else:
        found = [d for d in phones + sims if to in d[1:3]]
    if not found:
        sys.exit(f"No iPhone or simulator {to}")
    print(*found[0][:2])
    ' "{{to}}")
    build=(-workspace xcode/omim.xcworkspace -scheme OMaps -configuration Debug -destination "id=$udid")
    if [ "$kind" = sim ]; then
      xcrun simctl bootstatus "$udid" -b >/dev/null
      open -a Simulator 2>/dev/null || echo "No Simulator app to show it: the simulator runs without a window"
      build+=(EXCLUDED_ARCHS=x86_64)
    else
      build+=(-allowProvisioningUpdates)
    fi
    echo "Building for $kind $udid"
    xcodebuild "${build[@]}" -quiet build
    # The bundle id goes first: the path has spaces.
    read -r bundle app < <(xcodebuild "${build[@]}" -showBuildSettings -json 2>/dev/null | python3 -c '
    import json, sys
    b = next(t["buildSettings"] for t in json.load(sys.stdin) if t["target"] == "OMaps")
    print(b["PRODUCT_BUNDLE_IDENTIFIER"], b["TARGET_BUILD_DIR"] + "/" + b["FULL_PRODUCT_NAME"])
    ')
    if [ "$kind" = sim ]; then
      xcrun simctl install "$udid" "$app"
      xcrun simctl launch --terminate-running-process "$udid" "$bundle"
    else
      xcrun devicectl device install app --device "$udid" "$app"
      xcrun devicectl device process launch --terminate-existing --device "$udid" "$bundle"
    fi

# Archive the iOS release and upload it to App Store Connect, with the version of the last commit
[macos]
[confirm("Upload the last commit to App Store Connect?")]
appstore:
    git diff --quiet HEAD || { echo "Commit or stash the changes first: the version comes from the last commit"; exit 1; }
    ./iphone/upload_to_appstore.sh

# Build and run the NoGPS core unit tests on desktop (on Windows, CI runs them)
[unix]
test filter="NoGps_.*" dir="build/debug":
    [ -f {{dir}}/CMakeCache.txt ] || cmake --preset debug -B {{dir}}
    cmake --build {{dir}} --target map_tests
    {{ if os() == "macos" { "QT_PLUGIN_PATH=${QT_PLUGIN_PATH:-$(brew --prefix qt@6)/share/qt/plugins}" } else { "" } }} {{dir}}/map_tests --filter="{{filter}}"

# Open the trip log viewer in the browser; logs, zips or folders are optional, more can be added in the page
[no-cd]
logs *args:
    {{ if os_family() == "windows" { "python" } else { "python3" } }} {{ quote(justfile_directory() / "tools/python/nogps_log_viewer.py") }} {{args}}
