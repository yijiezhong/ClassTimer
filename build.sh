#!/usr/bin/env bash
#
# 课堂计时器 构建脚本
#
# 版本规则（全局约定）：
#   - 版本号唯一来源是本目录的 VERSION 文件，形如 x.y.z，每一位都是 0-9 的个位数；
#   - 每次构建 z+1，满 9 进位到 y，y 满 9 进位到 x（9.9.9 之后需人工决定，脚本会拒绝）；
#   - 构建号 build 取当前本地时间 YYYYMMDDhhmmss（精确到秒），写入 Info.plist 的 CFBundleVersion；
#   - 不手改 Info.plist 里的版本号，改 VERSION 或用 --bump。
#
# 用法：
#   ./build.sh            构建（读取当前 VERSION）
#   ./build.sh --bump     先把 VERSION 递增一个版本再构建
#   ./build.sh --dry-run  只打印将使用的版本与路径
#   ./build.sh            构建 + 自动安装到 ~/Applications（默认）
#   ./build.sh --no-install  只构建，不安装
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DISPLAY_NAME="ClassTimer"
EXEC_NAME="ClassTimer"
BUNDLE_ID="com.zhongyijie.class-timer"
# 签名证书：优先环境变量 CODESIGN_IDENTITY；没设就自动取本机第一张 Apple Development；
# 都没有则回退 ad-hoc。公开仓库不写死个人证书名。
# 为什么不用 ad-hoc：ad-hoc 的签名随二进制变化，TCC（屏幕录制等权限）认不出是同一个 app，
# 每次构建都要重新授权；固定证书后权限记录可以长期复用。
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
BUILD_DIR="$ROOT/build"
APP_PATH="$BUILD_DIR/$APP_DISPLAY_NAME.app"

BUMP=0
DRY_RUN=0
INSTALL=1   # 默认就装到 ~/Applications，--no-install 可跳过
for arg in "$@"; do
  case "$arg" in
    --bump) BUMP=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --install) INSTALL=1 ;;
    --no-install) INSTALL=0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg" >&2; exit 1 ;;
  esac
done

VERSION_FILE="$ROOT/VERSION"
CURRENT_VERSION="$(head -n1 "$VERSION_FILE" | tr -d '[:space:]')"
if ! [[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION 内容不合法：$CURRENT_VERSION（应形如 1.2.3）" >&2
  exit 1
fi

if [[ "$BUMP" == "1" ]]; then
  IFS='.' read -r major minor patch <<< "$CURRENT_VERSION"
  if (( patch < 9 )); then
    patch=$((patch + 1))
  elif (( minor < 9 )); then
    patch=0; minor=$((minor + 1))
  elif (( major < 9 )); then
    patch=0; minor=0; major=$((major + 1))
  else
    echo "已经是 9.9.9，按约定需人工决定是否归零循环。" >&2
    exit 1
  fi
  NEXT_VERSION="${major}.${minor}.${patch}"
  if [[ "$DRY_RUN" == "0" ]]; then
    echo "$NEXT_VERSION" > "$VERSION_FILE"
    echo "==> 版本递增：$CURRENT_VERSION -> $NEXT_VERSION"
    CURRENT_VERSION="$NEXT_VERSION"
  else
    echo "==> [dry-run] 版本将递增：$CURRENT_VERSION -> $NEXT_VERSION"
    CURRENT_VERSION="$NEXT_VERSION"
  fi
fi

BUILD_NUMBER="$(date '+%Y%m%d%H%M%S')"

echo "==> 构建 $APP_DISPLAY_NAME $CURRENT_VERSION ($BUILD_NUMBER)"
echo "    输出：$APP_PATH"
if [[ "$DRY_RUN" == "1" ]]; then
  exit 0
fi

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

swiftc \
  -O \
  -swift-version 5 \
  -module-name ClassTimer \
  -target "$(uname -m)-apple-macosx14.0" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  -o "$APP_PATH/Contents/MacOS/$EXEC_NAME" \
  "$ROOT"/Sources/*.swift

# 音效资源（木鱼 / 结束提醒）
if [ -d "$ROOT/Resources" ]; then
  cp "$ROOT"/Resources/*.wav "$APP_PATH/Contents/Resources/" 2>/dev/null || true
fi

# App 图标：正常拷贝 assets/AppIcon.icns。该文件不在父仓库 .gitignore 的白名单里
# （白名单只收了 *.png），新 clone 可能没有 icns；此时用已入库的 iconset 现场重建，
# 避免静默产出一个没有图标的 app。
ICON_SRC="$ROOT/assets/AppIcon.icns"
if [ ! -f "$ICON_SRC" ] && [ -d "$ROOT/assets/AppIcon.iconset" ]; then
  iconutil -c icns -o "$ICON_SRC" "$ROOT/assets/AppIcon.iconset"
  echo "==> 已从 iconset 重建 AppIcon.icns"
fi
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APP_PATH/Contents/Resources/AppIcon.icns"
else
  echo "警告：assets/AppIcon.icns 与 iconset 都缺失，产物将没有图标" >&2
fi

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$EXEC_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$CURRENT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.zhongyijie.class-timer</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>classtimer</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [[ -n "$CODESIGN_IDENTITY" ]]; then
  codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP_PATH" >/dev/null 2>&1 || {
    echo "签名失败：无法用 $CODESIGN_IDENTITY 签名" >&2
    exit 1
  }
  echo "==> 已签名：$CODESIGN_IDENTITY"
else
  # 没证书的机器退回 ad-hoc，保证还能本地运行
  codesign --force --sign - "$APP_PATH" >/dev/null 2>&1 || {
    echo "ad-hoc 签名失败" >&2
    exit 1
  }
  echo "==> 已签名：ad-hoc（本机无 Apple Development 证书）"
fi

echo "==> 构建完成：$APP_PATH"
echo "    $APP_DISPLAY_NAME $CURRENT_VERSION ($BUILD_NUMBER)"

if [[ "$INSTALL" == "1" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  rm -rf "$DEST/$APP_DISPLAY_NAME.app"
  cp -R "$APP_PATH" "$DEST/"
  echo "==> 已安装到：$DEST/$APP_DISPLAY_NAME.app"
fi
