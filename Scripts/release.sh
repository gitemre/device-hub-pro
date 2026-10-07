#!/usr/bin/env bash
# Builds, signs, notarizes and stages a release of Device Hub Pro, and prints the
# `gh release create` command that publishes it (it never runs it).
# docs/distribution.md ("First release checklist") has the one-time setup.
#
#   Scripts/release.sh                     # the release for VERSION (tag vX.Y.Z on HEAD)
#   Scripts/release.sh --dry-run           # everything except Apple: ad-hoc signed, no
#                                          # notarization, a throwaway Sparkle key
#   Scripts/release.sh --dry-run --host-arch   # same, faster (this Mac's architecture only)
#
# What a real run does, in order:
#   1. checks VERSION, the tag, a clean tree, the CHANGELOG section, the
#      Developer ID identity, the notary profile and the two Sparkle settings;
#   2. builds the app (Apple silicon) and signs it (Developer ID, hardened runtime,
#      Sparkle signed inside out), notarizes and staples the app;
#   3. makes the disk image from the stapled app, notarizes and staples it;
#   4. signs the disk image with the Sparkle EdDSA key (sign_update);
#   5. writes dist/appcast.xml (one item: this release, with the CHANGELOG
#      section as its notes), dist/release-notes-X.Y.Z.md and the SHA-256;
#   6. checks the staged files and prints the gh command.
#
# Settings (environment, or the flag next to it):
#   DHP_SIGN_IDENTITY      --identity   "Developer ID Application: Name (TEAMID)"
#   DHP_APPCAST_URL        --appcast-url   the feed the app checks, https
#   DHP_SPARKLE_PUBLIC_KEY --sparkle-public-key   from Sparkle's generate_keys
#   SPARKLE_PRIVATE_KEY         the key `generate_keys -x` exports (CI); unset means
#                               sign_update reads it from the login keychain
#   DHP_DOWNLOAD_BASE_URL  where the disk image will be served, without the
#                               file name. Default: derived from a GitHub
#                               .../releases/latest/download/appcast.xml feed as
#                               .../releases/download/vX.Y.Z
#   NOTARY_PROFILE / NOTARY_KEYCHAIN   passed to Scripts/notarize.sh
#
# The appcast is a release asset (feed URL ending in
# /releases/latest/download/appcast.xml), so "latest" always serves the newest
# release's one-item feed and no file is committed or kept between releases.

set -euo pipefail

APP_NAME="Device Hub Pro"   # the bundle: dist/Device Hub Pro.app
EXEC_NAME="DeviceHubPro"    # the executable, the disk image and the dSYM

die() { printf 'release: error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }
warn() { printf 'release: note: %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
usage: Scripts/release.sh [--dry-run] [--host-arch] [--identity <Developer ID Application: ...>]
                          [--appcast-url <https url>] [--sparkle-public-key <base64>]
                          [--download-base-url <https url>]

  --dry-run      build and stage everything with ad-hoc signing, a throwaway Sparkle
                 key and placeholder URLs; skip the tag, identity and notary checks
                 and the notarization. Nothing leaves dist/.
  --host-arch    build for this Mac's architecture (default: arm64)
EOF
}

dry_run=0
host_arch=0
identity="${DHP_SIGN_IDENTITY:-}"
appcast_url="${DHP_APPCAST_URL:-}"
public_key="${DHP_SPARKLE_PUBLIC_KEY:-}"
download_base="${DHP_DOWNLOAD_BASE_URL:-}"

while (($#)); do
    case "$1" in
        --dry-run) dry_run=1; shift ;;
        --host-arch) host_arch=1; shift ;;
        --identity) [[ $# -ge 2 && -n "$2" ]] || die "--identity needs a name"; identity="$2"; shift 2 ;;
        --appcast-url) [[ $# -ge 2 ]] || die "--appcast-url needs a URL"; appcast_url="$2"; shift 2 ;;
        --sparkle-public-key) [[ $# -ge 2 ]] || die "--sparkle-public-key needs a key"; public_key="$2"; shift 2 ;;
        --download-base-url) [[ $# -ge 2 ]] || die "--download-base-url needs a URL"; download_base="$2"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
dist="$repo_root/dist"
app="$dist/$APP_NAME.app"

version="$(tr -d '[:space:]' < VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must hold X.Y.Z, found '$version'"
tag="v$version"
dmg="$dist/$EXEC_NAME-$version.dmg"
notes_file="$dist/release-notes-$version.md"
appcast_file="$dist/appcast.xml"

work="$(mktemp -d "${TMPDIR:-/tmp}/devicehubpro-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --- Preflight ----------------------------------------------------------------

note "Release $version ($([[ $dry_run -eq 1 ]] && echo 'DRY RUN' || echo "tag $tag"))"

sparkle_bin=""
find_sparkle_tools() {
    sparkle_bin="$(find "$repo_root/.build/artifacts" -path '*/sparkle/Sparkle/bin' -type d -print -quit 2>/dev/null || true)"
    if [[ -z "$sparkle_bin" ]]; then
        swift package resolve >/dev/null 2>&1 || true
        sparkle_bin="$(find "$repo_root/.build/artifacts" -path '*/sparkle/Sparkle/bin' -type d -print -quit 2>/dev/null || true)"
    fi
    [[ -x "$sparkle_bin/sign_update" ]] || die "Sparkle's sign_update is not in .build/artifacts (run swift package resolve)"
}
find_sparkle_tools

private_key_file=""
if ((dry_run)); then
    # A throwaway EdDSA key: the real key never touches a dry run.
    openssl genpkey -algorithm ed25519 -out "$work/dry.pem" 2>/dev/null \
        || die "this openssl cannot make an ed25519 key (needed for the dry run's throwaway key)"
    public_key="$(openssl pkey -in "$work/dry.pem" -pubout -outform DER | tail -c 32 | base64)"
    openssl pkey -in "$work/dry.pem" -outform DER | tail -c 32 | base64 > "$work/dry.key"
    private_key_file="$work/dry.key"
    [[ -n "$appcast_url" ]] || appcast_url="https://github.com/example/device-hub-pro/releases/latest/download/appcast.xml"
    identity="-"
else
    [[ -n "$identity" ]] || die "no signing identity: set DHP_SIGN_IDENTITY or pass --identity \"Developer ID Application: Name (TEAMID)\""
    [[ "$identity" == "Developer ID Application:"* ]] || die "the identity must be a 'Developer ID Application: ...' certificate (an Apple Development or Distribution one cannot be notarized for download)"
    security find-identity -v -p codesigning | grep -qF "\"$identity\"" \
        || die "the keychain has no valid code-signing identity named '$identity' (security find-identity -v -p codesigning)"
    [[ -n "$appcast_url" ]] || die "no appcast URL: set DHP_APPCAST_URL (docs/distribution.md, \"First release checklist\")"
    [[ -n "$public_key" ]] || die "no Sparkle public key: set DHP_SPARKLE_PUBLIC_KEY (the line generate_keys prints)"

    git diff --quiet && git diff --cached --quiet || die "the working tree has uncommitted changes"
    tag_commit="$(git rev-parse -q --verify "refs/tags/$tag^{commit}" || true)"
    [[ -n "$tag_commit" ]] || die "tag $tag does not exist. Tag the release commit first: git tag -a $tag -m \"Device Hub Pro $version\""
    [[ "$tag_commit" == "$(git rev-parse HEAD)" ]] || die "tag $tag does not point at HEAD"

    notary_args=(--keychain-profile "${NOTARY_PROFILE:-devicehubpro-notary}")
    if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
        notary_args+=(--keychain "$NOTARY_KEYCHAIN")
    fi
    xcrun notarytool history "${notary_args[@]}" >/dev/null 2>&1 \
        || die "the notary profile '${NOTARY_PROFILE:-devicehubpro-notary}' does not work. Create it once: Scripts/notarize.sh --print-setup"

    if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
        umask 077
        printf '%s' "$SPARKLE_PRIVATE_KEY" > "$work/sparkle.key"
        private_key_file="$work/sparkle.key"
    fi
fi

[[ "$appcast_url" =~ ^https://[^/[:space:]]+ ]] || die "the appcast URL must be https, found '$appcast_url'"
if [[ -z "$download_base" ]]; then
    if [[ "$appcast_url" =~ ^(https://github\.com/[^/]+/[^/]+)/releases/latest/download/[^/]+$ ]]; then
        download_base="${BASH_REMATCH[1]}/releases/download/$tag"
    else
        die "cannot derive where the disk image will be served from '$appcast_url'; set DHP_DOWNLOAD_BASE_URL (the URL of the folder that will hold $EXEC_NAME-$version.dmg)"
    fi
fi
download_base="${download_base%/}"

# --- CHANGELOG section for the release notes ---------------------------------

# The body of "## [X.Y.Z]" (up to the next "## "). A dry run falls back to
# "## [Unreleased]", since the heading is only renamed when the release is cut.
changelog_section() {
    awk -v heading="$1" '
        /^## / { if (inside) exit; inside = (index($0, "## [" heading "]") == 1); next }
        inside { print }
    ' CHANGELOG.md
}

release_notes="$(changelog_section "$version")"
notes_source="CHANGELOG.md [$version]"
if [[ -z "${release_notes//[[:space:]]/}" ]]; then
    if ((dry_run)); then
        release_notes="$(changelog_section Unreleased)"
        notes_source="CHANGELOG.md [Unreleased] (dry run)"
    else
        die "CHANGELOG.md has no '## [$version]' section with content. Rename '## [Unreleased]' to '## [$version] - $(date +%Y-%m-%d)' and commit it."
    fi
fi
[[ -n "${release_notes//[[:space:]]/}" ]] || die "no release notes found in CHANGELOG.md"

# --- Build, sign, notarize ----------------------------------------------------

package_args=(--sign "$identity" --appcast-url "$appcast_url" --sparkle-public-key "$public_key")
if ((host_arch)); then
    package_args+=(--host-arch)
fi
if ((dry_run)); then
    warn "dry run: ad-hoc signature, no notarization, throwaway Sparkle key, placeholder feed $appcast_url"
else
    package_args+=(--require-licenses)
fi

note "Building and signing the app"
Scripts/package-app.sh "${package_args[@]}"
if ((dry_run)); then
    note "SKIPPED (dry run): notarizing and stapling $app"
else
    Scripts/notarize.sh "$app"
fi

note "Making the disk image from the (stapled) app"
Scripts/package-app.sh --sign "$identity" --appcast-url "$appcast_url" --sparkle-public-key "$public_key" --dmg-only
[[ -f "$dmg" ]] || die "$dmg was not created"
if ((dry_run)); then
    note "SKIPPED (dry run): notarizing and stapling $dmg"
else
    Scripts/notarize.sh "$dmg"
fi

# --- Sparkle signature, appcast, notes -----------------------------------------

note "Signing the disk image for Sparkle"
sign_args=()
if [[ -n "$private_key_file" ]]; then
    sign_args=(--ed-key-file "$private_key_file")
fi
sign_output="$("$sparkle_bin/sign_update" ${sign_args[@]+"${sign_args[@]}"} "$dmg")" \
    || die "sign_update failed (is the Sparkle private key in the login keychain? see docs/distribution.md)"
ed_signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$sign_output")"
length="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<< "$sign_output")"
[[ -n "$ed_signature" && -n "$length" ]] || die "could not read the signature from sign_update's output"
[[ "$length" == "$(stat -f %z "$dmg")" ]] || die "sign_update's length ($length) is not the disk image's size"
"$sparkle_bin/sign_update" --verify ${sign_args[@]+"${sign_args[@]}"} "$dmg" "$ed_signature" >/dev/null \
    || die "the Sparkle signature does not verify against the disk image"

build_number="$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")"
minimum_system="$(plutil -extract LSMinimumSystemVersion raw -o - "$app/Contents/Info.plist")"

# The CHANGELOG's Markdown subset (### headings, - bullets with indented
# continuation lines, **bold**, `code`) as HTML for the update window.
markdown_to_html() {
    awk '
        function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
        function inline(s,   out, a, b) {
            s = esc(s)
            while (match(s, /`[^`]+`/)) { s = substr(s, 1, RSTART - 1) "<code>" substr(s, RSTART + 1, RLENGTH - 2) "</code>" substr(s, RSTART + RLENGTH) }
            while (match(s, /\*\*[^*]+\*\*/)) { s = substr(s, 1, RSTART - 1) "<b>" substr(s, RSTART + 2, RLENGTH - 4) "</b>" substr(s, RSTART + RLENGTH) }
            return s
        }
        function closeItem() { if (item != "") { print "<li>" inline(item) "</li>"; item = "" } }
        function closeList() { closeItem(); if (inlist) { print "</ul>"; inlist = 0 } }
        function closePara() { if (para != "") { print "<p>" inline(para) "</p>"; para = "" } }
        /^### / { closeList(); closePara(); print "<h3>" inline(substr($0, 5)) "</h3>"; next }
        /^## /  { closeList(); closePara(); print "<h2>" inline(substr($0, 4)) "</h2>"; next }
        /^- /   { closePara(); if (!inlist) { print "<ul>"; inlist = 1 } closeItem(); item = substr($0, 3); next }
        /^[ \t]+[^ \t]/ && inlist { sub(/^[ \t]+/, ""); item = item " " $0; next }
        /^[ \t]*$/ { closeList(); closePara(); next }
        { closeList(); para = (para == "" ? $0 : para " " $0) }
        END { closeList(); closePara() }
    ' <<< "$1"
}

release_html="$(markdown_to_html "$release_notes")"
release_html="${release_html//]]>/]]&gt;}"
pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
mkdir -p "$dist"
cat > "$appcast_file" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>$APP_NAME</title>
        <link>$appcast_url</link>
        <description>Updates for $APP_NAME</description>
        <language>en</language>
        <item>
            <title>Version $version</title>
            <pubDate>$pub_date</pubDate>
            <sparkle:version>$build_number</sparkle:version>
            <sparkle:shortVersionString>$version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$minimum_system</sparkle:minimumSystemVersion>
            <description><![CDATA[
$release_html
            ]]></description>
            <enclosure url="$download_base/$EXEC_NAME-$version.dmg" sparkle:edSignature="$ed_signature" length="$length" type="application/octet-stream"/>
        </item>
    </channel>
</rss>
EOF
xmllint --noout "$appcast_file" || die "$appcast_file is not well-formed XML"

printf '%s\n' "$release_notes" | sed -e '/./,$!d' > "$notes_file"
(cd "$dist" && shasum -a 256 "$(basename "$dmg")" | tee "$(basename "$dmg").sha256")
if [[ -d "$dist/$EXEC_NAME-$version.dSYM" ]]; then
    rm -f "$dist/$EXEC_NAME-$version.dSYM.zip"
    (cd "$dist" && ditto -c -k --keepParent "$EXEC_NAME-$version.dSYM" "$EXEC_NAME-$version.dSYM.zip")
fi

# --- Check what was staged ------------------------------------------------------

note "Checking the staged release"
check() { printf '  ok: %s\n' "$1"; }
fail() { die "check failed: $1"; }

info="$app/Contents/Info.plist"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$info")" == "$version" ]] || fail "CFBundleShortVersionString is not $version"
check "version $version, build $build_number"
[[ "$(plutil -extract SUFeedURL raw -o - "$info")" == "$appcast_url" ]] || fail "SUFeedURL is not the appcast URL"
[[ "$(plutil -extract SUPublicEDKey raw -o - "$info")" == "$public_key" ]] || fail "SUPublicEDKey is not the public key"
check "Info.plist: SUFeedURL and SUPublicEDKey set"
[[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || fail "Sparkle.framework is not embedded"
otool -l "$app/Contents/MacOS/$EXEC_NAME" | grep -q '@executable_path/../Frameworks' || fail "the executable has no rpath to Contents/Frameworks"
check "Sparkle.framework embedded, rpath set"
codesign --verify --deep --strict "$app" || fail "the app's signature does not verify"
sparkle_dir="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in "$sparkle_dir"/XPCServices/*.xpc "$sparkle_dir/Autoupdate" "$sparkle_dir/Updater.app" "$app/Contents/Frameworks/Sparkle.framework"; do
    [[ -e "$nested" ]] || continue
    codesign --verify --strict "$nested" || fail "$nested is not validly signed"
    if ((!dry_run)); then
        details="$(codesign -dvv "$nested" 2>&1)"
        grep -q 'flags=.*runtime' <<< "$details" || fail "$nested lacks the hardened runtime"
        grep -q '^Authority=Developer ID Application:' <<< "$details" || fail "$nested is not signed with Developer ID"
    fi
done
check "app and Sparkle's nested code verify$([[ $dry_run -eq 1 ]] || echo ', hardened runtime, Developer ID')"
hdiutil verify -quiet "$dmg" || fail "the disk image does not verify"
check "disk image verifies"
grep -q "sparkle:edSignature=\"$ed_signature\"" "$appcast_file" || fail "the appcast lacks the signature"
check "appcast.xml is well-formed and carries the EdDSA signature of $(basename "$dmg")"
if ((!dry_run)); then
    xcrun stapler validate "$dmg" >/dev/null || fail "the disk image is not stapled"
    xcrun stapler validate "$app" >/dev/null || fail "the app is not stapled"
    check "app and disk image are notarized and stapled"
fi

# --- Done ---------------------------------------------------------------------------

assets=("$dmg" "$dmg.sha256" "$appcast_file")
if [[ -f "$dist/$EXEC_NAME-$version.dSYM.zip" ]]; then
    assets+=("$dist/$EXEC_NAME-$version.dSYM.zip")
fi
printf '\n%s %s (%s)%s\n' "$APP_NAME" "$version" "$build_number" "$([[ $dry_run -eq 1 ]] && echo ' - DRY RUN, not for publishing')"
printf '  disk image:   %s\n' "$dmg"
printf '  appcast:      %s\n' "$appcast_file"
printf '  notes:        %s (from %s)\n' "$notes_file" "$notes_source"
printf '  enclosure:    %s/%s\n' "$download_base" "$(basename "$dmg")"
printf '\nTo publish (not run by this script), after pushing the tag:\n\n'
printf '  git push origin %s\n' "$tag"
printf '  gh release create %s \\\n' "$tag"
for asset in "${assets[@]}"; do
    printf '      %q \\\n' "${asset#"$repo_root"/}"
done
printf '      --title "%s %s" --notes-file %q --verify-tag\n' "$APP_NAME" "$version" "${notes_file#"$repo_root"/}"
if ((dry_run)); then
    printf '\n(dry run: the files above carry a throwaway key and placeholder URLs; do not publish them)\n'
fi
