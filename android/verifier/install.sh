#!/usr/bin/env bash
# Builds, installs, grants permissions and launches the Device Hub Pro Verifier on ONE device.
#
#   ./install.sh emulator-5554            # or: ANDROID_SERIAL=emulator-5554 ./install.sh
#
# The device must be named, and every adb call carries `-s`: Gradle's installDebug would
# install on every attached device, phones included, and a script that picked the only
# attached device would pick a phone whenever the emulator is not running.
set -euo pipefail

cd "$(dirname "$0")"

SERIAL="${1:-${ANDROID_SERIAL:-}}"
if [ -z "$SERIAL" ]; then
    echo "usage: ./install.sh <serial>   (or set ANDROID_SERIAL); see 'adb devices'" >&2
    exit 64
fi

JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
ADB="${ADB:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb}"
PACKAGE="com.devicehubpro.verifier"
SERIAL="${1:-${ANDROID_SERIAL:-}}"

if [[ -z "$SERIAL" ]]; then
    attached=$("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }' | paste -sd " " -)
    echo "install.sh: name the device (./install.sh <serial> or ANDROID_SERIAL=<serial>); attached: ${attached:-none}" >&2
    exit 1
fi

JAVA_HOME="$JAVA_HOME" ./gradlew :app:assembleDebug
"$ADB" -s "$SERIAL" install -r -t app/build/outputs/apk/debug/app-debug.apk

for permission in \
    android.permission.ACCESS_FINE_LOCATION \
    android.permission.READ_PHONE_STATE \
    android.permission.READ_PHONE_NUMBERS \
    android.permission.READ_CALL_LOG \
    android.permission.RECEIVE_SMS \
    android.permission.BODY_SENSORS \
    android.permission.BLUETOOTH_CONNECT
do
    "$ADB" -s "$SERIAL" shell pm grant "$PACKAGE" "$permission" 2>/dev/null || true
done

"$ADB" -s "$SERIAL" shell am start -n "$PACKAGE/.MainActivity"
