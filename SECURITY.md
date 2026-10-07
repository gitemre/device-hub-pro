# Security policy

## Supported versions

Security fixes go into the latest release. Device Hub Pro updates itself, so please update
before reporting.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately through
GitHub: open the repository's **Security** tab and choose **Report a vulnerability**.

Include what you found, how to reproduce it, and what an attacker could do with it. You will
get an answer within a week. Once a fix is released, the advisory is published with credit to
you, unless you prefer otherwise.

## Scope

In scope:

- The app and everything it bundles (the scrcpy server, the language helper, the fast input
  helper).
- The update path: the appcast, its EdDSA signatures and the disk images.
- The iPhone input runner (`ios/agent`) and its token and address checks.
- Anything that lets the app act on a device the user did not select.

Out of scope: bugs in adb, the Android emulator, Xcode, simctl or devicectl themselves.
Please report those to Google or Apple.
