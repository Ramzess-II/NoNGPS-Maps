# NonGPS Maps: just recipes

`justfile` has shortcuts for the tasks we repeat: `just` lists them. Run them from `app/`. When a recipe does what
the task needs, use it instead of typing its commands. When it does more than needed, use the plain command.

- **Check a change in the running app:** `just android` builds, installs and starts the debug app on the phone
  plugged into USB. `just ios` does the same on the plugged-in iPhone, else on a simulator: `just ios sim`, or
  `just ios "<name or udid>"`.
  - Use them when the user wants to see the change on a device, not to check that the code compiles. For that,
    `./gradlew :app:compileGoogleDebugJavaWithJavac -Parm64` or an `xcodebuild ... build` is faster.
  - If Android refuses the install as a downgrade, see "Versions" in `nogps-workflow.md`.
- **An APK to send or install by hand:** `just apk`.
- **Core unit tests:** `just test` runs `NoGps_.*` of `map_tests`. Pass a filter and your own build dir:
  `just test "NoGps_Cars.*" build-<name>`.
- **Check the app against the box without the box:** `just box` opens the box simulator and its panel in the
  browser (macOS or Linux). It is a box standing in a parked car; the panel sets the flags, the OBD state, the
  shake and the versions. On macOS the app must be a debug build, see `tools/python/nogps_box_sim.py`.
- **Show trip logs to the user:** `just logs <files>` opens the log viewer in the browser. To analyse logs yourself,
  use `/nogps-log`.
- **Release:** `just appstore` uploads the iOS build to App Store Connect. Run it only when the user asks.

A command you repeat that has no recipe: suggest one to the user instead of adding it on your own. Recipes also
run on Ramzess's Windows: mark the ones that can't with `[unix]` or `[macos]`.
