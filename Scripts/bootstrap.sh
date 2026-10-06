#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo '缺少开发工具 XcodeGen，请安装后重试（brew install xcodegen）。' >&2
  exit 1
fi
xcodegen generate --spec project.yml

# 生成工程后恢复已审定的依赖锁，避免另一台电脑解析出不同版本。
if [ -f Config/Package.resolved ]; then
  mkdir -p LectoAI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
  cp Config/Package.resolved LectoAI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
fi
