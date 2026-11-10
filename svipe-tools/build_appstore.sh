#!/bin/bash
# Build a signed App Store IPA of Svipe iOS and (with --upload) send it to TestFlight.
#
# Signing material lives outside the repo, created through the App Store Connect API:
#   ~/.appstoreconnect/config.json                 key id / issuer id / key path / team id
#   ~/.appstoreconnect/svipe-codesigning/profiles  IOS_APP_STORE profiles, one per bundle id
#   Apple Distribution identity                    in the login keychain
# The configuration json (api id/hash) is written from apikeys.properties and is git-ignored.
set -euo pipefail
cd "$(dirname "$0")/.."
UPLOAD=0; [ "${1:-}" = "--upload" ] && UPLOAD=1
KEYS="${SVIPE_APIKEYS:-$HOME/StudioProjects/Lavha/apikeys.properties}"
CONF=build-system/svipe-appstore-configuration.json
SIGN="$HOME/.appstoreconnect/svipe-codesigning"
python3 - "$KEYS" "$CONF" <<'PY'
import json, sys
keys = dict(l.strip().split('=', 1) for l in open(sys.argv[1]) if '=' in l and not l.lstrip().startswith('#'))
json.dump({
    "bundle_id": "uz.svipe.app", "team_id": "K3LJRJ3899",
    "api_id": keys["APP_ID"],
    "api_hash": keys["APP_HASH"],
    "is_internal_build": "false", "is_appstore_build": "true", "appstore_id": "6832866022",
    "app_specific_url_scheme": "svipe", "premium_iap_product_id": "",
    "enable_siri": False, "enable_icloud": False,
}, open(sys.argv[2], "w"), indent=1)
PY
BUILD_NUMBER=$(git rev-list --count HEAD)
python3 build-system/Make/Make.py --cacheDir="$HOME/telegram-bazel-cache" build \
    --configurationPath="$CONF" --codesigningInformationPath="$SIGN" \
    --buildNumber="$BUILD_NUMBER" --configuration=release_arm64
OUT="$HOME/Downloads/Svipe-iOS-$BUILD_NUMBER.ipa"
cp bazel-bin/Telegram/Telegram.ipa "$OUT"
echo "IPA: $OUT (build $BUILD_NUMBER)"
if [ $UPLOAD = 1 ]; then
    KID=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.appstoreconnect/config.json')))['key_id'])")
    ISS=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.appstoreconnect/config.json')))['issuer_id'])")
    xcrun altool --upload-app -f "$OUT" -t ios --apiKey "$KID" --apiIssuer "$ISS"
fi
