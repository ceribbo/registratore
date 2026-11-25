#!/bin/bash
# Compila e impacchetta Registratore come .app (Dock + barra dei menu).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Registratore.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Registratore "$APP/Contents/MacOS/Registratore"
cp Info.plist "$APP/Contents/Info.plist"

# Icona: genera il PNG e lo converte in .icns
ICONSET=".build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift Icon/make_icon.swift .build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s .build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) .build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Firma: con il certificato personale (vedi crea-certificato.sh) i permessi
# restano validi tra una compilazione e l'altra; altrimenti firma locale.
CERT="Registratore Firma Locale"
if security find-certificate -c "$CERT" >/dev/null 2>&1; then
  codesign --force --deep --sign "$CERT" "$APP"
else
  codesign --force --deep --sign - "$APP"
  echo "Attenzione: firma locale, macOS chiederà di nuovo i permessi. Esegui ./crea-certificato.sh per evitarlo."
fi

echo ""
echo "Fatto: $(pwd)/$APP"
echo "Per installarla:  cp -R \"$APP\" /Applications/ && open \"/Applications/$APP\""
