#!/bin/bash
# shellcheck disable=SC2154,SC2086  # CI 变量 / COLLECTIONS 需按空格拆分
# 主题 / IP / 主机名 / 时区 / 平台文件覆盖；源码根目录执行，须在 feeds install 前

# 默认主题
COLLECTIONS="$(find ./feeds/luci/collections/ -type f -name 'Makefile' 2>/dev/null)"
if [ -n "$COLLECTIONS" ]; then
  sed -i "s/luci-theme-bootstrap/luci-theme-$OpenWrt_THEME/g" $COLLECTIONS
else
  echo "::warning::未找到 feeds/luci/collections，跳过默认主题修改"
fi

# IP / 主机名 / 时区
GEN=./package/base-files/files/bin/config_generate
if [ -f "$GEN" ]; then
  sed -i "s/192\.168\.[0-9]*\.[0-9]*/$OpenWrt_IP/g" "$GEN"
  sed -i "s/hostname='.*'/hostname='$OpenWrt_NAME'/g" "$GEN"
  sed -i "s/timezone='.*'/timezone='CST-8'/g" "$GEN"
  if ! grep -q "zonename='Asia/Shanghai'" "$GEN"; then
    sed -i "/timezone='CST-8'/a\\\t\t\tset system.@system[-1].zonename='Asia/Shanghai'" "$GEN"
  fi
else
  echo "::warning::未找到 $GEN，跳过 IP/主机名/时区修改"
fi

# 平台文件覆盖：ReplacementFiles/<平台>/<源码内相对路径> 覆盖到源码根目录同名文件
# 例如 ReplacementFiles/op-an758x-pbs05/package/emortal/autocore/files/tempinfo
#      → package/emortal/autocore/files/tempinfo
OVERLAY_DIR="$GITHUB_WORKSPACE/ReplacementFiles/${OpenWrt_TARGET}"
# .gitkeep 仅用于让空目录入库，不参与覆盖
if [ ! -d "$OVERLAY_DIR" ]; then
  echo "[ReplacementFiles] 平台 $OpenWrt_TARGET 无覆盖目录，保留源码自带文件"
elif ! find "$OVERLAY_DIR" -type f ! -name '.gitkeep' -print -quit | grep -q .; then
  echo "[ReplacementFiles] 平台 $OpenWrt_TARGET 覆盖目录为空，保留源码自带文件"
else
  OVERLAY_COUNT=0
  while IFS= read -r -d '' src; do
    rel="${src#"$OVERLAY_DIR"/}"
    mkdir -p "$(dirname "$rel")"
    cp -p "$src" "$rel"
    echo "[ReplacementFiles] 覆盖 $rel"
    OVERLAY_COUNT=$((OVERLAY_COUNT + 1))
  done < <(find "$OVERLAY_DIR" -type f ! -name '.gitkeep' -print0)
  echo "[ReplacementFiles] 平台 $OpenWrt_TARGET 共覆盖 $OVERLAY_COUNT 个文件"
fi

echo "Settings.sh 执行完成"
