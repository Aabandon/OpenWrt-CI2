#!/bin/bash
# shellcheck disable=SC2154,SC2086  # 变量由 CI 注入；$COLLECTIONS 需要按空格拆分
# 修改默认主题 / IP / 主机名 / 时区
# 执行位置：openwrt 源码根目录，且必须在 `feeds install` 之前

# ---- 按需删除冲突插件 ----
#rm -rf $(find ./feeds/luci/ -type d -regex ".*\(alist\).*")
#rm -rf $(find ./feeds/packages/ -type d -regex ".*\(alist\).*")

# ---- 删除源码自带的 rtp2httpd / luci-app-openclash ----
# 这里先清掉 feeds / package 里的同名包，避免 `feeds install -a` 又把旧版装回去
# （feeds update 已经执行过，此时 ./feeds 下是本次同步的内容）
for pkg in rtp2httpd luci-app-rtp2httpd openclash luci-app-openclash; do
  if [ -d ./feeds ]; then
    find ./feeds -maxdepth 5 -type d -name "$pkg" \
      -prune -print -exec rm -rf {} + 2>/dev/null || true
  fi
  rm -rf "./package/$pkg" 2>/dev/null || true
  rm -rf ./package/feeds/*/"$pkg" 2>/dev/null || true
done
# 重建 feeds 索引，避免 `feeds install -a` 还按旧索引去找已删除的包
if [ -x ./scripts/feeds ]; then
  ./scripts/feeds update -i >/dev/null 2>&1 || true
fi

# ---- 默认主题：把 luci 集合里的 bootstrap 替换成指定主题 ----
COLLECTIONS="$(find ./feeds/luci/collections/ -type f -name 'Makefile' 2>/dev/null)"
if [ -n "$COLLECTIONS" ]; then
  sed -i "s/luci-theme-bootstrap/luci-theme-$OpenWrt_THEME/g" $COLLECTIONS
else
  echo "::warning::未找到 feeds/luci/collections，跳过默认主题修改"
fi

# ---- 默认 IP / 主机名 / 时区 ----
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

# autocore: 启用 airoha 首页温度行（CPU/PON/WiFi）
# 用 CI 仓库 Files/autocore/ 下的同名文件覆盖源码仓库对应文件
if [ -d package/emortal/autocore ] && [ -d "$GITHUB_WORKSPACE/Files/autocore" ]; then
	cp -f "$GITHUB_WORKSPACE/Files/autocore/Makefile" package/emortal/autocore/Makefile
	cp -f "$GITHUB_WORKSPACE/Files/autocore/files/tempinfo" package/emortal/autocore/files/tempinfo
	chmod 755 package/emortal/autocore/files/tempinfo
fi

echo "Settings.sh 执行完成"
