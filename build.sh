#!/bin/sh
# Compila Foco.app em build/ e copia para /Applications
set -e
cd "$(dirname "$0")"
APP=build/Foco.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 Sources/*.swift -o "$APP/Contents/MacOS/Foco"
cp Info.plist "$APP/Contents/"
# ícone: icon.png (gerado por `swift icon.swift`) -> AppIcon.icns
mkdir -p "$APP/Contents/Resources" build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
# assinatura estável: o macOS mantém as permissões entre builds (certificado "Foco Dev" no Chaves)
codesign --force -s "Foco Dev" "$APP"
rm -rf /Applications/Foco.app && cp -R "$APP" /Applications/
echo "ok: /Applications/Foco.app"
