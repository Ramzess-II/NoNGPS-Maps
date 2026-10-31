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

# Build and run the NoGPS core unit tests on desktop (on Windows, CI runs them)
[unix]
test filter="NoGps_.*" dir="build/debug":
    [ -f {{dir}}/CMakeCache.txt ] || cmake --preset debug -B {{dir}}
    cmake --build {{dir}} --target map_tests
    {{ if os() == "macos" { "QT_PLUGIN_PATH=${QT_PLUGIN_PATH:-$(brew --prefix qt@6)/share/qt/plugins}" } else { "" } }} {{dir}}/map_tests --filter="{{filter}}"
