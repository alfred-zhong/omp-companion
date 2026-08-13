#!/usr/bin/env bash
# 一键构建 omp-companion.app
# 产物：build/omp-companion.app

set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="omp-companion"
BUILD_DIR="build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"

echo "==> swift build (-c ${CONFIG})"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [ ! -x "${BIN_PATH}" ]; then
    echo "错误: 找不到可执行文件 ${BIN_PATH}" >&2
    exit 1
fi

echo "==> 拼 .app bundle → ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "${APP_DIR}"

echo "==> 完成: ${APP_DIR}"
echo "    启动: open ${APP_DIR}"
echo "    调试: ${APP_DIR}/Contents/MacOS/${APP_NAME}"
