#!/bin/bash
# shellcheck disable=SC2154  # OpenWrt_* 变量由 GitHub Actions 注入
# 批量重命名产物为 <TARGET>_<原名>_<日期>.<ext>
# 说明：默认未启用；产物统一由 OpenWrt-CORE 的 Package Firmware 步骤整理

[ -z "$OpenWrt_TYPE" ] && exit 0

for var in $OpenWrt_TYPE; do
  find ./ -maxdepth 1 -type f -iname "*${var}*" ! -iname "*.txt" | while IFS= read -r file; do
    base="$(basename "$file")"
    name="$(echo "$base" | grep -io "\(${var}\).*" | cut -d '.' -f 1)"
    ext="${base#*.}"
    mv -f "$file" "${OpenWrt_TARGET}_${name}_${OpenWrt_DATE}.${ext}"
  done
done
