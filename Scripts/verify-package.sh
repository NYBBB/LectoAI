#!/bin/bash
set -euo pipefail
app="${1:?需要应用路径}"
identity="${2:--}"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
# 完整性通过不等于运行时可加载，额外检查 runtime 标志及团队一致性。
codesign --verify --deep --strict "$app"
objects=("$app" "$sparkle" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/XPCServices/Downloader.xpc")
app_team=''
for object in "${objects[@]}"; do
  details="$(codesign -dv --verbose=4 "$object" 2>&1)"
  team="$(sed -n 's/^TeamIdentifier=//p' <<< "$details")"
  if [ "$identity" = '-' ]; then
    if [[ "$details" == *'runtime)'* || "$details" == *'runtime,'* ]] || [ "$team" != 'not set' ]; then
      echo "临时签名包存在不兼容的 runtime 或团队标志：$object" >&2
      exit 1
    fi
  else
    if [[ "$details" != *'runtime)'* && "$details" != *'runtime,'* ]] || [ -z "$team" ] || [ "$team" = 'not set' ]; then
      echo "正式签名缺少 runtime 或 Team ID：$object" >&2
      exit 1
    fi
    if [ -n "$app_team" ] && [ "$app_team" != "$team" ]; then
      echo "组件签名与主程序团队不一致：$object" >&2
      exit 1
    fi
    app_team="$team"
  fi
done
# 沙盒不会因本机签名策略而关闭，也不加入禁用动态库校验的豁免权限。
entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null)"
/usr/bin/grep -q '<key>com.apple.security.app-sandbox</key><true/>' <<< "$entitlements" || { echo '应用缺少沙盒权限声明' >&2; exit 1; }
if /usr/bin/grep -q 'com.apple.security.cs.disable-library-validation' <<< "$entitlements"; then
  echo '应用不应包含禁用动态库校验的豁免权限' >&2
  exit 1
fi
