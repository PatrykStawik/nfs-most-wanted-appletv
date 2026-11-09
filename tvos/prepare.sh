#!/bin/sh
# Prepares the Apple TV build on this Mac (tvos/tv.sh runs it; each step is skipped when its inputs are unchanged):
#   1. the project's Python (.venv: capstone, numpy, Pillow at Setup's pinned versions; TOOLS_PY names another one)
#   2. your speed.exe checked against the PC v1.3 code fingerprint, then translated to C (recomp/out)
#   3. the game-data tables from your game folder (runtime/gen), PC only
#   4. FFmpeg 7.1.1 for the Apple TV (third_party/ffmpeg-<sdk>; the pinned tarball is downloaded once)
#   5. the app's icons (out/tvos-assets): your game's title screen when out/art has it (tvos/tv.sh art), else the
#      Mac app's generic speedometer
#   GAME="/path/to/game folder" (default: "NFS Most Wanted" in the checkout)   SDK=appletvos|appletvsimulator
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
GAME=${GAME:-$ROOT/NFS Most Wanted}
SDK=${SDK:-appletvos}
[ -f "$GAME/speed.exe" ] || { echo "prepare: no speed.exe in \"$GAME\": set GAME to your PC game folder (v1.3)" >&2; exit 1; }

# 1. Python
PY=${TOOLS_PY:-$ROOT/.venv/bin/python}
if ! "$PY" -c 'import capstone, numpy, PIL' 2>/dev/null; then
    [ -n "${TOOLS_PY:-}" ] && { echo "prepare: TOOLS_PY=$TOOLS_PY lacks capstone, numpy or Pillow" >&2; exit 1; }
    BASE=$(command -v python3.12 || command -v python3)
    echo "prepare: making .venv with $BASE"
    "$BASE" -m venv "$ROOT/.venv"
    "$ROOT/.venv/bin/pip" install -q capstone==5.0.9 numpy==2.0.2 pillow==11.3.0
fi

# 2. the translated game
"$PY" -I - "$GAME/speed.exe" <<'EOF'
import sys
sys.path.insert(0, "recomp")
import exe_fingerprint
exe_fingerprint.check(open(sys.argv[1], "rb").read(), sys.argv[1])   # exits with the reason when the code differs
print("prepare: speed.exe is the supported PC v1.3 code")
EOF
key=$( (shasum -a 256 "$GAME/speed.exe"; cat recomp/recomp.py recomp/build_all.py recomp/hooks.txt recomp/functions_v13.tsv recomp/runtime.h) | shasum | cut -c1-40)
if [ -f recomp/out/funcs.h ] && [ "$(cat recomp/out/.tvos-key 2>/dev/null)" = "$key" ]; then
    echo "prepare: translated game up to date"
else
    echo "prepare: translating speed.exe to C (a few minutes)"
    "$PY" -I recomp/build_all.py --generate-only --exe "$GAME/speed.exe" | tail -4
    echo "$key" > recomp/out/.tvos-key
fi

# 3. tables
"$PY" -I tools/gen_tables.py --if-stale --pc "$GAME" --no-x360 | tail -1

# 4. FFmpeg
TARBALL=third_party/dl/ffmpeg-7.1.1.tar.xz
if [ ! -f "$TARBALL" ]; then
    echo "prepare: downloading FFmpeg 7.1.1"
    mkdir -p third_party/dl
    curl -fsSL -o "$TARBALL.part" https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz
    mv "$TARBALL.part" "$TARBALL"
fi
SDK=$SDK tvos/build_ffmpeg.sh

# 5. icons: the Mac app's speedometer (runtime/app_icon.m, built and run here on the Mac), in tvOS's layered format
ICONS=out/tvos-assets/Assets.xcassets
ART=""
[ -f out/art/logo.png ] && [ -f out/art/title.png ] && [ -f out/art/art.json ] && ART=out/art
ikey=$(cat runtime/app_icon.m tvos/tools/make_icons.py ${ART:+out/art/logo.png out/art/title.png out/art/art.json} | shasum | cut -c1-40)
if [ -d "$ICONS" ] && [ "$(cat out/tvos-assets/.key 2>/dev/null)" = "$ikey" ]; then
    echo "prepare: icons up to date"
else
    mkdir -p out/tvos-assets
    clang -fobjc-arc -w runtime/app_icon.m -framework Cocoa -framework ImageIO -framework UniformTypeIdentifiers -o out/tvos-assets/app_icon
    out/tvos-assets/app_icon out/tvos-assets/icon.png
    "$PY" -I tvos/tools/make_icons.py out/tvos-assets/icon.png "$ICONS" $ART
    echo "$ikey" > out/tvos-assets/.key
fi
echo "prepare: done"
