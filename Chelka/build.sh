#!/bin/zsh
# Сборка Chelka.app.
#   ./build.sh                 — собрать в build/
#   ./build.sh install         — собрать и положить в ~/Applications
#   ./build.sh snapshot        — собрать и нарисовать панель в build/snapshot.png
set -euo pipefail
cd "${0:A:h}"

APP="build/Chelka.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/Chelka" \
  Sources/*.swift

codesign --force --sign - --identifier local.Chelka "$APP"
echo "Собрано: $PWD/$APP"

case "${1:-}" in
  install)
    pkill -x Chelka 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Chelka.app
    cp -R "$APP" ~/Applications/
    echo "Установлено: ~/Applications/Chelka.app"
    ;;
  snapshot)
    "$APP/Contents/MacOS/Chelka" --snapshot build/snapshot.png
    echo "Снимок: $PWD/build/snapshot.png"
    ;;
esac
