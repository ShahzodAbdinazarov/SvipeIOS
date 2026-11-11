#!/bin/bash
# Svipe iOS: simulator build -> install -> launch, headless (no Simulator window).
#
#   svipe-tools/build_sim.sh            build debug_sim_arm64, install on a booted-or-first iPhone simulator
#
# The Telegram API id/hash are Svipe's own, read from the Android repo's git-ignored
# apikeys.properties into a git-ignored configuration (never printed, never committed).
# A simulator build is unsigned: Make.py skips provisioning profiles for debug_sim_*, and the
# fake-codesigning identity (team C67CF9S4VU, ph.telegra.Telegraph) only names the bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
KEYS="${SVIPE_APIKEYS:-$HOME/StudioProjects/Lavha/apikeys.properties}"
CONF=build-system/svipe-sim-configuration.json
python3 - "$KEYS" "$CONF" <<'PY'
import json, re, sys
props = {}
for line in open(sys.argv[1]):
    m = re.match(r'\s*([A-Z_]+)\s*=\s*(.*?)\s*$', line)
    if m: props[m.group(1)] = m.group(2).strip('"')
json.dump({"bundle_id": "ph.telegra.Telegraph", "api_id": props["APP_ID"], "api_hash": props["APP_HASH"],
           "team_id": "C67CF9S4VU", "is_internal_build": "true", "is_appstore_build": "false",
           "appstore_id": "0", "app_specific_url_scheme": "svipe", "premium_iap_product_id": "",
           "enable_siri": False, "enable_icloud": False}, open(sys.argv[2], "w"), indent=2)
PY
grep -qx "$CONF" .git/info/exclude || echo "$CONF" >> .git/info/exclude

python3 build-system/Make/Make.py --cacheDir="$HOME/telegram-bazel-cache" build \
    --configurationPath="$CONF" --codesigningInformationPath=build-system/fake-codesigning \
    --buildNumber=1 --configuration=debug_sim_arm64

OUT=$(mktemp -d)
unzip -qo bazel-bin/Telegram/Telegram.ipa -d "$OUT"
# SVIPE_SIM_DEVICE picks a specific simulator (e.g. a clean one for store screenshots).
DEV="${SVIPE_SIM_DEVICE:-$(xcrun simctl list devices booted | grep -oE "[0-9A-F-]{36}" | head -1 || true)}"
xcrun simctl boot "$DEV" 2>/dev/null || true
if [ -z "$DEV" ]; then
    DEV=$(xcrun simctl list devices available | grep -m1 iPhone | grep -oE "[0-9A-F-]{36}")
    xcrun simctl boot "$DEV"
fi
xcrun simctl install "$DEV" "$OUT"/Payload/*.app
# `simctl install` over an existing install keeps the old embedded frameworks (their own
# CFBundleVersion never changes), so a rebuild would silently run yesterday's code. Sync the bundle
# in place: the app's data container is separate, so a signed-in session survives.
xcrun simctl terminate "$DEV" ph.telegra.Telegraph 2>/dev/null || true
rsync -a --delete --checksum "$OUT"/Payload/Telegram.app/ "$(xcrun simctl get_app_container "$DEV" ph.telegra.Telegraph)/"
xcrun simctl launch "$DEV" ph.telegra.Telegraph
echo "running on simulator $DEV (screenshot: xcrun simctl io $DEV screenshot shot.png)"
