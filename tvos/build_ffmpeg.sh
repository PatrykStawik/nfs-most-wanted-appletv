#!/bin/sh
# Builds the static FFmpeg 7.1.1 for the Apple TV (the same components as media/build_ffmpeg.sh, minus the programs).
#   tvos/build_ffmpeg.sh                       Apple TV device -> third_party/ffmpeg-appletvos
#   SDK=appletvsimulator tvos/build_ffmpeg.sh  tvOS simulator  -> third_party/ffmpeg-appletvsimulator
# Source: third_party/dl/ffmpeg-7.1.1.tar.xz (the pinned tarball media/build_ffmpeg.sh checks), built out of tree so the
# Mac build in third_party/src/ffmpeg-7.1.1 keeps its own configuration.
set -e
cd "$(dirname "$0")/.."
T="$PWD/third_party"
SDK=${SDK:-appletvos}
MINOS=${MINOS:-17.0}
SHA=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1
ARCHIVE="$T/dl/ffmpeg-7.1.1.tar.xz"
PREFIX="$T/ffmpeg-$SDK"
[ -f "$ARCHIVE" ] || { echo "FFmpeg source missing: $ARCHIVE (https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz)" >&2; exit 1; }
echo "$SHA  $ARCHIVE" | shasum -a 256 -c - >/dev/null 2>&1 || { echo "FFmpeg 7.1.1 checksum failed: $ARCHIVE" >&2; exit 1; }
[ -d "$T/src/ffmpeg-7.1.1" ] || { mkdir -p "$T/src" && tar -xJf "$ARCHIVE" -C "$T/src"; }
# Already built for this SDK and minimum version: nothing to do.
STAMP="$PREFIX/.built-$SDK-$MINOS"
[ -f "$STAMP" ] && [ -f "$PREFIX/lib/libavcodec.a" ] && { echo "ok: $PREFIX (up to date)"; exit 0; }
case "$SDK" in
  appletvos)        VMIN="-mtvos-version-min=$MINOS" ;;
  appletvsimulator) VMIN="-mtvos-simulator-version-min=$MINOS" ;;
  *) echo "SDK must be appletvos or appletvsimulator" >&2; exit 2 ;;
esac
SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
B="$T/build/ffmpeg-$SDK"
rm -rf "$B" "$PREFIX"
mkdir -p "$B"
cd "$B"
"$T/src/ffmpeg-7.1.1/configure" --prefix="$PREFIX" --enable-cross-compile --target-os=darwin --arch=aarch64 \
  --cc="xcrun -sdk $SDK clang" --cxx="xcrun -sdk $SDK clang++" --sysroot="$SYSROOT" \
  --extra-cflags="-arch arm64 $VMIN" --extra-ldflags="-arch arm64 $VMIN" \
  --enable-static --disable-shared --disable-doc --disable-network --disable-autodetect --disable-programs \
  --enable-zlib --disable-everything \
  --enable-decoder='wmv3,wmapro,xma1,wmav2,vp6,vp6f,vp6a,adpcm_ea,adpcm_ea_r1,adpcm_ea_r2,adpcm_ea_r3,adpcm_ea_xas,pcm_s16le,pcm_f32le,ac3,eac3,truehd,mp3' \
  --enable-demuxer='asf,ea,wav,ac3,eac3,spdif' \
  --enable-encoder='ac3,eac3,truehd,pcm_s16le,png,rawvideo' \
  --enable-muxer='spdif,wav,ac3,eac3,image2,rawvideo,null' \
  --enable-parser='ac3,mlp,vc1' --enable-protocol='file,pipe' \
  --enable-filter='aresample,scale,format,null,anull,aformat,pan' \
  --enable-swscale --enable-swresample > "$T/ffmpeg-$SDK-configure.log" 2>&1 || { tail -20 "$T/ffmpeg-$SDK-configure.log"; exit 1; }
make -j"${JOBS:-$(sysctl -n hw.ncpu)}" > "$T/ffmpeg-$SDK-make.log" 2>&1 || { tail -30 "$T/ffmpeg-$SDK-make.log"; exit 1; }
make install >> "$T/ffmpeg-$SDK-make.log" 2>&1
touch "$STAMP"
echo "ok: $PREFIX"
