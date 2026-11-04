#!/bin/zsh
# Сборка DockToggle.app. Запуск: ./build.sh          — собрать в build/
#                              ./build.sh install  — собрать и положить в ~/Applications
set -euo pipefail
cd "${0:A:h}"

APP="build/DockToggle.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/DockToggle" \
  Sources/main.swift

codesign --force --sign - --identifier local.DockToggle "$APP"
echo "Собрано: $PWD/$APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x DockToggle 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/DockToggle.app
  cp -R "$APP" ~/Applications/
  echo "Установлено: ~/Applications/DockToggle.app"
fi
