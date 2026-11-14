#!/usr/bin/env bash
#
# 构建 DockFixator.app（Intel + Apple Silicon 通用二进制）
# 用法：
#   ./build.sh              仅构建到 ./build/DockFixator.app
#   ./build.sh --install    构建并安装到 /Applications
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DockFixator"
MIN_MACOS="14.0"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "✗ 未找到 swiftc，请先安装 Xcode 或 Command Line Tools：xcode-select --install"
    exit 1
fi

SOURCES=(Sources/"${APP_NAME}"/*.swift)
if [ ! -e "${SOURCES[0]}" ]; then
    echo "✗ 找不到源码 ${SOURCES[0]}"
    exit 1
fi

echo "→ 清理 ${BUILD_DIR}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

build_slice() {
    local arch="$1"
    local output="${BUILD_DIR}/${APP_NAME}-${arch}"
    echo "→ 编译 ${arch}"
    swiftc -O -swift-version 5 \
        -target "${arch}-apple-macosx${MIN_MACOS}" \
        -framework Cocoa \
        -framework ApplicationServices \
        -framework ServiceManagement \
        -o "${output}" \
        "${SOURCES[@]}"
}

SLICES=()
if build_slice arm64; then
    SLICES+=("${BUILD_DIR}/${APP_NAME}-arm64")
else
    echo "! arm64 编译失败，跳过"
fi

if build_slice x86_64; then
    SLICES+=("${BUILD_DIR}/${APP_NAME}-x86_64")
else
    echo "! x86_64 编译失败，跳过"
fi

if [ ${#SLICES[@]} -eq 0 ]; then
    echo "✗ 编译失败，请检查上面的报错信息"
    exit 1
fi

echo "→ 组装 App Bundle"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
if [ ${#SLICES[@]} -eq 1 ]; then
    cp "${SLICES[0]}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
else
    lipo -create "${SLICES[@]}" -output "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
fi
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

echo "→ 临时签名（ad-hoc）"
if ! codesign --force --sign - --timestamp=none "${APP_BUNDLE}" 2>/dev/null; then
    echo "! 签名失败：程序仍可运行，但每次重新编译后都要重新授予辅助功能权限"
fi

rm -f "${SLICES[@]}"

echo "✓ 已生成 ${APP_BUNDLE}"
printf '  架构: '
lipo -archs "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || echo "unknown"

if [ "${1:-}" = "--install" ]; then
    echo "→ 安装到 /Applications"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_BUNDLE}" "/Applications/${APP_NAME}.app"
    echo "✓ 已安装 /Applications/${APP_NAME}.app，首次运行请在菜单栏图标里授权辅助功能"
    open "/Applications/${APP_NAME}.app"
else
    echo "  运行：open ${APP_BUNDLE}"
    echo "  安装：./build.sh --install"
fi
