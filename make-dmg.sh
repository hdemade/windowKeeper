#!/bin/bash
# Fabrique WindowKeeper-<version>.dmg à partir de l'app compilée.
#   bash make-dmg.sh            -> utilise l'app du dossier de build (la compile si besoin)
#   APP=/chemin/WindowKeeper.app OUT=/chemin/fichier.dmg bash make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

BUILD_DIR="${BUILD_DIR:-$HOME/Library/Caches/WindowKeeper-build}"
APP="${APP:-$BUILD_DIR/WindowKeeper.app}"
if [ ! -d "$APP" ]; then
    bash build.sh
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")"
OUT="${OUT:-$BUILD_DIR/WindowKeeper-$VERSION.dmg}"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/WindowKeeper.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "WindowKeeper" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
rm -rf "$STAGE"
echo "DMG créé : $OUT"
