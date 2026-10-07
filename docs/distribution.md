# Distributing Device Hub Pro

This page covers how to turn the Swift package into `Device Hub Pro.app`, sign and notarize it, wrap it in a disk image, and publish a release that testers can install. It also says what testers see the first time they open the app.

| Step | Command | Who |
|---|---|---|
| Add BoringSSL's license text (once per BoringSSL revision) | the two `curl` commands under "BoringSSL's license", then commit | maintainer |
| Build the app (ad-hoc signed) | `Scripts/package-app.sh` | anyone |
| Build the app and disk image | `Scripts/package-app.sh --dmg` | anyone |
| Sign for distribution | `Scripts/package-app.sh --sign "Developer ID Application: …" --dmg` | maintainer (certificate) |
| Store notary credentials (once) | `xcrun notarytool store-credentials …` (`Scripts/notarize.sh --print-setup` prints it) | maintainer |
| Notarize and staple | `Scripts/notarize.sh dist/DeviceHubPro-X.Y.Z.dmg` | maintainer |
| Release (build, sign, notarize, Sparkle-sign, appcast) | `Scripts/release.sh` (rehearse with `--dry-run`) | maintainer |
| Publish | the `gh release create …` command `release.sh` prints | maintainer |

> **Prerequisite for any build that other people get:** BoringSSL's `LICENSE` must be committed as `packaging/licenses/boringssl-<revision>/LICENSE` for both vendored revisions. If `packaging/licenses` does not exist in your checkout yet, run the two commands under "BoringSSL's license" below and commit the files. Until then:
>
> - `Scripts/package-app.sh` and `--dmg` still build, but only for your own Mac. The script prints a warning at the start and at the end, and its summary says `licenses: INCOMPLETE`. Do not give such a build to anyone.
> - `--sign` with a real identity, `--require-licenses` and `release.yml` stop before building.

## First release checklist

The app is ready for its first public release once these are done, in this order. Steps 1 to 3 are one-time; the Mac currently has Apple Development and Apple Distribution identities only, and neither can sign a download.

1. **Create the Developer ID Application certificate.** Only the Account Holder can. In Xcode: Settings ▸ Accounts ▸ (your team) ▸ Manage Certificates ▸ **+** ▸ Developer ID Application (or developer.apple.com ▸ Certificates). Check that `security find-identity -v -p codesigning` now lists `Developer ID Application: Name (TEAMID)`.
2. **Store the notary credentials** under the name the scripts expect: `xcrun notarytool store-credentials devicehubpro-notary` (it asks for your Apple ID, Team ID and an app-specific password; `Scripts/notarize.sh --print-setup` prints the full command).
3. **Create the Sparkle signing key.** Run `.build/artifacts/sparkle/Sparkle/bin/generate_keys` (after any `swift build`). The private key goes into your login keychain; the command prints the **public key**, a 44-character base64 string. Keep the private key safe: every later update must be signed with it, and losing it strands installed copies. Back it up with `generate_keys -x sparkle-private-key.txt` and store the file somewhere offline, never in the repository. Do not generate the key on a CI machine, and never commit it.
4. **Create the new public GitHub repository**, push this code there, and decide the feed URL. The recommended one serves the newest release's `appcast.xml` through GitHub's `latest` redirect, so no file is committed or hosted separately: `https://github.com/OWNER/REPO/releases/latest/download/appcast.xml`.
5. **Set the two build settings** (shell profile or each run):

   ```sh
   export DHP_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
   export DHP_APPCAST_URL="https://github.com/OWNER/REPO/releases/latest/download/appcast.xml"
   export DHP_HELP_URL="https://github.com/OWNER/REPO#readme"   # Help ▸ Device Hub Pro Help
   export DHP_SPARKLE_PUBLIC_KEY="<the public key from step 3>"
   ```

6. **Prepare the release commit.** In `CHANGELOG.md` rename `## [Unreleased]` to `## [1.0.0] - YYYY-MM-DD` (that section becomes the release notes and the update window's text), set `VERSION`, commit, then tag: `git tag -a v1.0.0 -m "Device Hub Pro 1.0.0"`. The BoringSSL license files must be committed (see below).
7. **Rehearse:** `Scripts/release.sh --dry-run --host-arch` builds and stages everything with ad-hoc signing and a throwaway key, and runs every check except Apple's. Fix anything it reports.
8. **Run the release:** `Scripts/release.sh`. It builds the app, signs it with the hardened runtime (Sparkle inside out), notarizes and staples the app, makes the disk image from it, notarizes and staples that, signs the image for Sparkle, writes `dist/appcast.xml`, and prints the `gh release create` command.
9. **Publish:** `git push origin v1.0.0`, then run the printed `gh release create v1.0.0 …` (it uploads the disk image, its SHA-256, `appcast.xml` and the dSYM, with the CHANGELOG section as notes). Pushing the tag also starts `release.yml`, which builds a second copy as a workflow artifact; ignore it unless the CI secrets below are set.
10. **Check the update path once:** install the published disk image, then publish a later version (a patch bump) and use Device Hub Pro ▸ Check for Updates… in the first install.

Releasing from CI instead of this Mac: set the secrets and variables listed under "Continuous integration" for `release.yml` and push the tag; `release.yml` then runs the same `Scripts/release.sh`, and the job log ends with the same `gh` command.

## In-app updates

Device Hub Pro updates itself with [Sparkle 2](https://sparkle-project.org) (MIT, pinned to an exact version in `Package.swift`; `THIRD_PARTY_NOTICES.md` covers it). The packaged app has:

- **Device Hub Pro ▸ Check for Updates…** (under About) and **Settings ▸ Updates ▸ Automatically check for updates** (on by default; the choice is Sparkle's own `SUEnableAutomaticChecks` default).
- `SUFeedURL` and `SUPublicEDKey` in its `Info.plist`.

**One setting names the feed.** `packaging/Info.plist` keeps both values empty. `Scripts/package-app.sh` fills them from `--appcast-url` / `DHP_APPCAST_URL` and `--sparkle-public-key` / `DHP_SPARKLE_PUBLIC_KEY`. Both are needed (the script stops with only one), the URL must be https, and the key must be the 44-character string `generate_keys` prints. With neither, as in a local build, a `.build/debug` run or `swift test`, the app **never starts Sparkle and hides the menu item and the Settings section** (`UpdaterConfiguration`, `UpdaterConfigurationTests`). To move the project to another repository, change `DHP_APPCAST_URL` and rebuild; installed copies keep checking the old feed, so the last release from the old location must be one whose feed already points at the new one.

**How an update is checked.** The app downloads the appcast, compares `sparkle:version` (the build number, the commit count) with its own `CFBundleVersion`, downloads the disk image the item names, verifies its EdDSA signature with the embedded public key, and replaces the app. The EdDSA signature is what protects users; Apple's notarization is independent of it, and both are needed for a release.

**The appcast** is one `<item>` for the newest release, written by `Scripts/release.sh` from a template (not by Sparkle's `generate_appcast`, which wants a folder of every release and the key in the keychain). The CHANGELOG section for that version is converted to HTML as the item's description, `sparkle:minimumSystemVersion` comes from `LSMinimumSystemVersion`, and the enclosure URL is `<download base>/DeviceHubPro-X.Y.Z.dmg`, where the download base is derived from a GitHub `…/releases/latest/download/appcast.xml` feed as `…/releases/download/vX.Y.Z` (set `DHP_DOWNLOAD_BASE_URL` for any other host). A release that must reach only some users is not supported; every installed copy is offered the newest release.

**Signing, in Sparkle's documented order.** `package-app.sh` embeds `Sparkle.framework` in `Contents/Frameworks` (and adds `@executable_path/../Frameworks` to the executable's rpaths), then signs, with the same identity and `--options runtime`: the framework's XPC services (keeping the entitlements they carry), `Autoupdate`, `Updater.app`, the framework, other resource bundles, and last the app. It never uses `--deep` to sign: that re-signs nested code with the app's flags and entitlements, which breaks Sparkle's helpers. `codesign --verify --deep --strict` is used only to verify. `Scripts/notarize.sh` checks every nested code item (framework, XPC services, helper, app) for a Developer ID signature, a secure timestamp and the hardened runtime before uploading, for an app and, by mounting it, for a disk image; Apple's notary service rejects the whole submission when one of them lacks any.

**Ad-hoc local builds** still build and run: Sparkle is embedded and signed ad hoc, and with no feed the updater stays off.

## Cutting a release

`Scripts/release.sh` is the whole flow (the checklist above has the one-time setup):

```sh
git tag -a vX.Y.Z -m "Device Hub Pro X.Y.Z"    # after VERSION and CHANGELOG are committed
Scripts/release.sh                         # build, sign, notarize, Sparkle-sign, appcast
git push origin vX.Y.Z
gh release create vX.Y.Z …                 # the command release.sh printed
```

`release.sh` refuses to run unless `VERSION` is `X.Y.Z`, tag `vX.Y.Z` points at `HEAD`, the tree is clean, `CHANGELOG.md` has a `## [X.Y.Z]` section, the identity is a Developer ID Application one the keychain holds, the notary profile works, and the appcast URL and public key are set. `CFBundleVersion` is the commit count, so each build from `main` gets a higher number than the one before; Sparkle compares it. `--dry-run` skips the tag, identity and notary checks and the notarization, uses a throwaway key and a placeholder feed, and falls back to the `[Unreleased]` notes; use it before every release, and use `--host-arch` for a faster one. Everything lands in `dist/`.

The manual steps `release.sh` wraps, for reference: `Scripts/package-app.sh --sign … ` (the app), `Scripts/notarize.sh "dist/Device Hub Pro.app"`, `Scripts/package-app.sh --sign … --dmg-only`, `Scripts/notarize.sh dist/DeviceHubPro-X.Y.Z.dmg`, then `sign_update` on the image.

Pushing the tag also starts `.github/workflows/release.yml`, described below.

## What the packaging script builds

`Scripts/package-app.sh` runs from any directory. It does these steps:

1. **Checks license coverage.** Every package in `Package.resolved` must be listed in the script, either as shipped (it is linked into the app and covered by `THIRD_PARTY_NOTICES.md`) or as build-only. A new dependency stops the script until someone classifies it. The script also checks BoringSSL's license files (see "BoringSSL's license" below). A file that differs from upstream always stops it. A missing file stops it only for builds meant for other people.
2. **Builds release.** It runs `swift build -c release` with Swift Build (`--build-system swiftbuild`) for `arm64`: the app ships for Apple silicon only (macOS 26 is the last release for Intel Macs, and an Intel build could not be tested). `--host-arch` builds for the machine's own architecture instead.
3. **Assembles `dist/Device Hub Pro.app`**:
   - `Contents/MacOS/DeviceHubPro`: the executable, stripped of debug and local symbols. The matching dSYM is saved as `dist/DeviceHubPro-<version>.dSYM` so crash reports can be symbolicated.
   - `Contents/Info.plist`, from `packaging/Info.plist`:
     - bundle identifier `io.github.gitemre.devicehubpro` (the same subsystem the app logs under)
     - `CFBundleShortVersionString` from `VERSION`
     - `CFBundleVersion`: the number of commits on `HEAD`
     - `SUFeedURL`, `SUPublicEDKey` (Sparkle, from the appcast settings; empty means no updater) and `SUEnableAutomaticChecks`
     - minimum macOS 26.0 (`LSMinimumSystemVersion`). `Package.swift` holds the same minimum twice: `platforms`, which every module is compiled for, and the first number of `-platform_version`, which the executable is linked for. The script stops unless all three agree; `DeploymentTargetTests` checks the same in `swift test`.
     - category Developer Tools
     - usage strings for the Desktop, Documents and Downloads folders and for the local network (wireless debugging)
   - `Contents/Resources`:
     - `AppIcon.icns`
     - the SwiftPM resource bundles: the scrcpy server, the device-language helper (`devicehubpro-locales.dex`), the Metal shader, and the privacy manifests of the dependencies
     - `Credits.rtf`, generated from `THIRD_PARTY_NOTICES.md` by `Scripts/make-credits.swift`. The standard About panel shows it.
     - `Licenses/`: every shipped component's license and NOTICE files, copied unchanged from the resolved checkouts, plus BoringSSL's `LICENSE` from `packaging/licenses` as `Licenses/swift-nio-ssl/BoringSSL-LICENSE` and `Licenses/swift-crypto/BoringSSL-LICENSE`. A local ad-hoc build made before those files were committed lacks the two BoringSSL files.
   - `Contents/Frameworks/Sparkle.framework` and nothing else (see "In-app updates"). The executable targets macOS 26 and links only the Swift runtime in the system's `/usr/lib/swift`. The macOS 15 build also linked the back-deployment library `libswiftCompatibilitySpan.dylib`, and the script bundled it; `otool -L` of the macOS 26 build lists no `@rpath/libswift…` library. The script stops if a toolchain links such a library again, because bundling it would need its own signature and a `THIRD_PARTY_NOTICES.md` entry. It also removes the build machine's absolute paths from the executable's rpaths (the `@executable_path/../Frameworks` one for Sparkle stays).
4. **Signs**, nested code first (Sparkle's XPC services, helper and updater app, then its framework, then the resource bundles, then the app). With a real identity, the app uses the **hardened runtime**, which notarization requires, and gets a secure timestamp. The app has **two entitlements**, the Camera and the audio input (`packaging/DeviceHubPro.entitlements`, `com.apple.security.device.camera` and `com.apple.security.device.audio-input`): a connected iPhone's screen reaches the Mac as a capture device (the public CoreMediaIO + AVFoundation screen capture path), and the hardened runtime blocks capture devices without the first; the same device carries the phone's audio, which the live view plays, and the hardened runtime blocks that without the second. `Info.plist` carries `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` for the two permission prompts. Nothing else is needed:
   - The hardened runtime does not restrict spawning `adb`, `emulator` or `java`.
   - The app is not sandboxed, so it can read the SDK and `~/.android`.
   - Metal compiles the shader source out of process, so no JIT or unsigned-memory entitlement is involved.

   With the default `--sign -` the signature is ad hoc, has no timestamp, and has **no hardened runtime**. Ad-hoc builds cannot be notarized, so they lose nothing. The hardened runtime also turns on library validation, and an ad-hoc process may not load an ad-hoc dylib: dyld refuses it because the two have no matching Team ID. That made a hardened ad-hoc build abort before `main` while the app bundled `libswiftCompatibilitySpan.dylib` for macOS 15; the macOS 26 app bundles no dylib. `--entitlements <plist>` replaces the default entitlements file if a future feature needs another.
5. **Verifies** with `codesign --verify --deep --strict`.
6. With `--dmg`, **creates `dist/DeviceHubPro-<version>.dmg`**: a compressed HFS+ image that holds the app and an `Applications` link. With a real identity the image is signed too. `--dmg-only` makes the image from an existing `dist/Device Hub Pro.app` without rebuilding it (see "Stapling the app too"). With `--require-licenses` or a real identity, `--dmg-only` refuses an app that lacks the BoringSSL license files.
7. **Prints a summary**: version, architectures, signature, whether the runtime is hardened, and `licenses: complete` or `licenses: INCOMPLETE`. Share only builds that say `complete`.

`dist/` is ignored by git.

### Resources inside the app

`Bundle.module` alone is not reliable in a packaged app. The accessor that the native SwiftPM build system generates looks for `<name>.bundle` at the top level of the `.app` folder (`Device Hub Pro.app/<name>.bundle`, outside `Contents`, where a signed app cannot hold unsealed content). It then looks at the absolute `.build` path of the machine that built it, and calls `fatalError` when neither exists. Such an app runs on the build machine and crashes on a tester's Mac. The Swift Build accessor checks `Contents/Resources` first, but that depends on the toolchain. `ResourceBundleLookup` (in DeviceHubProKit) therefore looks for `<Package>_<Target>.bundle` in `Bundle.main.resourceURL` first. It asks `Bundle.module` only when no packaged bundle is there, as in `swift test`. The scrcpy server, the language helper dex and `Shaders.metal` are found this way. `ResourceBundleLookupTests` and `ShaderResourceLookupTests` cover the lookup order.

Checked on 2026-09-25 with Xcode 27.0 (Swift 6.4):

1. Built the universal DMG and copied the app out of it to a scratch folder.
2. Moved the worktree's `.build` away.
3. Launched the copy with `DHP_AUTOMIRROR=1 DHP_FORCE_PHYSICAL=emulator-5554`.

Results:

- The app pushed the bundled scrcpy server 3.1 to the emulator and mirrored over it. The perf log recorded frames with 0 dropped at about 4.5 ms latency.
- The app compiled the bundled shader at run time: the Metal cache for `io.github.gitemre.devicehubpro` was created and no renderer error was logged.

### BoringSSL's license

SwiftNIO SSL and Swift Crypto each vendor a copy of BoringSSL, and neither copy includes BoringSSL's `LICENSE`. Its terms ask a binary distribution to carry the notices and conditions (`THIRD_PARTY_NOTICES.md` explains why). The repository therefore keeps that file, unchanged, for each vendored revision:

```
packaging/licenses/boringssl-<revision>/LICENSE
```

The script reads each revision from the `hash.txt` file in the vendored copy and compares the file's Git blob hash with the upstream hash pinned in `BORINGSSL_LICENSE_PINS`. It ships only files that match, as `Licenses/swift-nio-ssl/BoringSSL-LICENSE` and `Licenses/swift-crypto/BoringSSL-LICENSE`.

| Situation | Local ad-hoc build | `--sign` with a real identity, `--require-licenses`, `release.yml` |
|---|---|---|
| File present and matches its pin | ships it | ships it |
| File differs from its pin | stops | stops |
| File missing, or its revision has no pin | builds without it, warns at the start and the end, summary says `licenses: INCOMPLETE` | stops |

The local exception exists so that a checkout without the files can still build and try the app on the same Mac. Such a build must not leave that Mac.

**Adding the files the first time.** The revisions vendored today are `817ab07…` (SwiftNIO SSL) and `0226f30…` (Swift Crypto). From the repository root:

```sh
curl -fsSL --create-dirs -o packaging/licenses/boringssl-817ab07ebb53da35afea409ab9328f578492832d/LICENSE \
    https://raw.githubusercontent.com/google/boringssl/817ab07ebb53da35afea409ab9328f578492832d/LICENSE
curl -fsSL --create-dirs -o packaging/licenses/boringssl-0226f30467f540a3f62ef48d453f93927da199b6/LICENSE \
    https://raw.githubusercontent.com/google/boringssl/0226f30467f540a3f62ef48d453f93927da199b6/LICENSE
Scripts/package-app.sh --require-licenses --dmg   # checks both hashes; the summary must say "licenses: complete"
git add packaging/licenses
git commit -m "build: add boringssl's license for the vendored revisions"
```

**When a SwiftNIO SSL or Swift Crypto update changes the BoringSSL revision**, the script prints the commands to run from the repository root (and stops, for a build meant for other people):

1. Fetch the new file: `curl -fsSL --create-dirs -o packaging/licenses/boringssl-<revision>/LICENSE https://raw.githubusercontent.com/google/boringssl/<revision>/LICENSE`
2. Add `"<revision> <sha>"` to `BORINGSSL_LICENSE_PINS` in the script. The sha is the one that `gh api "repos/google/boringssl/contents/LICENSE?ref=<revision>" --jq .sha` prints.
3. Update the revision and license summary in `THIRD_PARTY_NOTICES.md`, and delete the folder of the revision that no package vendors any more.

### Build-system caveat

A release build from the deprecated native build system (`swift build -c release --build-system native`) aborted at launch in the same check. The abort happened even when the binary ran unpackaged from `.build`. The error was the Swift concurrency runtime's "freed pointer was not the last allocation", in `swift_task_dealloc`, under `ProcessRunner.run`'s `Task.sleep`.

The cause was a toolchain bug. Our modules (built at macOS 15 then, at macOS 26 now, with the same result) and two dependencies (macOS 12) each emitted a weak copy of the `Clock.sleep(for:)` specialization, and the copies needed different async context sizes. The native build links all modules' objects together. ld took the body from one copy and the context size from another, and every sleep then overran its context. Swift Build links each module into one object first, which keeps each module's copies private. `docs/native-build-async-odr.md` has the full analysis and a two-file reproducer. The workaround is the `Task.sleep(for:)` shim in `Sources/DeviceHubProKit/Internal/TaskSleep.swift`, and the native release now launches. The script still requests Swift Build explicitly. If a native build is ever shipped, run `Scripts/check-async-odr.sh` on it first.

## The disk image window

`--dmg` lays the disk image's window out with [dmgbuild](https://github.com/dmgbuild/dmgbuild) (MIT, build-time only, never shipped): a 660 x 400 pt window with no toolbar or sidebar, the app on the left, an Applications link on the right, 128 pt icons, and `packaging/dmg/background.tiff` behind them (an arrow and "Drag Device Hub Pro to Applications to install it"). dmgbuild writes the window layout itself, so no Finder scripting and no Automation prompt is involved, on a Mac or in CI. `Scripts/package-app.sh` installs it once into `.build/dmgbuild-venv` from `packaging/dmg/requirements.txt` (pinned by hash); the layout is `Scripts/dmg-settings.py`. Without Python or network access the image is made the plain way, and the summary says `(plain window)` instead of `(styled window)`. To change the background, edit `Scripts/make-dmg-background.swift` and run `swift Scripts/make-dmg-background.swift`; keep its icon centres in sync with `dmg-settings.py`.

## The icon

`packaging/AppIcon.icns` is drawn by `Scripts/make-icon.swift` with Core Graphics: a white squircle on the macOS icon grid with faint rings spreading from the middle (the hub), and three liquid-glass devices over them: a violet tablet behind, a blue phone with a pill-shaped camera and a green phone with a punch-hole camera, for iOS and Android. At 16 and 32 px the rings and cameras are left out. It uses no Apple, Google or Android marks.

To change the icon, do one of these:

- Edit the script and run `swift Scripts/make-icon.swift`. Add `--png icon-1024.png` to keep the master image.
- Replace `packaging/AppIcon.icns` with your own `.icns`. You can build one from an iconset with `iconutil -c icns AppIcon.iconset`.

## Signing with Developer ID

What you need:

- A paid Apple Developer Program membership.
- A **Developer ID Application** certificate, with its private key, in your login keychain. To create one in Xcode: Settings ▸ Accounts ▸ (your team) ▸ Manage Certificates ▸ + ▸ Developer ID Application. You can also create it at developer.apple.com under Certificates. Only the Account Holder can create Developer ID certificates. A "Mac Development" or "Apple Distribution" certificate will not work.
- The identity name. `security find-identity -v -p codesigning` lists it, for example `Developer ID Application: Jane Doe (ABCDE12345)`.

Then run:

```sh
Scripts/package-app.sh --sign "Developer ID Application: Jane Doe (ABCDE12345)" --dmg
```

The first signature may make Keychain Access ask for permission to use the key. Choose "Always Allow" for `codesign`.

## Notarizing

Gatekeeper blocks downloaded apps that Apple has not notarized. Notarization uploads the build to Apple's notary service, which scans it and issues a ticket.

**Once:** store the notary credentials in your keychain. Run this yourself; `Scripts/notarize.sh --print-setup` prints the same command:

```sh
xcrun notarytool store-credentials "devicehubpro-notary" \
    --apple-id "<your Apple ID email>" \
    --team-id "<your Team ID>"
```

It asks for an **app-specific password**. Create one at account.apple.com under Sign-In and Security ▸ App-Specific Passwords. An App Store Connect API key (`--key`, `--key-id`, `--issuer`) works as well.

**Each release:**

```sh
Scripts/notarize.sh dist/DeviceHubPro-1.0.0.dmg
```

The script:

1. Refuses ad-hoc builds, missing timestamps and apps without the hardened runtime.
2. Submits with `xcrun notarytool submit --keychain-profile devicehubpro-notary --wait`. If Apple rejects the build, it prints Apple's log.
3. Staples the ticket with `xcrun stapler staple` and checks it with `stapler validate`.
4. Runs `spctl --assess`, which should report `source=Notarized Developer ID`.

To use another profile name, pass `--profile <name>` or set `NOTARY_PROFILE`.

### Stapling the app too

Notarizing the disk image also covers the app inside it. The staple, however, is attached only to the disk image. After a tester copies the app to /Applications, Gatekeeper looks the ticket up online on first launch. Testers who may be offline need the ticket stapled to the app itself:

```sh
Scripts/package-app.sh --sign "$IDENTITY"              # the app only
Scripts/notarize.sh "dist/Device Hub Pro.app"                   # zips, notarizes, staples the app
Scripts/package-app.sh --sign "$IDENTITY" --dmg-only    # image the stapled app
Scripts/notarize.sh dist/DeviceHubPro-1.0.0.dmg             # notarize and staple the image
```

## Continuous integration

There is no CI on pushes or pull requests. Run `swift build` and `swift test` locally before every commit (`AGENTS.md`); the packaging scripts can be checked with `shellcheck Scripts/package-app.sh Scripts/notarize.sh Scripts/release.sh`.

`.github/workflows/release.yml` runs on `v*.*.*` tags and on demand:

1. Checks that the tag matches `VERSION`.
2. Builds the app and DMG with `--require-licenses`, so it stops until BoringSSL's license files are committed.
3. Uploads the DMG, its SHA-256, the zipped dSYM and (for a full release) `appcast.xml` as a workflow artifact.

It never publishes the GitHub release. Without secrets, the artifact is **unsigned** (ad hoc) and suits only technical testers (see below). Signing and notarization run only when these repository secrets are set:

| Secret | Value |
|---|---|
| `MACOS_DEVELOPER_ID_P12_BASE64` | `base64 -i DeveloperID.p12` of the exported Developer ID Application certificate and key |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | the password chosen when exporting the `.p12` |
| `MACOS_DEVELOPER_ID_IDENTITY` | `Developer ID Application: Jane Doe (ABCDE12345)` |
| `MACOS_NOTARY_APPLE_ID` | the Apple ID email |
| `MACOS_NOTARY_TEAM_ID` | the Team ID |
| `MACOS_NOTARY_PASSWORD` | an app-specific password for that Apple ID |
| `SPARKLE_PRIVATE_KEY` | the contents of the file `generate_keys -x` exports (the EdDSA private key) |

and these repository **variables** (not secrets):

| Variable | Value |
|---|---|
| `DHP_APPCAST_URL` | the feed, e.g. `https://github.com/OWNER/REPO/releases/latest/download/appcast.xml` |
| `DHP_HELP_URL` | the page Help ▸ Device Hub Pro Help opens, e.g. `https://github.com/OWNER/REPO#readme`; empty hides the item |
| `DHP_SPARKLE_PUBLIC_KEY` | the public key `generate_keys` printed |

With the signing secrets only, the job signs without notarizing; with the notary secrets too, it notarizes; with the Sparkle secret and variables as well, it runs `Scripts/release.sh` (a tag push is needed: the script checks that the tag is at `HEAD`) and uploads `appcast.xml` and the release notes beside the disk image. Builds without all of those carry no updater.

The workflow imports the certificate into a temporary keychain, which it deletes at the end, and stores the notary credentials only in that keychain.

## What testers do

**Before installing:**

- **macOS 26 or later.** Earlier versions do not open the app.
- **Android SDK.** Install the platform tools and the emulator, for example through Android Studio's SDK Manager, or with `sdkmanager "platform-tools" "emulator"`. Opened from the Finder, Device Hub Pro finds the SDK only in `~/Library/Android/sdk`, Android Studio's default. It also finds `adb` and `emulator` in Homebrew's `/opt/homebrew/bin` or `/usr/local/bin`. Apps opened from the Finder do not see `ANDROID_HOME`, `ANDROID_SDK_ROOT` or `PATH` from shell profiles. If the SDK is somewhere else, do one of these:
  - Link it to the default location: `ln -s /path/to/sdk ~/Library/Android/sdk`.
  - Quit Device Hub Pro and start it with the variable set: `open --env ANDROID_HOME=/path/to/sdk -a "Device Hub Pro"`. `DHP_ADB=/path/to/adb` points at one `adb` binary instead.

  Device Hub Pro ▸ Settings shows which `adb` and `emulator` it found, but only the emulator binary can be changed there (Emulator ▸ Choose…).
- **Physical phones.** Enable USB debugging (or Wireless debugging) in Developer options, connect the phone, and accept the RSA fingerprint prompt on it.

**Installing a notarized release:**

1. Download `DeviceHubPro-X.Y.Z.dmg` from the GitHub release and open it.
2. Drag Device Hub Pro to Applications.
3. Open Device Hub Pro. macOS asks once whether to open an app downloaded from the internet: choose Open.

**Prompts on first use:**

- **Local Network**, when wireless debugging pairs or connects to a phone.
- **Desktop folder**, the first time a capture is saved there.
- **Downloads or Documents**, when reopening a recent APK stored there.

Each prompt explains why Device Hub Pro asks.

**Installing an unsigned build** (a CI artifact, or your own `package-app.sh` build moved to another Mac; share only a build whose summary said `licenses: complete`): macOS refuses to open these at first. After the first refusal, go to System Settings ▸ Privacy & Security and click **Open Anyway** next to the Device Hub Pro message. Technical testers can instead clear the quarantine flag with `xattr -dr com.apple.quarantine /Applications/Device Hub Pro.app`. Only do this for builds from a trusted source.

**Settings from development builds.** The packaged app keeps its settings under `io.github.gitemre.devicehubpro`. A `.build/debug/DeviceHubPro` run keeps its settings separately, so settings made in a development build do not carry over.

## Troubleshooting

| Symptom | Check |
|---|---|
| `package-app.sh` stops with "BoringSSL's license text must ship with a build for other people" | `packaging/licenses` lacks a file for the vendored revision. Run the printed `curl` commands and commit the files (see "BoringSSL's license"). |
| The summary says `licenses: INCOMPLETE` | Same cause, for a local ad-hoc build. The build works on this Mac but must not be shared. |
| "Device Hub Pro is damaged and can't be opened" | The build is not notarized and is quarantined. Use a notarized build, or see the unsigned-build note above. |
| `spctl --assess` says `rejected` | Expected for ad-hoc builds. For Developer ID builds, notarize and staple first. |
| `release.sh` stops with "tag vX.Y.Z does not point at HEAD" | Commit VERSION and CHANGELOG first, then create the tag on that commit. |
| `release.sh` stops in `sign_update` | The Sparkle private key is not in the login keychain of the user running it. Import it (`generate_keys -f sparkle-private-key.txt`) or set `SPARKLE_PRIVATE_KEY`. |
| "Check for Updates…" is missing | The build has no appcast URL and public key (see "In-app updates"); the summary of `package-app.sh` says `updater: off`. |
| notarytool status `Invalid` | `Scripts/notarize.sh` prints Apple's log. The usual causes are a missing hardened runtime, missing timestamps, or unsigned nested code. The script covers all three, so the log names the file. |
| "adb was not found" although the SDK is installed | The SDK is not in `~/Library/Android/sdk`. See "Before installing" above: link it there, or start Device Hub Pro with `ANDROID_HOME` or `DHP_ADB` set. |
| Wireless Android devices never appear; `adb connect` says "No route to host" | The adb server was started by a process without the macOS Local Network permission. The app restarts it itself from its own process (it declares `NSBonjourServices` in `Info.plist`); if you denied Local Network to Device Hub Pro, allow it under System Settings › Privacy & Security › Local Network. See [Troubleshooting](troubleshooting.md). |
| The mirror stays blank | Start the app from Terminal (`"/Applications/Device Hub Pro.app/Contents/MacOS/DeviceHubPro"`) and look for `(MirrorView) renderer unavailable` in its output. Also check that `Contents/Resources/DeviceHubPro_DeviceHubProApp.bundle` holds `Shaders.metal`. |
| Physical mirroring fails at once with "the vendored scrcpy-server is missing" | `Contents/Resources/DeviceHubPro_DeviceHubProKit.bundle` is missing or incomplete. Rebuild with `Scripts/package-app.sh`. |
