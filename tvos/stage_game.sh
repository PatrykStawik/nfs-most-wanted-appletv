#!/bin/sh
# Puts the player's PC game folder into the built app as <app>/Game (Xcode runs this after Copy Bundle Resources).
#   NFSMW_GAME   the game folder (the Xcode project's build setting, from GAME when tvos/tv.sh made the project)
# Files are APFS clones (cp -c) of the originals: no second copy on disk, and nothing is re-copied while the folder's
# listing (paths, sizes, dates) is unchanged. The installer's leftovers are not copied.
set -e
GAME=${NFSMW_GAME:?NFSMW_GAME is not set: make the project again with tvos/tv.sh project}
APP="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
DEST="$APP/Game"
[ -f "$GAME/speed.exe" ] || { echo "error: no speed.exe in $GAME (GAME=...)" >&2; exit 1; }
listing=$(cd "$GAME" && find . -type f -not -path './Support/*' -not -path './Uninstall/*' -exec stat -f '%N %z %m' {} + | sort | shasum | cut -c1-40)
if [ -f "$DEST/.staged" ] && [ "$(cat "$DEST/.staged")" = "$listing" ]; then
    echo "stage_game: $DEST up to date"
    exit 0
fi
rm -rf "$DEST"
mkdir -p "$DEST"
( cd "$GAME" && for f in *; do
    case "$f" in
      Support|Uninstall|uninstall.exe|change_language.exe|nfsmwres.exe) continue ;;
    esac
    cp -cR "$f" "$DEST/" 2>/dev/null || cp -R "$f" "$DEST/"
done )
echo "$listing" > "$DEST/.staged"
echo "stage_game: $GAME -> $DEST ($(du -sh "$DEST" | cut -f1))"
