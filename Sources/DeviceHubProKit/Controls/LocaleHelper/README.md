# Device-language helper

`devicehubpro-locales.dex` is built from `DeviceHubProLocales.java` in this directory by
`Scripts/build-locale-helper.sh` (JDK 21 from Android Studio's JBR, `javac --release 8`
against `platforms/android-36/android.jar`, then `build-tools/36.0.0/d8 --release
--min-api 26`). Neither tool stamps times or paths into its output, so the build is
reproducible: `bash Scripts/build-locale-helper.sh --check` rebuilds it and compares.

- Size: 3,964 bytes
- SHA-256: `821d80041b64177599c18f25e3dd88a822e4ccd94bec4ba0dcac0cc320ea4924`
  (`LocaleHelperTests.testBundledHelperIsTheBuiltDex` pins both)

## Why a helper

The shell user holds `CHANGE_CONFIGURATION` and `WRITE_SETTINGS` from Android 8.0 (API
26), which is all `IActivityManager.updatePersistentConfiguration` checks, but no shell
command pushes a whole language list:

- `settings put system system_locales` is read only at boot (a stale value becomes the
  device language at the next restart), and `setprop persist.sys.locale` is refused.
- `cmd locale set-device-locale` exists from Android 16 QPR2 (API 36.1) and installs one
  language, which must be listed by `cmd locale list-device-locales`.

The helper does what Settings' `LocalePicker.updateLocales` does: a `Configuration` with
the list and `userSetLocale`, through the hidden `ActivityManager.getService()`. It runs
as the shell user the way scrcpy's server does:

```sh
adb push devicehubpro-locales.dex /data/local/tmp/devicehubpro-locales-<token>.dex
adb shell 'CLASSPATH=/data/local/tmp/devicehubpro-locales-<token>.dex app_process / DeviceHubProLocales set tr-TR,en-US; status=$?; rm -f /data/local/tmp/devicehubpro-locales-<token>.dex; exit $status'
```

Commands: `get` (the configuration's list), `set LIST [LIST...]` (pushes each list, one
second apart), `repush` (the current list again, which recomputes the layout direction
after `debug.force_rtl` changed) and `supported` (the framework's `supported_locales`,
the list language pickers start from on API 26-36.0).

Verified on the API 37 emulator: lists, `-u-` extensions (`en-US-u-mu-celsius`),
scripts (`zh-Hans-CN`), the Force RTL re-push (`ldrtl` ↔ `ldltr`), and the settle push
that keeps SystemUI's status-bar clock in the new language's time pattern. Older API
levels are source-verified only (`ActivityManager.getService()` and the permission checks
exist from android-8.0.0_r1).
