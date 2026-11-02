#!/bin/sh
# Mac 用：Xcode プロジェクトを作って開く
set -e
cd "$(dirname "$0")"

if ! command -v xcodebuild >/dev/null 2>&1 || ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode が見つかりません。App Store から Xcode をインストールしてから、もう一度実行してください。"
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew をインストールします（パスワードを聞かれたら Mac のログインパスワードを入力）"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
  fi
  brew install xcodegen
fi

# バンドルID を自分専用のものにする（他人と被ると登録できないため）
if grep -q "com.example.videosaver" project.yml; then
  NAME=$(whoami | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z')
  sed -i '' "s/com.example.videosaver/com.${NAME}$(date +%m%d).videosaver/" project.yml
fi

xcodegen generate
open VideoSaver.xcodeproj
echo ""
echo "Xcode が開きました。README の「Xcode での操作」に進んでください。"
