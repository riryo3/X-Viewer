#!/bin/sh
# X-Viewer.app を作るスクリプト。Xcode（または開発者ツール）が入っていれば動きます。
set -e
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "コンパイラが見つかりません。表示される案内に従って開発者ツールを入れてから、もう一度実行してください。"
  xcode-select --install || true
  exit 1
fi

APP="X-Viewer.app"
echo "ビルド中..."
rm -rf "$APP" "Xだけ.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -framework Cocoa -framework WebKit main.swift -o "$APP/Contents/MacOS/XOnly"
codesign --force --deep -s - "$APP" 2>/dev/null || true

echo ""
echo "できました: $(pwd)/$APP"
echo "このフォルダの「X-Viewer.app」をダブルクリックすると起動します。"
echo "気に入ったら「アプリケーション」フォルダへドラッグしておくと便利です。"
