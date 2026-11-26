# Crash reports

Crashes of both apps go to Sentry (organization `nongps`, EU region), one project per platform:
`nongps-maps-ios` and `nongps-maps-android`. What is sent and why is in `privacy-policy.md`.

## What is on

- On by default in beta and release builds; off in Debug builds of the app (iOS: `DEBUG`, Android: `BuildConfig.DEBUG`).
- The switch "Send crash reports" (`nogps_crash_reports`) in the settings turns it off at once and keeps it off:
  iOS `MWMSettings.crashReportsEnabled`, Android the `SendCrashReports` preference.
- The DSN is `SENTRY_DSN_IOS` / `SENTRY_DSN_ANDROID` in `private.h`. An empty value disables reporting on that
  platform. A DSN is not a secret: it only permits sending events.
- Android: every flavor but `fdroid`, which links no Sentry (the real `CrashReporter` is in `src/sentry`, the no-op one
  in `src/nosentry`).
- Not sent: coordinates, trip logs, logcat or NSLog lines, screenshots, view hierarchy, network breadcrumbs, IP
  address (`sendDefaultPii = false`, *Prevent Storing of IP Addresses* on in both projects). An event with a path
  of the logs folder is dropped in `beforeSend`. Tracing, profiling, session replay, app hangs and user feedback are off.
- What a report carries: the stack, OS and device model, release `<version>+<build>`, tags `screen`, `box`,
  `box.firmware`, `nogps.source`, and for a failed `CHECK`/`ASSERT` the extras `assert.message` and `assert.source`
  (condition and `file:line`; a decimal with 4 or more digits after the point is replaced by `<num>`, as it may be a coordinate). The core's assert function calls `Logger.setAssertHandler` (iOS) /
  `Logger.setAssertListener` (Android) before the process aborts; it only puts the text on the Sentry scope, the
  native handler writes it to the report on disk and the report is sent at the next launch.
- The widget extension and Wear OS are not covered.

## Debug symbols

Reports have readable C++ frames only after the symbols are uploaded. The token is an organization auth token with the
`org:ci` scope (`sentry token create nongps/<name>`), kept in a gitignored `credentials/sentry.env`:

```
export SENTRY_AUTH_TOKEN=...
```

- iOS: `iphone/upload_to_appstore.sh` sources it and runs `sentry-cli debug-files upload` over the archive's dSYMs. It
  stops before the App Store upload when the token or `sentry-cli` is missing, and before the archive when
  `SENTRY_DSN_IOS` is empty.
- Android: the `io.sentry.android.gradle` plugin (`uploadNativeSymbols`) is applied only when `SENTRY_AUTH_TOKEN` is in
  the environment of the Gradle build.

Both developers need the file.

## Checking the whole path

With a beta or release build that has a DSN, type `?nogps-crash` in the search bar: the core fails a `CHECK` on purpose.
Start the app again; within a minute the report is in Sentry with `assert.message` and the C++ frames. With the switch
off nothing arrives.
