#!/bin/sh
# The Apple TV build in one command.
#   tvos/tv.sh run        prepare, build, install on the Apple TV and start it with its log in the terminal
#   tvos/tv.sh prepare    translate the game and build what the app needs on this Mac (tvos/prepare.sh)
#   tvos/tv.sh project    (re)make tvos/NFSMW.xcodeproj
#   tvos/tv.sh build      build the app (out/tvos-dd/Build/Products/Debug-appletvos/NFSMW.app)
#   tvos/tv.sh install    install the last build on the Apple TV
#   tvos/tv.sh launch     start the installed app, its log in the terminal (Ctrl-C stops watching, not the game)
#   tvos/tv.sh log        copy the app's last log from the Apple TV to out/NFSMW.log (and the one before)
#   tvos/tv.sh upload     archive and upload to App Store Connect for TestFlight (tvos/testflight.sh)
#   tvos/tv.sh art        the Home screen icon from your game's title screen: starts the game, captures the TV, cuts it
#                         (tvos/tools/title_art.py into out/art, not committed); the next build uses it
# Settings come from the environment or tvos/local.env (not committed), e.g.
#   TEAM=ABCDE12345                      your Apple developer team ID (Xcode > Settings > Accounts)
#   BUNDLE_ID=com.yourname.nfsmw         a bundle ID of your own
#   GAME="/path/to/NFS Most Wanted"      your PC game folder, v1.3 (default: "NFS Most Wanted" in the checkout)
#   DEVICE=<name or id>                  the Apple TV (default: the paired one devicectl finds)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
[ -f tvos/local.env ] && . tvos/local.env
export GAME=${GAME:-$ROOT/NFS Most Wanted}
PROJ=tvos/NFSMW.xcodeproj
DD=out/tvos-dd
APP=$DD/Build/Products/Debug-appletvos/NFSMW.app

project() {
    : "${TEAM:?set TEAM (your Apple developer team ID) in tvos/local.env or the environment}"
    : "${BUNDLE_ID:?set BUNDLE_ID (e.g. com.yourname.nfsmw) in tvos/local.env or the environment}"
    TEAM=$TEAM BUNDLE_ID=$BUNDLE_ID ruby tvos/make_project.rb 2>&1 | grep -v '^Ignoring '
}
bundle_id() { grep -o 'PRODUCT_BUNDLE_IDENTIFIER = [^;]*' "$PROJ/project.pbxproj" | head -1 | awk '{print $3}'; }

# The paired Apple TV: DEVICE, else the first tvOS device devicectl lists as paired (connected ones first).
device() {
    [ -n "${DEVICE:-}" ] && { echo "$DEVICE"; return; }
    j=$(mktemp)
    xcrun devicectl list devices --json-output "$j" >/dev/null 2>&1 || true
    python3 - "$j" <<'EOF'
import json, sys
try:
    devs = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devs = []
tv = [d for d in devs if d.get("hardwareProperties", {}).get("platform") == "tvOS"
      and d.get("hardwareProperties", {}).get("reality") == "physical"
      and d.get("connectionProperties", {}).get("pairingState") == "paired"]
tv.sort(key=lambda d: d.get("connectionProperties", {}).get("tunnelState") != "connected")
if tv:
    print(tv[0]["hardwareProperties"]["udid"])
EOF
    rm -f "$j"
}
tv() {
    DEV=$(device)
    [ -n "$DEV" ] || { echo "tv.sh: no paired Apple TV (pair it in Xcode > Window > Devices and Simulators; keep it awake)" >&2; exit 1; }
    echo "Apple TV: $DEV"
}
build() {
    [ -d "$PROJ" ] || project
    xcodebuild -project "$PROJ" -scheme NFSMW -configuration Debug -destination "id=$DEV" -allowProvisioningUpdates \
        -derivedDataPath "$DD" build 2>&1 | grep -E "error:|warning: .*(sign|provision)|stage_game:|tvos/build.sh:|BUILD (SUCC|FAIL)" || true
    [ -d "$APP" ] || { echo "tv.sh: the build made no app" >&2; exit 1; }
}
install() { xcrun devicectl device install app --device "$DEV" "$APP" 2>&1 | grep -E "installed|rror|bundleID" || true; }
launch() {
    exec xcrun devicectl device process launch --device "$DEV" --terminate-existing --console \
        --environment-variables '{"BOOT_LOG": "-"}' "$(bundle_id)"
}
log() {
    mkdir -p out
    for f in NFSMW.log NFSMW.previous.log; do
        xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$(bundle_id)" \
            --source "Library/Caches/NFSMW/Logs/$f" --destination "out/$f" >/dev/null 2>&1 && echo "out/$f"
    done
}

case "${1:-run}" in
  prepare) tvos/prepare.sh ;;
  project) project ;;
  build)   tvos/prepare.sh; tv; build ;;
  install) tv; install ;;
  launch)  tv; launch ;;
  log)     tv; log ;;
  run)     tvos/prepare.sh; tv; build; install; launch ;;
  upload)  tvos/prepare.sh; [ -d "$PROJ" ] || project; exec tvos/testflight.sh ;;
  art)     tv; mkdir -p out
           xcrun devicectl device process launch --device "$DEV" --terminate-existing "$(bundle_id)" >/dev/null
           echo "waiting 40 s for the title screen (Press START)..."; sleep 40
           xcrun devicectl device capture screenshot --device "$DEV" --destination out/title_screen.png >/dev/null
           "${TOOLS_PY:-.venv/bin/python}" -I tvos/tools/title_art.py out/title_screen.png out/art ;;
  *) sed -n 2,17p "$0"; exit 2 ;;
esac
