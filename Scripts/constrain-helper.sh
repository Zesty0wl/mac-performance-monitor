#!/bin/bash
#
# constrain-helper.sh <App.app>
#
# Adds a launch constraint (SpawnConstraint, macOS 14+) to the bundled helper's
# LaunchDaemon plist: launchd then starts the root helper only when its binary
# carries our signing identifier AND the team it was just signed with. The
# helper runs from inside the app bundle, which a drag or install.sh install
# leaves writable by the user, so without this a same-user process could swap
# the binary and have launchd run its own code as root.
#
# Run after signing the helper and before signing the app (the plist is part of
# the app's sealed resources). The team is read from the helper's signature, so
# a clone signed with any certificate works. An ad-hoc helper has no team and
# gets no constraint; ad-hoc builds cannot run the helper anyway.
set -euo pipefail

APP="$1"
HELPER="$APP/Contents/MacOS/MacPerfMonitorHelper"
PLIST="$APP/Contents/Library/LaunchDaemons/uk.co.bzwrd.macperfmonitor.helper.plist"
[[ -f "$HELPER" && -f "$PLIST" ]] || exit 0

TEAM="$(codesign -dvvv "$HELPER" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ -z "$TEAM" || "$TEAM" == "not set" ]]; then
  echo "==> Helper has no team; no launch constraint"
  exit 0
fi
plutil -replace SpawnConstraint -json \
  "{\"team-identifier\":\"$TEAM\",\"signing-identifier\":\"uk.co.bzwrd.macperfmonitor.helper\"}" \
  "$PLIST"
echo "==> Helper launch constrained to team $TEAM"
