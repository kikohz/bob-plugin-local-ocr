#!/bin/bash
# 编译并安装 bob-local-ocr 服务（LaunchAgent，登录后自动运行）。
#
# 用法:
#   ./install.sh             安装或更新服务
#   ./install.sh uninstall   卸载服务（同时删除模型编译缓存）
#
# 可选环境变量:
#   BOB_OCR_PORT=50888       服务端口，需与 Bob 插件设置中的端口一致
set -euo pipefail

LABEL="com.kikohz.bob-local-ocr"
PORT="${BOB_OCR_PORT:-50888}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Library/Application Support/BobLocalOCR"
BIN="$APP_DIR/bob-local-ocr"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/bob-local-ocr.log"
CACHE="$HOME/Library/Caches/bob-local-ocr"
DOMAIN="gui/$(id -u)"

die() {
  echo "错误: $*" >&2
  exit 1
}

unload() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
}

if [[ "${1:-}" == "uninstall" ]]; then
  unload
  rm -f "$PLIST"
  rm -rf "$APP_DIR" "$CACHE"
  echo "已卸载服务。日志保留在 $LOG，可手动删除。"
  echo "Bob 插件请在 Bob 偏好设置 → 插件 中删除。"
  exit 0
fi

echo "==> 检查环境"
major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$major" -ge 13 ]] || die "需要 macOS 13 或更高版本（当前 $(sw_vers -productVersion)）"
command -v swiftc >/dev/null 2>&1 ||
  die "找不到 swiftc。请先运行 xcode-select --install 安装命令行工具"
for pid in $(lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null); do
  [[ "$(ps -o comm= -p "$pid")" == *bob-local-ocr ]] ||
    die "端口 $PORT 已被其他程序占用，请换一个端口: BOB_OCR_PORT=50889 ./install.sh"
done

echo "==> 编译服务"
mkdir -p "$APP_DIR" "$(dirname "$PLIST")" "$ROOT/dist"
swiftc -O -swift-version 5 "$ROOT/server/main.swift" -o "$ROOT/dist/bob-local-ocr"

echo "==> 安装 LaunchAgent"
unload
cp "$ROOT/dist/bob-local-ocr" "$BIN"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>BOB_OCR_PORT</key>
    <string>$PORT</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
  <key>StandardOutPath</key>
  <string>$LOG</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "==> 检查服务"
for _ in $(seq 1 20); do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break
  sleep 0.5
done
curl -sf "http://127.0.0.1:$PORT/health" >/dev/null || die "服务没有启动，请查看日志: $LOG"

echo "服务已启动: http://127.0.0.1:$PORT"
echo "首次运行会在后台编译 OCR 模型（约 1~2 分钟），进度见: tail -f \"$LOG\""
