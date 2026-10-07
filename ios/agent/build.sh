#!/bin/bash
# Builds and signs the Device Hub Pro agent (host app + UI-test runner) for one iPhone.
#
#   ios/agent/build.sh <DEVICE-UDID> <TEAM-ID> [<derived-data-dir>]
#
# The team and UDID come from the command line only; nothing about signing is stored in
# the project. Automatic signing needs a development profile for the phone already on
# this Mac (a wildcard "iOS Team Provisioning Profile: *" covers it). No
# -allowProvisioningUpdates: this never contacts Apple or asks for a credential.
# Output: <derived-data-dir>/Build/Products/*.xctestrun and the two signed bundles.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
udid="${1:?device UDID}"
team="${2:?team id}"
dd="${3:-$here/../../.build/ios-agent}"

python3 "$here/gen_project.py" >/dev/null
xcodebuild build-for-testing \
    -project "$here/DeviceHubProAgent.xcodeproj" \
    -scheme DeviceHubProAgent \
    -destination "id=$udid" \
    -derivedDataPath "$dd" \
    DEVELOPMENT_TEAM="$team" \
    CODE_SIGN_STYLE=Automatic
