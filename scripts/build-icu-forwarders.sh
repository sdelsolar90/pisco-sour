#!/bin/sh
# Windows 10 ships an unversioned ICU (icuuc.dll, icuin.dll, icu.dll) that Qt 6 apps link against; Wine doesn't.
# This builds those DLLs as forwarders to the official ICU4C Win64 release (versioned exports, e.g. ucnv_open_79).
# Needs: brew install mingw-w64. Usage: scripts/build-icu-forwarders.sh <icu4c bin64 folder> <version, e.g. 79>
set -e
BIN="$1"; V="$2"; OUT="$(dirname "$0")/../PiscoSour/WindowsICU"
TMP="$(mktemp -d)"
for lib in uc in; do
  x86_64-w64-mingw32-objdump -p "$BIN/icu${lib}${V}.dll" | awk '/\+base\[/{print $NF}' \
    | grep -E "^[A-Za-z][A-Za-z0-9_]*_${V}\$" > "$TMP/$lib.names"
  { echo "LIBRARY icu${lib}.dll"; echo "EXPORTS"
    sed -E "s/^(.*)_${V}\$/  \1 = icu${lib}${V}.\1_${V}/" "$TMP/$lib.names"; } > "$TMP/icu${lib}.def"
  x86_64-w64-mingw32-gcc -shared -nostdlib -o "$OUT/icu${lib}.dll" "$TMP/icu${lib}.def"
  cp "$BIN/icu${lib}${V}.dll" "$OUT/"
done
{ echo "LIBRARY icu.dll"; echo "EXPORTS"
  sed -E "s/^(.*)_${V}\$/  \1 = icuuc${V}.\1_${V}/" "$TMP/uc.names"
  sed -E "s/^(.*)_${V}\$/  \1 = icuin${V}.\1_${V}/" "$TMP/in.names"; } > "$TMP/icu.def"
x86_64-w64-mingw32-gcc -shared -nostdlib -o "$OUT/icu.dll" "$TMP/icu.def"
cp "$BIN/icudt${V}.dll" "$OUT/"
rm -rf "$TMP"
