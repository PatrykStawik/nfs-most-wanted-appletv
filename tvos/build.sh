#!/bin/sh
# Compiles the game for the Apple TV into one static library: out/<sdk>/libnfsmw.a (the Xcode project links it).
#   tvos/build.sh                        Apple TV device (out/appletvos)
#   SDK=appletvsimulator tvos/build.sh   tvOS simulator  (out/appletvsimulator)
# Inputs (tvos/prepare.sh makes them): the translated game in recomp/out (recomp/build_all.py --generate-only), the
# game-data tables in runtime/gen (tools/gen_tables.py) and FFmpeg in third_party/ffmpeg-<sdk> (tvos/build_ffmpeg.sh).
# Each object is rebuilt only when its source, the shared headers or the flags change. Xcode runs this before linking.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
SDK=${SDK:-${PLATFORM_NAME:-appletvos}}
MINOS=${MINOS:-17.0}
case "$SDK" in
  appletvos)        TARGET="arm64-apple-tvos$MINOS" ;;
  appletvsimulator) TARGET="arm64-apple-tvos$MINOS-simulator" ;;
  *) echo "tvos/build.sh: SDK must be appletvos or appletvsimulator (got $SDK)" >&2; exit 2 ;;
esac
OUT="$ROOT/out/$SDK"
FF="$ROOT/third_party/ffmpeg-$SDK"
SYSROOT=${SYSROOT:-$(xcrun --sdk "$SDK" --show-sdk-path)}
CC="xcrun -sdk $SDK clang -target $TARGET -isysroot $SYSROOT"
# The runtime's flags (runtime/build.sh) as Setup builds it (NFS_PUBLIC=1), plus the Apple TV host's headers; the
# translated game's flags are recomp.CFLAGS.
RT_FLAGS="-O1 -g -w -DSAVE_TIMING_ENABLED -DNFS_PUBLIC=1 -DNFS_TV=1 -I$ROOT/recomp -I$ROOT/recomp/out -I$ROOT/runtime -I$ROOT/tvos/host -I$OUT/inc -I$FF/include -fobjc-arc"
GEN_FLAGS="-O2 -w -mllvm -capture-tracking-max-uses-to-explore=100000 -I$ROOT/recomp -I$ROOT/recomp/out"
CXX_FLAGS="-std=c++17 -O2 -w -I$FF/include -I$ROOT/tvos/host"

# One job: "<kind> <source>". Prints "FAILED <source>" and its first errors on failure.
compile() {
    kind=$1 src=$2
    b=$(basename "$src"); b=${b%.*}
    case "$kind" in
      gen)  obj="$OUT/obj/gen/$b.o";  flags="$GEN_FLAGS" ;;
      rt)   obj="$OUT/obj/rt/$b.o";   flags="$RT_FLAGS" ;;
      host) obj="$OUT/obj/host/$b.o"; flags="$RT_FLAGS" ;;
      cxx)  obj="$OUT/obj/cxx/$b.o";  flags="$CXX_FLAGS" ;;
    esac
    case "$src" in
      *.cpp) lang="-x c++ -std=c++17" ;;
      *.mm)  lang="-x objective-c++ -std=c++17" ;;
      *)     lang="" ;;
    esac
    extra=""
    [ "$kind" = rt ] || [ "$kind" = host ] && extra="-DPORT_BUILD_ID=\"\\\"$BUILD_ID\\\"\""
    # boot.c's main() is the game's entry point; the app's main() is UIApplicationMain (tvos/app/main.m -> tv_app.m).
    [ "$src" = runtime/boot.c ] && extra="$extra -Dmain=nfsmw_main"
    sum=$( (cat "$src"; echo "$CC $flags $lang $extra $HEADERS_SUM") | shasum | cut -c1-40)
    if [ -f "$obj" ] && [ "$(cat "$obj.sum" 2>/dev/null)" = "$sum" ]; then return 0; fi
    rm -f "$obj" "$obj.sum"
    if out=$(eval $CC $flags $lang $extra -c "\"$src\"" -o "\"$obj\"" 2>&1); then
        echo "$sum" > "$obj.sum"
        echo "  compiled $src"
    else
        echo "FAILED $src"; printf '%s\n' "$out" | grep -E "error" | head -"${ERRLINES:-8}"
        return 1
    fi
}
# xargs runs each job in a fresh sh running this script with _TV_COMPILE_ONE set (POSIX sh can't export functions).
if [ -n "${_TV_COMPILE_ONE:-}" ]; then compile "$1" "$2"; exit $?; fi

J=${J:-$(sysctl -n hw.ncpu)}
[ -f recomp/out/funcs.h ] && [ -f recomp/out/table.c ] || { echo "tvos/build.sh: recomp/out is missing: run tvos/prepare.sh" >&2; exit 1; }
[ -f runtime/gen/inputs.txt ] || { echo "tvos/build.sh: runtime/gen is missing: run tvos/prepare.sh" >&2; exit 1; }
[ -f "$FF/lib/libavcodec.a" ] || { echo "tvos/build.sh: $FF is missing: run SDK=$SDK tvos/build_ffmpeg.sh" >&2; exit 1; }
mkdir -p "$OUT/obj/gen" "$OUT/obj/rt" "$OUT/obj/host" "$OUT/obj/cxx" "$OUT/inc"
# runtime/app.m's USERDATA/app.txt code (its "offline prefs" block, which the Mac tests extract the same way) for tv_app.m.
sed -n '/BEGIN offline prefs/,/END offline prefs/p' runtime/app.m > "$OUT/inc/app_prefs.inc.new"
grep -q 'END offline prefs' "$OUT/inc/app_prefs.inc.new" || { echo "tvos/build.sh: no prefs block in runtime/app.m" >&2; exit 1; }
if cmp -s "$OUT/inc/app_prefs.inc.new" "$OUT/inc/app_prefs.inc"; then rm "$OUT/inc/app_prefs.inc.new"
else mv "$OUT/inc/app_prefs.inc.new" "$OUT/inc/app_prefs.inc"; fi

# Sources. The runtime list is runtime/build.sh's public list without the Mac-only parts, which tvos/host replaces:
#   app.m, pub_update_launch.m        -> tv_app.m (UIKit, the game thread, folders, preferences, the audio session)
#   rumble.m (IOKit HID)              -> tv_rumble.m (GameController haptics)
#   report.m, report_github.m, report_submit.m, pub_update.m, pub_discord.c, gpuclients.m, cliprec.mm, stream_key.m
#                                     -> tv_stubs.m (problem reports, updates, Discord, GPU clients, clip recording and
#                                        the stream key's AppKit entry panel: off)
MAC_ONLY="app.m pub_update_launch.m rumble.m report.m report_github.m report_submit.m pub_update.m pub_discord.c gpuclients.m cliprec.mm stream_key.m"
# runtime/build.sh's NFS_PUBLIC=1 sources (its public branch, then the clang command's file list), read at build time
RUNTIME=$( (sed -n '/NFS_PUBLIC:-0}" = 1/,/^else/p' runtime/build.sh; sed -n '/^clang \\$/,/speed\.a/p' runtime/build.sh) |
    sed -nE 's/^ *([A-Za-z0-9_]+\.(c|m|mm|cpp)) *\\?$/\1/p' | grep -vxF "$(echo $MAC_ONLY | tr ' ' '\n')" | tr '\n' ' ')
[ -n "$RUNTIME" ] || { echo "tvos/build.sh: no sources found in runtime/build.sh" >&2; exit 1; }
HOST=$(cd tvos/host && ls *.c *.m 2>/dev/null | tr '\n' ' ')
CXX_SRC="host/shaders/sm_parse.cpp host/shaders/sm_msl.cpp host/audio/dsound_host.cpp media/media.cpp"
jobs_list() {
    for f in recomp/out/speed_*.c recomp/out/table.c; do echo "gen $f"; done
    for f in $RUNTIME; do echo "rt runtime/$f"; done
    for f in $HOST; do echo "host tvos/host/$f"; done
    for f in $CXX_SRC; do echo "cxx $f"; done
}

BUILD_ID="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)$(git diff --quiet HEAD 2>/dev/null || echo +) tvOS"
HEADERS_SUM=$(cat recomp/runtime.h recomp/out/funcs.h runtime/*.h runtime/gen/*.inc tvos/host/*.h "$OUT/inc/app_prefs.inc" | shasum | cut -c1-16)
export SDK MINOS SYSROOT BUILD_ID HEADERS_SUM ERRLINES
jobs_list | xargs -P "$J" -L 1 env _TV_COMPILE_ONE=1 sh "$ROOT/tvos/build.sh" || { echo "tvos/build.sh: compile errors (above)" >&2; exit 1; }

# The library: exactly this list's objects (not whatever an older list left in obj/).
object_of() {
    b=$(basename "$2"); b=${b%.*}
    case "$1" in
      gen) echo "$OUT/obj/gen/$b.o" ;;
      rt) echo "$OUT/obj/rt/$b.o" ;;
      host) echo "$OUT/obj/host/$b.o" ;;
      cxx) echo "$OUT/obj/cxx/$b.o" ;;
    esac
}
objs=$(jobs_list | while read -r kind src; do object_of "$kind" "$src"; done)
rm -f "$OUT/libnfsmw.a"
# shellcheck disable=SC2086
libtool -static -o "$OUT/libnfsmw.a" $objs 2>&1 | grep -v "has no symbols" || true
[ -f "$OUT/libnfsmw.a" ] || { echo "tvos/build.sh: libtool failed" >&2; exit 1; }
echo "tvos/build.sh: $OUT/libnfsmw.a ($(du -h "$OUT/libnfsmw.a" | cut -f1))"
