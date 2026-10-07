#!/usr/bin/env bash
# Notarizes a Developer ID-signed Device Hub Pro.app or disk image with Apple's
# notary service, staples the ticket, and checks the result with Gatekeeper.
# docs/distribution.md has the whole release flow.
#
#   Scripts/notarize.sh dist/DeviceHubPro-1.0.0.dmg
#   Scripts/notarize.sh --profile my-profile dist/Device Hub Pro.app
#   Scripts/notarize.sh --print-setup          # the one-time credential step
#
# It needs a notarytool keychain profile. Create it once, yourself, with the
# command --print-setup prints; this script never creates or reads
# credentials. NOTARY_PROFILE picks the profile (default devicehubpro-notary) and
# NOTARY_KEYCHAIN a keychain other than the default search list (CI).

set -euo pipefail

profile="${NOTARY_PROFILE:-devicehubpro-notary}"
keychain="${NOTARY_KEYCHAIN:-}"

die() { printf 'notarize: error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

print_setup() {
    cat <<EOF
One-time setup (run it yourself; notarytool asks for the password and stores
it in your login keychain):

  xcrun notarytool store-credentials "$profile" \\
      --apple-id "<your Apple ID email>" \\
      --team-id "<your 10-character Team ID>"

Use an app-specific password from https://account.apple.com (Sign-In and
Security > App-Specific Passwords), not your Apple ID password. An App Store
Connect API key works too: pass --key <AuthKey_XXXX.p8> --key-id <id>
--issuer <uuid> instead of --apple-id/--team-id.
EOF
}

usage() {
    cat <<'EOF'
usage: Scripts/notarize.sh [--profile <keychain-profile>] <Device Hub Pro.app | DeviceHubPro-x.y.z.dmg>
       Scripts/notarize.sh --print-setup
EOF
}

target=""
while (($#)); do
    case "$1" in
        --profile)
            [[ $# -ge 2 && -n "$2" ]] || die "--profile needs a name"
            profile="$2"
            shift 2
            ;;
        --print-setup)
            print_setup
            exit 0
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            die "unknown option: $1"
            ;;
        *)
            [[ -z "$target" ]] || die "one target at a time"
            target="${1%/}"
            shift
            ;;
    esac
done
[[ -n "$target" ]] || { usage >&2; exit 64; }
[[ -e "$target" ]] || die "$target does not exist"

case "$target" in
    *.app) kind="app" ;;
    *.dmg) kind="dmg" ;;
    *) die "expected an .app or a .dmg, got $target" ;;
esac

# --- Preflight: the notary service rejects anything below -----------------

signature_details="$(codesign -dvv "$target" 2>&1)" || die "$target is not signed; run Scripts/package-app.sh --sign \"Developer ID Application: ...\""
if ! grep -q '^Authority=Developer ID Application:' <<< "$signature_details"; then
    if grep -q '^Signature=adhoc' <<< "$signature_details"; then
        die "$target is signed ad hoc; notarization needs a Developer ID Application signature (Scripts/package-app.sh --sign \"Developer ID Application: ...\")"
    fi
    die "$target is not signed with a Developer ID Application certificate"
fi
grep -q '^Timestamp=' <<< "$signature_details" \
    || die "$target has no secure timestamp; sign with --timestamp (package-app.sh does for real identities)"

# The notary service rejects the whole submission when any nested code (the
# Sparkle framework's XPC services, Autoupdate helper and Updater app, or any
# other Mach-O under Contents/Frameworks) lacks a Developer ID signature, the
# hardened runtime or a secure timestamp. Check each one here, so the failure
# names the file before the upload instead of in Apple's log after it.
check_nested_code() {
    local app="$1" code details bad=0 count=0
    while IFS= read -r code; do
        count=$((count + 1))
        details="$(codesign -dvv "$code" 2>&1)" || { printf 'notarize: %s is not signed\n' "$code" >&2; bad=1; continue; }
        if ! grep -q '^Authority=Developer ID Application:' <<< "$details"; then
            printf 'notarize: %s is not signed with a Developer ID Application certificate\n' "$code" >&2; bad=1
        fi
        if ! grep -q '^Timestamp=' <<< "$details"; then
            printf 'notarize: %s has no secure timestamp\n' "$code" >&2; bad=1
        fi
        if ! grep -q 'flags=.*runtime' <<< "$details"; then
            printf 'notarize: %s lacks the hardened runtime\n' "$code" >&2; bad=1
        fi
    done < <(find "$app/Contents/Frameworks" \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' -o -name Autoupdate \) -not -type l -not -path '*/Versions/Current/*')
    ((bad == 0)) || die "nested code in $app would be rejected by the notary service (re-run Scripts/package-app.sh --sign ...)"
    note "Checked $count nested code item(s) under Contents/Frameworks"
}

if [[ "$kind" == "app" ]]; then
    codesign --verify --deep --strict "$target" || die "$target fails codesign --verify --deep --strict"
    grep -q 'flags=.*runtime' <<< "$signature_details" \
        || die "$target is not signed with the hardened runtime (--options runtime)"
    check_nested_code "$target"
else
    codesign --verify --strict "$target" || die "$target fails codesign --verify --strict"
fi


notary_auth=(--keychain-profile "$profile")
if [[ -n "$keychain" ]]; then
    notary_auth+=(--keychain "$keychain")
fi

# --- Submit -----------------------------------------------------------------

work="$(mktemp -d "${TMPDIR:-/tmp}/devicehubpro-notarize.XXXXXX")"
mount_point=""
cleanup() {
    if [[ -n "$mount_point" ]]; then
        hdiutil detach -quiet "$mount_point" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

if [[ "$kind" == "dmg" ]]; then
    # The image holds the app: check its nested code the same way.
    mount_point="$work/mount"
    mkdir -p "$mount_point"
    if hdiutil attach -quiet -readonly -nobrowse -noverify -mountpoint "$mount_point" "$target"; then
        if [[ -d "$mount_point/Device Hub Pro.app" ]]; then
            check_nested_code "$mount_point/Device Hub Pro.app"
        fi
        hdiutil detach -quiet "$mount_point" && mount_point=""
    else
        mount_point=""
        die "could not mount $target to check the app inside"
    fi
fi

upload="$target"
if [[ "$kind" == "app" ]]; then
    # notarytool takes a zip, pkg or dmg; the ticket is stapled to the app.
    upload="$work/$(basename "$target" .app).zip"
    ditto -c -k --keepParent "$target" "$upload"
fi

note "Submitting $(basename "$upload") with profile '$profile' (this waits for Apple's verdict)"
result="$work/submission.plist"
# notarytool's exit code for a rejected (Invalid) submission is not
# documented, so the verdict is read from its output either way, and Apple's
# log is fetched whenever a submission exists and was not accepted.
submit_exit=0
xcrun notarytool submit "$upload" "${notary_auth[@]}" --wait --output-format plist > "$result" || submit_exit=$?
status="$(plutil -extract status raw -o - "$result" 2>/dev/null || echo unknown)"
submission_id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
if [[ -n "$submission_id" ]]; then
    note "Submission $submission_id: $status"
fi
if [[ "$status" != "Accepted" ]]; then
    if [[ -n "$submission_id" ]]; then
        note "Apple's log for submission $submission_id"
        xcrun notarytool log "$submission_id" "${notary_auth[@]}" >&2 \
            || printf 'notarize: could not fetch the log; run: xcrun notarytool log %s --keychain-profile %s\n' "$submission_id" "$profile" >&2
        die "notarization was not accepted ($status)"
    fi
    cat "$result" >&2 || true
    die "notarytool submit failed (exit $submit_exit) before Apple returned a verdict; see above (--print-setup shows the credential step)"
fi

# --- Staple and check -------------------------------------------------------

note "Stapling the ticket to $target"
xcrun stapler staple "$target"
xcrun stapler validate "$target"

note "Gatekeeper assessment"
if [[ "$kind" == "app" ]]; then
    spctl --assess --type execute --verbose=4 "$target"
else
    spctl --assess --type open --context context:primary-signature --verbose=4 "$target"
fi
note "$target is notarized and stapled"
