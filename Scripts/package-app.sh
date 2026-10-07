#!/usr/bin/env bash
# Builds dist/Device Hub Pro.app from the Swift package, signs it, and with --dmg
# wraps it in dist/DeviceHubPro-<version>.dmg. docs/distribution.md walks through
# signing, notarization and cutting a release.
#
#   Scripts/package-app.sh                    # Apple silicon build, ad-hoc signed
#   Scripts/package-app.sh --dmg              # ... plus the disk image
#   Scripts/package-app.sh --sign "Developer ID Application: Jane Doe (TEAMID)" --dmg
#   Scripts/package-app.sh --host-arch        # this Mac's architecture (arm64 on Apple silicon)
#   Scripts/package-app.sh --sign "..." --dmg-only   # image an existing (stapled) app
#   Scripts/package-app.sh --require-licenses --dmg  # what release.yml runs
#   Scripts/package-app.sh --appcast-url https://.../appcast.xml --sparkle-public-key <base64> --dmg
#
# In-app updates (Sparkle 2): Sparkle.framework is embedded in
# Contents/Frameworks and signed inside out (XPC services, Autoupdate,
# Updater.app, the framework, then the app; never --deep). The updater only
# runs when the app's Info.plist names a feed and a public key, which come from
# --appcast-url / DHP_APPCAST_URL and --sparkle-public-key /
# DHP_SPARKLE_PUBLIC_KEY. Without them the build has no updater and no
# "Check for Updates..." item (docs/distribution.md, "In-app updates").
# DHP_HELP_URL names the page Help ▸ Device Hub Pro Help opens (the public
# repository's README); without it the Help menu has no item.
#
# BoringSSL's LICENSE (packaging/licenses, see check_boringssl_licenses) must
# ship with any build that other people get. A build signed with a real
# identity, or run with --require-licenses, stops when the file is missing. A
# local ad-hoc build goes on without it and warns at the start and the end
# that the result must stay on this Mac.
#
# With a real identity the app is signed with the hardened runtime, which
# notarization requires, and two entitlements: the Camera and the audio input
# (packaging/DeviceHubPro.entitlements), which the hardened runtime needs for the
# capture device a connected iPhone's screen and audio arrive as (the live view
# of a physical iPhone, the public CoreMediaIO + AVFoundation screen capture path). Nothing else is needed: the app spawns adb, emulator and java (the
# hardened runtime does not restrict child processes), reads the Android SDK
# and ~/.android (it is not sandboxed), and compiles its Metal shader at run
# time (Metal compiles out of process, so no JIT entitlement). --entitlements
# replaces the default file.
#
# Ad-hoc builds get no hardened runtime: they cannot be notarized, so it buys
# them nothing. Its library validation also refuses an ad-hoc dylib in an
# ad-hoc process ("mapping process and mapped file (non-platform) have
# different Team IDs"), which made a hardened ad-hoc build abort before main
# while the app bundled libswiftCompatibilitySpan.dylib for macOS 15. The
# macOS 26 app bundles no dylib (check_swift_runtime).

set -euo pipefail

APP_NAME="Device Hub Pro"   # the bundle: dist/Device Hub Pro.app
EXEC_NAME="DeviceHubPro"    # the SwiftPM product: executable, dSYM, disk image, resource bundles
# Every package in Package.resolved must be in exactly one of these lists, so
# a new dependency cannot ship without THIRD_PARTY_NOTICES.md covering it.
# SHIPPED: code linked into the executable (see THIRD_PARTY_NOTICES.md);
# their LICENSE/NOTICE files are copied into Contents/Resources/Licenses.
SHIPPED_PACKAGES=(
    grpc-swift-2
    grpc-swift-nio-transport
    grpc-swift-protobuf
    swift-asn1
    swift-async-algorithms
    swift-atomics
    swift-certificates
    swift-collections
    swift-crypto
    swift-log
    swift-nio
    swift-nio-extras
    swift-nio-http2
    swift-nio-ssl
    swift-nio-transport-services
    swift-protobuf
    swift-service-lifecycle
    sparkle
)
# BUILD_ONLY: resolved, but only build tools or unlinked modules use them.
BUILD_ONLY_PACKAGES=(
    swift-algorithms
    swift-http-structured-headers
    swift-http-types
    swift-numerics
    swift-system
)
# Shipped packages that vendor BoringSSL, as package:directory. The vendored
# copies leave out BoringSSL's LICENSE, whose OpenSSL, SSLeay and ISC terms
# ask a binary distribution to carry the notices and conditions. The repo
# keeps an unchanged copy per revision in packaging/licenses/boringssl-<rev>/.
VENDORED_BORINGSSL=(
    swift-nio-ssl:Sources/CNIOBoringSSL
    swift-crypto:Sources/CCryptoBoringSSL
)
# "<revision> <Git blob SHA-1 of LICENSE at that revision>", from upstream:
#   gh api "repos/google/boringssl/contents/LICENSE?ref=<revision>" --jq .sha
BORINGSSL_LICENSE_PINS=(
    "817ab07ebb53da35afea409ab9328f578492832d 3aa5aa6911da87a6dd95105c27b0e0aed946970c"
    "0226f30467f540a3f62ef48d453f93927da199b6 37a5b7439bf6d245179326da069fa561e20067ef"
)

usage() {
    cat <<'EOF'
usage: Scripts/package-app.sh [--sign <identity|->] [--dmg | --dmg-only] [--host-arch]
                              [--require-licenses] [--entitlements <plist>]
                              [--appcast-url <https url>] [--sparkle-public-key <base64>]

  --sign <identity>      codesign identity; "-" (the default) signs ad hoc.
                         Distribution needs your "Developer ID Application: ..." identity.
                         A real identity implies --require-licenses.
  --dmg                  also build dist/DeviceHubPro-<version>.dmg
  --dmg-only             only build (and sign) the disk image from the existing
                         dist/Device Hub Pro.app, e.g. after notarizing and stapling the app
  --host-arch            build for this Mac's architecture (default: arm64, the
                         only architecture the app ships for)
  --require-licenses     stop if BoringSSL's LICENSE is missing from packaging/licenses
                         instead of building an app that must stay on this Mac
  --entitlements <plist> sign the app with these entitlements instead of
                         packaging/DeviceHubPro.entitlements (the Camera and the audio
                         input, for the live view of a connected iPhone)
  --appcast-url <url>    the Sparkle feed (SUFeedURL), https only. Default: $DHP_APPCAST_URL.
                         Empty means the app has no updater and no menu item.
  --sparkle-public-key <base64>
                         the EdDSA public key (SUPublicEDKey) printed by Sparkle's
                         generate_keys. Default: $DHP_SPARKLE_PUBLIC_KEY.
EOF
}

die() { printf 'package-app: error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }
warn() { printf 'package-app: note: %s\n' "$*" >&2; }

# Runs a command that warns about the code signature it invalidates (the app
# is signed at the end), showing its output only when it fails.
quietly() {
    local output
    if ! output="$("$@" 2>&1)"; then
        printf '%s\n' "$output" >&2
        die "$* failed"
    fi
}

contains() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

sign_identity="-"
make_dmg=0
dmg_only=0
arch_mode="arm64"
entitlements=""
require_licenses=0
appcast_url="${DHP_APPCAST_URL:-}"
help_url="${DHP_HELP_URL:-}"
sparkle_public_key="${DHP_SPARKLE_PUBLIC_KEY:-}"

while (($#)); do
    case "$1" in
        --sign)
            [[ $# -ge 2 && -n "$2" ]] || die "--sign needs an identity (or - for ad hoc)"
            sign_identity="$2"
            shift 2
            ;;
        --dmg)
            make_dmg=1
            shift
            ;;
        --dmg-only)
            make_dmg=1
            dmg_only=1
            shift
            ;;
        --host-arch)
            arch_mode="host"
            shift
            ;;
        --require-licenses)
            require_licenses=1
            shift
            ;;
        --entitlements)
            [[ $# -ge 2 && -f "$2" ]] || die "--entitlements needs an existing plist"
            entitlements="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
            shift 2
            ;;
        --appcast-url)
            [[ $# -ge 2 ]] || die "--appcast-url needs a URL"
            appcast_url="$2"
            shift 2
            ;;
        --sparkle-public-key)
            [[ $# -ge 2 ]] || die "--sparkle-public-key needs a base64 key"
            sparkle_public_key="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
done
if [[ -n "$appcast_url" && ! "$appcast_url" =~ ^https://[^/[:space:]]+ ]]; then
    die "the appcast URL must be https, found '$appcast_url'"
fi
if [[ -n "$appcast_url" && -z "$sparkle_public_key" ]] || [[ -z "$appcast_url" && -n "$sparkle_public_key" ]]; then
    die "the updater needs both the appcast URL and the Sparkle public key (or neither)"
fi
if [[ -n "$sparkle_public_key" && ! "$sparkle_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    die "the Sparkle public key must be the 44-character base64 string generate_keys prints"
fi
# A real identity means the build is meant for other people.
if [[ "$sign_identity" != "-" ]]; then
    require_licenses=1
fi

# codesign cannot find an identity by a name with non-ASCII letters (a
# "Developer ID Application: Ad Öz…" is "no identity found"; established against
# Xcode 27.0), so a name is turned into its certificate's SHA-1 here and codesign
# gets the hash. Messages keep the name.
codesign_identity="$sign_identity"
if [[ "$sign_identity" != "-" && ! "$sign_identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    codesign_identity="$(security find-identity -v -p codesigning \
        | awk -v name="\"$sign_identity\"" 'index($0, name) { print $2; exit }')"
    [[ -n "$codesign_identity" ]] \
        || die "no valid signing identity named '$sign_identity' in the keychain (security find-identity -v -p codesigning lists them)"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "$entitlements" ]]; then
    entitlements="$repo_root/packaging/DeviceHubPro.entitlements"
fi
cd "$repo_root"

dist="$repo_root/dist"
app="$dist/$APP_NAME.app"
contents="$app/Contents"
resources="$contents/Resources"
executable="$contents/MacOS/$EXEC_NAME"
checkouts="$repo_root/.build/checkouts"

version="$(tr -d '[:space:]' < VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must hold X.Y.Z, found '$version'"
if build_number="$(git rev-list --count HEAD 2>/dev/null)"; then
    if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
        warn "shallow clone: CFBundleVersion ($build_number) counts only the fetched commits; fetch the full history for release builds"
    fi
else
    build_number="0"
    warn "not a git checkout; CFBundleVersion is 0"
fi

check_license_coverage() {
    local pin_count identity i
    pin_count="$(plutil -extract pins raw -o - Package.resolved)"
    for ((i = 0; i < pin_count; i++)); do
        identity="$(plutil -extract "pins.$i.identity" raw -o - Package.resolved)"
        if ! contains "$identity" "${SHIPPED_PACKAGES[@]}" && ! contains "$identity" "${BUILD_ONLY_PACKAGES[@]}"; then
            die "Package.resolved lists '$identity', which Scripts/package-app.sh does not classify. Check whether it is linked, then add it to SHIPPED_PACKAGES (and THIRD_PARTY_NOTICES.md) or BUILD_ONLY_PACKAGES."
        fi
    done
}

# Git's blob hash of a file (what the GitHub API reports as "sha"), without
# needing a git checkout.
git_blob_hash() {
    { printf 'blob %s\0' "$(wc -c < "$1" | tr -d ' ')"; cat "$1"; } | shasum -a 1 | cut -d ' ' -f 1
}

# Checks, before the long build, that packaging/licenses holds BoringSSL's
# unchanged LICENSE for every vendored revision, and records the verified
# files in boringssl_licenses as package:path for copy_licenses.
#   - A file whose Git blob hash differs from the pin always stops the script.
#   - A missing file, or a revision without a pin, stops it when
#     require_licenses is set (--require-licenses, or a real --sign identity).
#     Otherwise the build goes on without that file: missing_license_fixes
#     keeps the commands that add it, and warn_missing_licenses repeats them
#     at the end.
check_boringssl_licenses() {
    local entry package hash_file revision license pin expected actual wrong=""
    # The checkouts must match Package.resolved before their hash.txt is read.
    quietly swift package resolve
    boringssl_licenses=()
    missing_license_fixes=""
    for entry in "${VENDORED_BORINGSSL[@]}"; do
        package="${entry%%:*}"
        hash_file="$checkouts/$package/${entry#*:}/hash.txt"
        [[ -f "$hash_file" ]] || die "$hash_file is missing, so the BoringSSL revision that $package vendors is unknown. Update VENDORED_BORINGSSL."
        revision="$(grep -Eo '[0-9a-f]{40}' "$hash_file" | sed -n 1p)"
        [[ -n "$revision" ]] || die "no BoringSSL revision in $hash_file"
        license="packaging/licenses/boringssl-$revision/LICENSE"
        expected=""
        for pin in "${BORINGSSL_LICENSE_PINS[@]}"; do
            if [[ "${pin%% *}" == "$revision" ]]; then
                expected="${pin#* }"
            fi
        done
        if [[ -z "$expected" ]]; then
            missing_license_fixes+=$'\n'"  BORINGSSL_LICENSE_PINS has no hash for revision $revision ($package). Add \"$revision <sha>\" with the sha from:"
            missing_license_fixes+=$'\n'"    gh api \"repos/google/boringssl/contents/LICENSE?ref=$revision\" --jq .sha"
        fi
        if [[ ! -f "$license" ]]; then
            missing_license_fixes+=$'\n'"  $package vendors BoringSSL $revision, but $license is missing. Fetch it unchanged and commit it:"
            missing_license_fixes+=$'\n'"    curl -fsSL --create-dirs -o $license https://raw.githubusercontent.com/google/boringssl/$revision/LICENSE"
        elif [[ -n "$expected" ]]; then
            actual="$(git_blob_hash "$license")"
            if [[ "$actual" == "$expected" ]]; then
                boringssl_licenses+=("$package:$license")
            else
                wrong+=$'\n'"  $license is not BoringSSL's LICENSE at $revision: its Git blob hash is $actual, upstream's is $expected. Fetch it again with:"
                wrong+=$'\n'"    curl -fsSL -o $license https://raw.githubusercontent.com/google/boringssl/$revision/LICENSE"
            fi
        fi
    done
    [[ -z "$wrong" ]] || die "packaging/licenses holds a file that is not BoringSSL's LICENSE. From $repo_root:$wrong$missing_license_fixes"
    if [[ -n "$missing_license_fixes" ]]; then
        if ((require_licenses)); then
            die "BoringSSL's license text must ship with a build for other people (THIRD_PARTY_NOTICES.md). From $repo_root:$missing_license_fixes"
        fi
        warn_missing_licenses
    fi
}

# Prints the packages whose BoringSSL-LICENSE the assembled app lacks.
missing_app_licenses() {
    local entry package missing=""
    for entry in "${VENDORED_BORINGSSL[@]}"; do
        package="${entry%%:*}"
        if [[ ! -f "$resources/Licenses/$package/BoringSSL-LICENSE" ]]; then
            missing+="${missing:+ }$package"
        fi
    done
    printf '%s' "$missing"
}

warn_missing_licenses() {
    local line
    {
        printf '\n'
        for line in \
            "WARNING: packaging/licenses has no verified copy of BoringSSL's LICENSE, so this" \
            "build lacks license text that THIRD_PARTY_NOTICES.md says the app ships. Keep the" \
            "app and its disk image on this Mac: do not give them to anyone. Builds for other" \
            "people (--sign with a real identity, --require-licenses, release.yml) stop instead."; do
            printf '!!! %s\n' "$line"
        done
        if [[ -n "${missing_license_fixes:-}" ]]; then
            printf '!!! To fix it, from %s:%s\n\n' "$repo_root" "$missing_license_fixes"
        else
            printf '!!! To see how to fix it, run Scripts/package-app.sh without --dmg-only.\n\n'
        fi
    } >&2
}

build_release() {
    build_args=(-c release)
    # Swift Build explicitly: a release build from the deprecated native build
    # system aborted at launch in testing ("freed pointer was not the last
    # allocation" in swift_task_dealloc, under ProcessRunner.run's Task.sleep).
    # The cause was a toolchain bug that merged mismatched weak async copies
    # across modules. It is worked around in code (docs/native-build-async-odr.md),
    # but only Swift Build keeps each module's copies private.
    local help_text
    help_text="$(swift build --help 2>/dev/null || true)"
    if [[ "$help_text" == *swiftbuild* ]]; then
        build_args+=(--build-system swiftbuild)
    else
        warn "this toolchain has no Swift Build backend; check the native release build with Scripts/check-async-odr.sh (docs/native-build-async-odr.md)"
    fi
    # The vendored BoringSSL copies embed __FILE__ in their error paths, which
    # would put the builder's checkout path (and user name) into the binary.
    # Only those two packages are mapped: a wider map also rewrites the
    # include path of the protoc that the build compiles and runs, and the
    # module-cache paths under .build that dsymutil then misses.
    local vendored_c
    for vendored_c in swift-nio-ssl swift-crypto; do
        build_args+=(-Xcc "-ffile-prefix-map=$repo_root/.build/checkouts/$vendored_c=$vendored_c")
    done
    # Apple silicon only: macOS 26 is the last release for Intel
    # Macs, and the Intel slice could not be tested.
    if [[ "$arch_mode" == "arm64" ]]; then
        note "Building $APP_NAME $version ($build_number) for arm64"
        build_args+=(--arch arm64)
        swift build "${build_args[@]}"
    else
        note "Building $APP_NAME $version ($build_number) for $(uname -m)"
        swift build "${build_args[@]}"
    fi
    bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
    [[ -x "$bin_dir/$EXEC_NAME" ]] || die "no $EXEC_NAME executable in $bin_dir"
}

copy_licenses() {
    local licenses="$resources/Licenses" package source_dir file copied entry
    mkdir -p "$licenses/$APP_NAME" "$licenses/scrcpy"
    cp LICENSE "$licenses/$APP_NAME/LICENSE"
    cp THIRD_PARTY_NOTICES.md "$licenses/THIRD_PARTY_NOTICES.md"
    cp Sources/DeviceHubProKit/Scrcpy/Resources/LICENSE.scrcpy "$licenses/scrcpy/LICENSE"
    [[ -d "$checkouts" ]] || die "no package checkouts in $checkouts (run swift package resolve)"
    for package in "${SHIPPED_PACKAGES[@]}"; do
        source_dir="$checkouts/$package"
        if [[ ! -d "$source_dir" ]]; then
            # SwiftPM names a checkout after the repository (Sparkle); the
            # package identity is lowercase.
            source_dir="$(find "$checkouts" -maxdepth 1 -iname "$package" -type d -print -quit)"
        fi
        [[ -d "$source_dir" ]] || die "missing checkout $checkouts/$package"
        mkdir -p "$licenses/$package"
        copied=0
        for file in "$source_dir"/LICENSE* "$source_dir"/NOTICE*; do
            if [[ -f "$file" ]]; then
                cp "$file" "$licenses/$package/"
                copied=1
            fi
        done
        ((copied)) || die "$source_dir has no LICENSE file"
    done
    cp "$checkouts/swift-nio/Sources/CNIOLLHTTP/LICENSE" "$licenses/swift-nio/llhttp-LICENSE"
    cp "$checkouts/swift-protobuf/Sources/protobuf/protobuf/LICENSE" "$licenses/swift-protobuf/google-protobuf-LICENSE"
    # Verified by check_boringssl_licenses before the build. The array can be
    # empty, and bash 3.2 calls an empty "${array[@]}" unbound under set -u.
    if ((${#boringssl_licenses[@]} > 0)); then
        for entry in "${boringssl_licenses[@]}"; do
            cp "${entry#*:}" "$licenses/${entry%%:*}/BoringSSL-LICENSE"
        done
    fi
}

# Sparkle.framework from the package's binary artifact (the xcframework's
# macOS slice, universal), copied with symlinks intact into
# Contents/Frameworks, and the executable gets an rpath to it. The framework
# is signed in sign_app.
embed_sparkle() {
    local source_framework
    source_framework="$(find "$repo_root/.build/artifacts" -path '*Sparkle.xcframework/macos-*/Sparkle.framework' -type d -print -quit 2>/dev/null)"
    [[ -n "$source_framework" ]] || die "Sparkle.framework is not in .build/artifacts (run swift package resolve)"
    mkdir -p "$contents/Frameworks"
    ditto "$source_framework" "$contents/Frameworks/Sparkle.framework"
    [[ -x "$contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]] || die "the copied Sparkle.framework has no Sparkle binary"
    if ! otool -l "$executable" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }' | grep -qx '@executable_path/../Frameworks'; then
        quietly install_name_tool -add_rpath @executable_path/../Frameworks "$executable"
    fi
    if [[ -z "$appcast_url" ]]; then
        warn "no appcast URL: this build has no updater and no Check for Updates item (--appcast-url, docs/distribution.md)"
    fi
}

assemble_app() {
    note "Assembling $app"
    rm -rf "$app"
    mkdir -p "$contents/MacOS" "$resources"

    cp "$bin_dir/$EXEC_NAME" "$executable"
    # Debug and local symbols double the executable; the dSYM beside the app
    # (same UUID) keeps crash reports symbolicatable.
    quietly strip -S -x "$executable"
    rm -rf "$dist/$EXEC_NAME-$version.dSYM"
    if [[ -d "$bin_dir/$EXEC_NAME.dSYM" ]]; then
        ditto "$bin_dir/$EXEC_NAME.dSYM" "$dist/$EXEC_NAME-$version.dSYM"
    fi

    # SwiftPM resource bundles: ours (scrcpy server, language helper, shader) and the privacy
    # manifests of dependencies. ResourceBundleLookup reads ours from here.
    local bundles bundle required bundle_name file_name
    shopt -s nullglob
    bundles=("$bin_dir"/*.bundle)
    shopt -u nullglob
    ((${#bundles[@]} > 0)) || die "no resource bundles in $bin_dir"
    for bundle in "${bundles[@]}"; do
        ditto "$bundle" "$resources/$(basename "$bundle")"
    done
    for required in "${EXEC_NAME}_DeviceHubProKit.bundle:scrcpy-server" "${EXEC_NAME}_DeviceHubProKit.bundle:devicehubpro-locales.dex" "${EXEC_NAME}_DeviceHubProApp.bundle:Shaders.metal"; do
        bundle_name="${required%%:*}"
        file_name="${required#*:}"
        [[ -n "$(find "$resources/$bundle_name" -name "$file_name" -type f -print -quit 2>/dev/null)" ]] \
            || die "$file_name is missing from $bundle_name"
    done

    # The fast input helper's sources (built into the user's cache on first use).
    mkdir -p "$resources/fastinput"
    ditto fastinput/Sources "$resources/fastinput/Sources"
    cp fastinput/build.sh fastinput/LICENSE fastinput/PROVENANCE.md "$resources/fastinput/"
    [[ -f "$resources/fastinput/build.sh" ]] || die "fastinput/build.sh is missing from the bundle"

    embed_sparkle

    cp packaging/Info.plist "$contents/Info.plist"
    plutil -replace SUFeedURL -string "$appcast_url" "$contents/Info.plist"
    # Help ▸ Device Hub Pro Help opens this page (the project's README); empty hides the item.
    plutil -replace DeviceHubProHelpURL -string "$help_url" "$contents/Info.plist"
    plutil -replace SUPublicEDKey -string "$sparkle_public_key" "$contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string "$version" "$contents/Info.plist"
    plutil -replace CFBundleVersion -string "$build_number" "$contents/Info.plist"
    plutil -lint -s "$contents/Info.plist"
    printf 'APPL????' > "$contents/PkgInfo"

    cp packaging/AppIcon.icns "$resources/AppIcon.icns"

    note "Generating Credits.rtf from THIRD_PARTY_NOTICES.md"
    swift Scripts/make-credits.swift THIRD_PARTY_NOTICES.md "$resources/Credits.rtf"

    copy_licenses
}

# True when two versions are the same: 26, 26.0 and 26.0.0 are.
same_version() {
    [[ "$(sed -E 's/(\.0+)+$//' <<< "$1")" == "$(sed -E 's/(\.0+)+$//' <<< "$2")" ]]
}

# The minimum macOS is written three times, and all three must agree:
# - `platforms` in Package.swift. Every module is compiled for it, so the
#   code treats that macOS's APIs as always there.
# - The first number of the app's -platform_version flag in Package.swift.
#   ld writes it into LC_BUILD_VERSION (minos), which dyld checks. It wins
#   over `platforms` at link time: with `platforms` raised alone, ld only
#   warns ("object file ... was built for newer 'macOS' version (26.4) than
#   being linked (26.0)"), and the app claims a macOS it may crash on.
# - LSMinimumSystemVersion in packaging/Info.plist, which Finder checks
#   before it starts the app. A lower value lets an older macOS start an app
#   that dyld then refuses; a higher one keeps the app off Macs it runs on.
# Tests/DeviceHubProKitTests/DeploymentTargetTests.swift checks the same three
# in `swift test`; this checks the executable that ships.
check_minimum_system_version() {
    local declared manifest index name platforms="" arch linked
    declared="$(plutil -extract LSMinimumSystemVersion raw -o - "$contents/Info.plist")"
    manifest="$(swift package dump-package)" || die "swift package dump-package failed"
    index=0
    while name="$(plutil -extract "platforms.$index.platformName" raw -o - - <<< "$manifest" 2>/dev/null)"; do
        if [[ "$name" == macos ]]; then
            platforms="$(plutil -extract "platforms.$index.version" raw -o - - <<< "$manifest")"
            break
        fi
        index=$((index + 1))
    done
    [[ -n "$platforms" ]] || die "Package.swift names no macOS version in platforms"
    same_version "$platforms" "$declared" \
        || die "packaging/Info.plist declares LSMinimumSystemVersion $declared, but Package.swift's platforms says macOS $platforms. Make them match."
    for arch in $(lipo -archs "$executable"); do
        linked="$(otool -arch "$arch" -l "$executable" | awk '$1 == "cmd" { build = ($2 == "LC_BUILD_VERSION") } build && $1 == "minos" { print $2; exit }')"
        same_version "$linked" "$declared" \
            || die "packaging/Info.plist declares LSMinimumSystemVersion $declared, but the $arch executable is linked for macOS ${linked:-?} (the first number of -platform_version in Package.swift). Make them match."
    done
}

# At the macOS 26 deployment target the executable uses only the Swift runtime
# in the system's /usr/lib/swift. The macOS 15 build also linked the
# back-deployment library @rpath/libswiftCompatibilitySpan.dylib, and this
# script bundled it in Contents/Frameworks; the toolchain's back-deployment
# libraries (lib/swift-5.0, swift-5.5, swift-6.2) all serve targets below
# macOS 26, and otool -L of the macOS 26 build lists none (Swift 6.4, macOS 27
# SDK). A toolchain that links one again stops the script: shipping it needs
# Contents/Frameworks, an rpath to it, its own signature (see the hardened
# runtime note at the top) and a THIRD_PARTY_NOTICES.md entry.
#
# rpaths: drop absolute paths on the build machine, which would name the
# builder's folders and mean nothing on another Mac; keep /usr/lib/swift and
# @-relative ones. At macOS 26 the release builds (Swift Build and native)
# carry only @loader_path, but a debug build adds SwiftPM's absolute
# PackageFrameworks folder, so a changed build setup can bring such paths in.
check_swift_runtime() {
    local references existing_rpaths rpath
    references="$(otool -L "$executable" | awk '/@rpath\/libswift/ { print $1 }' | sort -u)"
    if [[ -n "$references" ]]; then
        die "the executable links Swift back-deployment libraries, which the deployment target's macOS does not ship: $(paste -sd ' ' - <<< "$references"). Bundle them in Contents/Frameworks (git log -S embed_swift_runtime -- Scripts/package-app.sh finds the removed step) or raise the deployment target."
    fi

    existing_rpaths="$(otool -l "$executable" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }' | sort -u)"
    while read -r rpath; do
        case "$rpath" in
            "" | /usr/lib/swift | @*) ;;
            /*) quietly install_name_tool -delete_rpath "$rpath" "$executable" ;;
        esac
    done <<< "$existing_rpaths"
}

# Sets the codesign flags (macOS ships bash 3.2: no mapfile): sign_flags for
# resource bundles and the disk image, code_sign_flags for the app. Only a
# real identity gets the hardened runtime (see the top).
set_sign_flags() {
    if [[ "$sign_identity" == "-" ]]; then
        sign_flags=(--force --sign - --timestamp=none)
        code_sign_flags=("${sign_flags[@]}")
    else
        sign_flags=(--force --sign "$codesign_identity" --timestamp)
        code_sign_flags=("${sign_flags[@]}" --options runtime)
    fi
}

sign_app() {
    local bundle app_flags
    set_sign_flags
    if [[ "$sign_identity" == "-" ]]; then
        note "Signing ad hoc, without the hardened runtime (not for distribution: Gatekeeper rejects ad-hoc apps downloaded from the internet)"
    else
        note "Signing with '$sign_identity' and the hardened runtime"
    fi
    # Inside out: nested code first, the app last. Sparkle's documented order:
    # the XPC services, the Autoupdate helper, Updater.app, then the framework.
    # Never --deep: it would re-sign them with the wrong flags and drop the
    # Downloader's entitlements.
    local sparkle="$contents/Frameworks/Sparkle.framework" xpc
    local sparkle_b="$sparkle/Versions/B"
    if [[ -d "$sparkle" ]]; then
        shopt -s nullglob
        for xpc in "$sparkle_b"/XPCServices/*.xpc; do
            codesign "${code_sign_flags[@]}" --preserve-metadata=entitlements "$xpc"
        done
        shopt -u nullglob
        codesign "${code_sign_flags[@]}" "$sparkle_b/Autoupdate"
        codesign "${code_sign_flags[@]}" "$sparkle_b/Updater.app"
        codesign "${code_sign_flags[@]}" "$sparkle"
    fi
    shopt -s nullglob
    for bundle in "$resources"/*.bundle; do
        # A flat bundle (no Contents/Info.plist, as the native build system
        # makes them) cannot be signed; the app's resource seal covers it.
        if [[ -f "$bundle/Contents/Info.plist" ]]; then
            codesign "${sign_flags[@]}" "$bundle"
        fi
    done
    shopt -u nullglob
    app_flags=("${code_sign_flags[@]}")
    if [[ -n "$entitlements" ]]; then
        app_flags+=(--entitlements "$entitlements")
    fi
    codesign "${app_flags[@]}" "$app"
    codesign --verify --deep --strict --verbose=2 "$app"
}

# Builds the disk image with dmgbuild (Scripts/dmg-settings.py, pinned by hash in
# packaging/dmg/requirements.txt, installed once into .build/dmgbuild-venv).
# Returns non-zero, after a warning, when Python or dmgbuild is unavailable.
styled_disk_image() {
    local venv="$repo_root/.build/dmgbuild-venv"
    if [[ ! -x "$venv/bin/dmgbuild" ]]; then
        command -v python3 >/dev/null || { warn "no python3: the disk image will be plain"; return 1; }
        rm -rf "$venv"
        if ! python3 -m venv "$venv" >/dev/null \
            || ! "$venv/bin/pip" install -q --disable-pip-version-check --require-hashes \
                -r "$repo_root/packaging/dmg/requirements.txt" >/dev/null; then
            warn "could not install dmgbuild: the disk image will be plain"
            rm -rf "$venv"
            return 1
        fi
    fi
    if ! "$venv/bin/dmgbuild" -s "$repo_root/Scripts/dmg-settings.py" \
        -D app="$app" -D background="$repo_root/packaging/dmg/background.tiff" \
        "$APP_NAME $version" "$dmg" >/dev/null; then
        warn "dmgbuild failed: the disk image will be plain"
        rm -f "$dmg"
        return 1
    fi
}

make_disk_image() {
    local staging
    dmg_style="plain"
    dmg="$dist/$EXEC_NAME-$version.dmg"
    note "Creating $dmg"
    staging="$(mktemp -d "${TMPDIR:-/tmp}/devicehubpro-dmg.XXXXXX")"
    # shellcheck disable=SC2064 # expand now: $staging is local
    trap "rm -rf '$staging'" EXIT
    ditto "$app" "$staging/$APP_NAME.app"
    ln -s /Applications "$staging/Applications"
    rm -f "$dmg"
    # The styled window (background, icon positions, no toolbar) comes from
    # dmgbuild, which writes the layout itself: no Finder scripting, so no
    # Automation prompt, on a Mac or in CI. Without it the image is plain.
    if styled_disk_image; then
        dmg_style="styled"
    elif ! hdiutil create -quiet -volname "$APP_NAME $version" -srcfolder "$staging" \
        -fs HFS+ -format UDZO -ov "$dmg" 2>/dev/null; then
        # hdiutil create -srcfolder fails on some macOS builds ("create
        # failed - Resource busy") even for a tiny folder; diskutil's
        # replacement makes an equivalent compressed image (APFS volume).
        warn "hdiutil create failed; making the disk image with diskutil image create"
        rm -f "$dmg"
        diskutil image create from --format UDZO --volumeName "$APP_NAME $version" "$staging" "$dmg" >/dev/null \
            || die "neither hdiutil nor diskutil could create $dmg"
    fi
    if [[ "$sign_identity" != "-" ]]; then
        set_sign_flags
        codesign "${sign_flags[@]}" "$dmg"
    fi
    hdiutil verify -quiet "$dmg"
}

dmg=""
if ((dmg_only)); then
    [[ -d "$app" ]] || die "--dmg-only needs an existing $app (run without --dmg-only first)"
    codesign --verify --deep --strict "$app" || die "$app fails codesign --verify --deep --strict"
    if ((require_licenses)) && [[ -n "$(missing_app_licenses)" ]]; then
        die "$app has no BoringSSL-LICENSE for $(missing_app_licenses); rebuild it without --dmg-only after adding packaging/licenses (docs/distribution.md, \"BoringSSL's license\")"
    fi
    # Name the image after the app it holds, not after VERSION.
    version="$(plutil -extract CFBundleShortVersionString raw -o - "$contents/Info.plist")"
    build_number="$(plutil -extract CFBundleVersion raw -o - "$contents/Info.plist")"
else
    check_license_coverage
    check_boringssl_licenses
    build_release
    assemble_app
    check_minimum_system_version
    check_swift_runtime
    sign_app
fi
if ((make_dmg)); then
    make_disk_image
fi

printf '\n%s %s (%s)\n' "$APP_NAME" "$version" "$build_number"
printf '  app:           %s\n' "$app"
printf '  architectures: %s\n' "$(lipo -archs "$executable")"
if [[ -n "$(plutil -extract SUFeedURL raw -o - "$contents/Info.plist" 2>/dev/null)" ]]; then
    printf '  updater:       %s\n' "$(plutil -extract SUFeedURL raw -o - "$contents/Info.plist")"
else
    printf '  updater:       off (no appcast URL)\n'
fi
signature="$(codesign -dv --verbose=2 "$app" 2>&1 || true)"
printf '  signature:     %s\n' "$(awk -F= '/^Authority=/ { print $2; exit } /^Signature=adhoc/ { print "ad hoc"; exit }' <<< "$signature")"
if grep -q '^CodeDirectory .*flags=[^ ]*runtime' <<< "$signature"; then
    printf '  runtime:       hardened\n'
else
    printf '  runtime:       not hardened\n'
fi
missing_licenses="$(missing_app_licenses)"
if [[ -z "$missing_licenses" ]]; then
    printf '  licenses:      complete\n'
else
    printf '  licenses:      INCOMPLETE, no BoringSSL-LICENSE for %s (keep this build on this Mac)\n' "$missing_licenses"
fi
if [[ -n "$dmg" ]]; then
    printf "  disk image:    %s (%s window)\n" "$dmg" "$dmg_style"
fi
if [[ -n "$missing_licenses" ]]; then
    warn_missing_licenses
fi
if [[ "$sign_identity" != "-" ]]; then
    printf '\nNext: Scripts/notarize.sh %s\n' "${dmg:-$app}"
fi
