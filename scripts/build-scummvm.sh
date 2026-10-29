#!/bin/sh
# Builds the ScummVM that Pisco Sour runs classic games with: official ScummVM plus scummvm-no-splash.patch,
# so games open straight away as apps of their own. Pisco Sour still downloads the official release for the
# data files (themes, engine .dat files); only the binary and its libraries come from here.
# Needs Xcode tools and: brew install sdl3 freetype libpng jpeg-turbo libvorbis flac mad theora faad2 libmpeg2
#   a52dec giflib fribidi libvpx dylibbundler
# Usage: scripts/build-scummvm.sh <work folder>   (output: PiscoSour/ScummVM, not tracked by git)
set -e
VERSION=2026.4.0   # keep in sync with ClassicGames.downloadURL
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$1"; OUT="$ROOT/PiscoSour/ScummVM"
mkdir -p "$WORK"
[ -d "$WORK/src" ] || git clone --depth 1 --branch "v$VERSION" https://github.com/scummvm/scummvm.git "$WORK/src"
cd "$WORK/src"
git apply --check "$ROOT/scripts/scummvm-no-splash.patch" 2>/dev/null && git apply "$ROOT/scripts/scummvm-no-splash.patch"
./configure --enable-release --disable-debug --disable-updates --disable-fluidsynth --disable-discord --disable-sonivox --prefer-sdl3
make -j"$(sysctl -n hw.ncpu)"

rm -rf "$OUT"; mkdir -p "$OUT/libs"
cp scummvm "$OUT/scummvm"
strip -x "$OUT/scummvm"
# Homebrew libraries go along with it; the game apps find them in Contents/Frameworks/libs
dylibbundler -of -b -x "$OUT/scummvm" -d "$OUT/libs" -p @executable_path/../Frameworks/libs/
codesign -f -s - "$OUT/scummvm" "$OUT"/libs/*.dylib
