#!/usr/bin/env bash
# Builds the device-language helper (Sources/DeviceHubProKit/Controls/LocaleHelper) from
# its Java source: javac against the SDK's android.jar, then the build-tools' d8.
# The inputs are pinned (JDK 21 from Android Studio's JBR, platform android-36,
# build-tools 36.0.0), and neither tool stamps times or paths into its output, so
# the dex is byte-identical on every run. `--check` rebuilds into a temporary
# directory and compares with the vendored file instead of replacing it.
#
#   bash Scripts/build-locale-helper.sh           # rebuild devicehubpro-locales.dex
#   bash Scripts/build-locale-helper.sh --check   # verify the vendored dex
set -euo pipefail

cd "$(dirname "$0")/.."

sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
platform="android-36"
build_tools="36.0.0"

helper_dir="Sources/DeviceHubProKit/Controls/LocaleHelper"
source_file="$helper_dir/DeviceHubProLocales.java"
output="$helper_dir/devicehubpro-locales.dex"
android_jar="$sdk/platforms/$platform/android.jar"
d8="$sdk/build-tools/$build_tools/d8"

die() {
    echo "build-locale-helper: $*" >&2
    exit 1
}

check=0
case "${1:-}" in
    "") ;;
    --check) check=1 ;;
    *) die "unknown option $1 (use --check)" ;;
esac

[[ -x "$JAVA_HOME/bin/javac" ]] || die "no javac under JAVA_HOME ($JAVA_HOME)"
[[ -f "$android_jar" ]] || die "missing $android_jar (sdkmanager \"platforms;$platform\")"
[[ -x "$d8" ]] || die "missing $d8 (sdkmanager \"build-tools;$build_tools\")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$JAVA_HOME/bin/javac" --release 8 -Xlint:-options -encoding UTF-8 \
    -classpath "$android_jar" -d "$work/classes" "$source_file"
"$d8" --release --min-api 26 --lib "$android_jar" --output "$work" \
    "$work/classes/DeviceHubProLocales.class"

if ((check)); then
    if cmp -s "$work/classes.dex" "$output"; then
        echo "devicehubpro-locales.dex matches its source"
    else
        die "devicehubpro-locales.dex differs from a fresh build of $source_file"
    fi
else
    cp "$work/classes.dex" "$output"
    echo "wrote $output ($(wc -c < "$output" | tr -d ' ') bytes)"
    shasum -a 256 "$output"
fi
