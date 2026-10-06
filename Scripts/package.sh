#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/bootstrap.sh
identity="${LECTOAI_SIGNING_IDENTITY:--}"
args=(-quiet -project LectoAI.xcodeproj -scheme LectoAI -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData "CODE_SIGN_IDENTITY=$identity")
if [ "$identity" != '-' ]; then
  args+=("DEVELOPMENT_TEAM=${LECTOAI_TEAM:?请配置签名团队}" 'ENABLE_HARDENED_RUNTIME=YES' 'OTHER_CODE_SIGN_FLAGS=--timestamp --options runtime')
else
  # 本机临时签名没有 Team ID，显式关闭 runtime，避免被动态库同团队校验拒绝。
  args+=('ENABLE_HARDENED_RUNTIME=NO' 'OTHER_CODE_SIGN_FLAGS=--options 0')
fi
xcodebuild "${args[@]}" build
app='build/DerivedData/Build/Products/Release/LectoAI.app'
# 两条路径均从内向外重签，避免缓存构建留下旧签名标志。
signing_options=(--options 0)
if [ "$identity" != '-' ]; then
  signing_options=(--options runtime --timestamp)
fi
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for helper in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  codesign --force --sign "$identity" "${signing_options[@]}" --preserve-metadata=entitlements "$sparkle/Versions/B/$helper"
done
codesign --force --sign "$identity" "${signing_options[@]}" "$sparkle"
codesign --force --sign "$identity" "${signing_options[@]}" --preserve-metadata=entitlements "$app"
./Scripts/verify-package.sh "$app" "$identity"
# 每次独立产物目录，不覆盖历史包或用户资料。
stage="$(mktemp -d "$PWD/build/package-XXXXXX")"
ditto "$app" "$stage/LectoAI.app"
./Scripts/verify-package.sh "$stage/LectoAI.app" "$identity"
ln -s /Applications "$stage/Applications"
if [ "$identity" = '-' ]; then
  printf '%s\n' '本包为本机测试构建，未经 Developer ID 签名和公证，不能视为对外发行包。' > "$stage/本机测试说明.txt"
fi
dmg="$stage.dmg"
hdiutil create -quiet -volname LectoAI -srcfolder "$stage" -ov -format UDZO "$dmg"
if [ "$identity" != '-' ]; then
  codesign -dv --verbose=4 "$app" 2>&1 | grep -q 'flags=.*runtime' || { echo '实际签名未启用 Hardened Runtime' >&2; exit 1; }
  xcrun notarytool submit "$dmg" --keychain-profile "${LECTOAI_NOTARY_PROFILE:?请配置公证凭据名称}" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi
printf '%s\n' "$dmg"
