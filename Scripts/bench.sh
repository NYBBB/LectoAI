#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/bootstrap.sh
xcodebuild -quiet -project LectoAI.xcodeproj -scheme LectoAI -configuration Debug -derivedDataPath build/DerivedData build
exec ./build/DerivedData/Build/Products/Debug/LectoAIBench "$@"
