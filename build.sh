#!/bin/bash
# Compile WindowKeeper et fabrique WindowKeeper.app.
#   ./build.sh            -> compile seulement
#   ./build.sh install    -> compile, installe dans /Applications et lance l'app
set -euo pipefail
cd "$(dirname "$0")"

# Le dossier de build est hors d'iCloud Drive pour ne pas synchroniser les fichiers intermédiaires.
BUILD_DIR="${BUILD_DIR:-$HOME/Library/Caches/WindowKeeper-build}"

# Avec les Command Line Tools seuls, le SDK macOS 27 déclare @State comme une macro dont le plugin
# (SwiftUIMacros) n'est livré qu'avec Xcode : on compile alors avec le SDK macOS 26 s'il est présent.
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [ -z "${SDKROOT:-}" ] && [ ! -e "$DEV_DIR/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ] \
    && [ ! -e "$DEV_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ] \
    && [ -d "$DEV_DIR/SDKs/MacOSX26.sdk" ]; then
    export SDKROOT="$DEV_DIR/SDKs/MacOSX26.sdk"
    echo "SDK utilisé : $SDKROOT"
fi
swift build -c release --scratch-path "$BUILD_DIR"

APP="$BUILD_DIR/WindowKeeper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD_DIR/release/WindowKeeper" "$APP/Contents/MacOS/WindowKeeper"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
iconutil -c icns AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Une identité de signature stable évite de redonner l'autorisation Accessibilité à chaque recompilation.
SIGN_ID="${SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -n 1 || true)"
fi
SIGN_NAME="$SIGN_ID"
if [ -n "$SIGN_ID" ] && codesign --force --sign "$SIGN_ID" "$APP"; then
    echo "Signature : $SIGN_NAME"
else
    codesign --force --sign - "$APP"
    echo "Signature : ad hoc"
fi
echo "App construite : $APP"

if [ "${1:-}" = "install" ]; then
    DEST="${DEST:-/Applications}"
    pkill -x WindowKeeper 2>/dev/null || true
    sleep 0.5
    if [ -w "$DEST" ]; then
        rm -rf "$DEST/WindowKeeper.app"
        cp -R "$APP" "$DEST/WindowKeeper.app"
    else
        # Compte non administrateur : macOS demande le mot de passe d'un administrateur.
        echo "Mot de passe administrateur nécessaire pour écrire dans $DEST"
        osascript -e "do shell script \"rm -rf '$DEST/WindowKeeper.app' && cp -R '$APP' '$DEST/WindowKeeper.app'\" with administrator privileges"
    fi
    touch "$DEST/WindowKeeper.app" 2>/dev/null || true
    echo "App installée : $DEST/WindowKeeper.app"

    # Les versions précédentes s'installaient dans ~/Applications : on retire cette ancienne copie.
    OLD="$HOME/Applications/WindowKeeper.app"
    if [ "$DEST/WindowKeeper.app" != "$OLD" ] && [ -d "$OLD" ]; then
        rm -rf "$OLD"
        echo "Ancienne copie supprimée : $OLD"
    fi
    open "$DEST/WindowKeeper.app"
fi
