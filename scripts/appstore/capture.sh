#!/bin/zsh
# Capture App Store screens on one simulator, from the club stage.py staged.
#   scripts/appstore/capture.sh <simulator-udid> <out-dir>
# Needs the local dev API running (cd API && AZURE_TOKEN_CREDENTIALS=dev dotnet run …) and a FRESH
# stage (a run reads the chat, so restage before each capture: python3 scripts/appstore/stage.py).
set -eu
UDID=$1 OUT=$2
cd "$(dirname "$0")/../.."
CLUB=$(python3 -c "import json;print(json.load(open('scripts/appstore/.stage.json'))['club_id'])")
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --operatorName "" --batteryState discharging --batteryLevel 100
pkill -f hermetic_stub.py 2>/dev/null || true; rm -f /tmp/ombc-hermetic-stub.pid
R=$(mktemp -d)/shots.xcresult
TEST_RUNNER_OMBC_SHOTS_CLUB_ID=$CLUB xcodebuild test -project OldMansBookClub.xcodeproj -scheme OldMansBookClub \
  -destination "platform=iOS Simulator,id=$UDID" -only-testing:OldMansBookClubUITests/AppStoreScreenshots \
  -resultBundlePath "$R" > "$R.log" 2>&1 || { grep -E "error|failed" "$R.log" | head -5; exit 1; }
RAW=$(mktemp -d)
xcrun xcresulttool export attachments --path "$R" --output-path "$RAW" >/dev/null
mkdir -p "$OUT"
python3 - "$RAW" "$OUT" <<'PY'
import json, shutil, sys
raw, out = sys.argv[1], sys.argv[2]
for t in json.load(open(f"{raw}/manifest.json")):
    for a in t.get("attachments", []):
        name = (a.get("suggestedHumanReadableName") or "shot").split("_")[0]
        shutil.copy(f"{raw}/{a['exportedFileName']}", f"{out}/{name}.png")
        print(name)
PY
