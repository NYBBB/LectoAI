#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
# 直接编译生产回调与定向检查；不用麦克风，不创建课堂记录。
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 -parse-as-library \
  LectoAI/Runtime/PCMSource.swift Checks/AudioCallbackCheck.swift -o build/AudioCallbackCheck
exec build/AudioCallbackCheck
