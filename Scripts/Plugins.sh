#!/bin/bash
# shellcheck disable=SC2154  # OpenWrt_* 变量由 GitHub Actions 注入
# 插件：判断同名 → 删旧 → 拉取；package/ 下执行，须在 feeds install -a 前

# 平台配置（CI 注入 OpenWrt_TARGET）
CI_CONFIG="${GITHUB_WORKSPACE}/${OpenWrt_CONFIG_FILE:-Config/$OpenWrt_TARGET.txt}"

# AN758X 判定（配置里 CONFIG_TARGET_airoha=y）
is_airoha() {
  [ -f "$CI_CONFIG" ] && grep -qE '^[[:space:]]*CONFIG_TARGET_airoha=y([[:space:]]|$)' "$CI_CONFIG"
}

# 删同名旧包：feeds 源在 ../feeds，install 软链在 ./feeds/；检测到才删
remove_pkg() {
  local pkg="$1" hit removed=0

  hit="$(find ../feeds -maxdepth 6 -type d -name "$pkg" -print -quit 2>/dev/null)"
  if [ -n "$hit" ]; then
    find ../feeds -maxdepth 6 -type d -name "$pkg" -prune -exec rm -rf {} + 2>/dev/null || true
    echo "[替换] $pkg：删除 feeds 源里的同名包"
    removed=1
  fi

  hit="$(find ./feeds -maxdepth 6 \( -type l -o -type d \) -name "$pkg" -print -quit 2>/dev/null)"
  if [ -n "$hit" ]; then
    find ./feeds -maxdepth 6 \( -type l -o -type d \) -name "$pkg" -exec rm -rf {} + 2>/dev/null || true
    echo "[替换] $pkg：删除 feeds install 生成的软链"
    removed=1
  fi

  if [ -e "./$pkg" ]; then
    rm -rf "./$pkg"
    echo "[替换] $pkg：删除 package 下的同名包"
    removed=1
  fi

  [ "$removed" = "1" ] || echo "[准备] $pkg：源码与 feeds 中均无同名包"
}

# clone_pkg <url> <branch> <目录>：删同名后克隆
clone_pkg() {
  local url="$1" branch="$2" dir="$3"

  remove_pkg "$dir"

  if [ -n "$branch" ]; then
    git clone --depth=1 --single-branch --branch "$branch" "$url" "$dir" \
      || echo "::warning::克隆失败（构建继续，相关配置项会被忽略）: $url ($branch)"
  else
    git clone --depth=1 --single-branch "$url" "$dir" \
      || echo "::warning::克隆失败（构建继续，相关配置项会被忽略）: $url"
  fi
}

# 探测目标架构：优先 .config，否则读平台配置（含 #!DEFCONFIG 时读源码自带）
detect_target() {
  local cfg def

  if [ -f ../.config ]; then
    TARGET_BOARD="$(sed -n 's/^CONFIG_TARGET_BOARD="\(.*\)"/\1/p' ../.config | head -n1)"
    TARGET_SUB="$(sed -n 's/^CONFIG_TARGET_SUBTARGET="\(.*\)"/\1/p' ../.config | head -n1)"
    TARGET_ARCH="$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"/\1/p' ../.config | head -n1)"
    return 0
  fi

  cfg="$GITHUB_WORKSPACE/${OpenWrt_CONFIG_FILE:-Config/$OpenWrt_TARGET.txt}"
  [ -f "$cfg" ] || return 0

  def="$(sed -n 's/^#!DEFCONFIG=[[:space:]]*//p' "$cfg" | head -n1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
  if [ -n "$def" ] && [ -f "../$def" ]; then
    cfg="../$def"
  fi

  TARGET_BOARD="$(sed -n 's/^CONFIG_TARGET_BOARD="\(.*\)"/\1/p' "$cfg" | head -n1)"
  TARGET_SUB="$(sed -n 's/^CONFIG_TARGET_SUBTARGET="\(.*\)"/\1/p' "$cfg" | head -n1)"
  TARGET_ARCH="$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\(.*\)"/\1/p' "$cfg" | head -n1)"
}

# clone_repo <url> <ref>：拉整仓，把含 Makefile 的包（根/子目录）放进 package/
clone_repo() {
  local url="$1" ref="$2" tmp pkg d

  tmp="$(mktemp -d)"
  if ! git clone --depth=1 --single-branch --branch "$ref" "$url" "$tmp/src"; then
    echo "::warning::克隆失败: $url ($ref)"
    rm -rf "$tmp"
    return 0
  fi

  # 仓库根目录本身就是包
  if [ -f "$tmp/src/Makefile" ]; then
    pkg="$(basename "$url" .git)"
    remove_pkg "$pkg"
    mv "$tmp/src" "./$pkg"
    echo "已放入插件: $pkg"
  else
    # 包在子目录：凡是含 Makefile 的一级目录都取出来
    for d in "$tmp/src"/*; do
      [ -f "$d/Makefile" ] || continue
      pkg="$(basename "$d")"
      remove_pkg "$pkg"
      mv "$d" "./$pkg"
      echo "已放入插件: $pkg"
    done
  fi
  rm -rf "$tmp"
}

# OpenClash 内核预置：下载内核 → 校验 → 放进包目录（包内已自带 mmdb/GeoSite）
fetch_openclash_core() {
  local pkg_dir=./luci-app-openclash
  local core_dir="$pkg_dir/root/etc/openclash/core"
  local base tarball tmp want got ver kind dest line versions

  if [ ! -d "$pkg_dir" ]; then
    echo "::warning::[OpenClash] 没有 $pkg_dir 目录，跳过内核预置"
    return 0
  fi

  detect_target

  case "${TARGET_ARCH:-}" in
    aarch64*)  CORE_ARCH=arm64 ;;
    arm_*)     CORE_ARCH=armv7 ;;
    x86_64)    CORE_ARCH=amd64 ;;
    i386*)     CORE_ARCH=386 ;;
    mips64el*) CORE_ARCH=mips64le ;;
    mips64*)   CORE_ARCH=mips64 ;;
    mipsel*)   CORE_ARCH=mipsle-softfloat ;;
    mips*)     CORE_ARCH=mips-softfloat ;;
    riscv64*)  CORE_ARCH=riscv64 ;;
    *)
      echo "::warning::[OpenClash] 未识别的目标架构 [${TARGET_ARCH:-空}]，跳过内核预置"
      return 0
      ;;
  esac

  echo "[OpenClash] 检测到平台: ${TARGET_BOARD:-未知}/${TARGET_SUB:-未知}  架构: ${TARGET_ARCH}"
  echo "[OpenClash] 对应内核架构: ${CORE_ARCH}"

  # 上游版本号（core/master/core_version：第 1 行 meta，第 2 行 smart）
  versions="$(curl -fsSL --retry 3 --retry-delay 2 \
    https://raw.githubusercontent.com/vernesong/OpenClash/core/master/core_version 2>/dev/null \
    | tr -d '\r')"

  mkdir -p "$core_dir"

  # meta → clash_meta，smart → clash_smart
  line=0
  for kind in meta smart; do
    line=$((line + 1))
    case "$kind" in
      meta)  dest="clash_meta" ;;
      smart) dest="clash_smart" ;;
    esac

    ver="$(printf '%s\n' "$versions" | sed -n "${line}p")"
    [ -n "$ver" ] && echo "[OpenClash] 上游 $kind 内核版本: $ver"

    base="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/$kind"
    tarball="clash-linux-${CORE_ARCH}.tar.gz"
    tmp="$(mktemp -d)"

    echo "[OpenClash] 下载 $kind: $base/$tarball"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/$tarball" "$base/$tarball"; then
      echo "::warning::[OpenClash] $kind 内核下载失败，跳过（设备端首次启动可自行下载）"
      rm -rf "$tmp"
      continue
    fi

    # 上游 checksums.txt 形如: <sha256>  ./clash-linux-arm64.tar.gz
    if curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$base/checksums.txt"; then
      want="$(awk -v f="./$tarball" '$2 == f { print $1 }' "$tmp/checksums.txt")"
      got="$(sha256sum "$tmp/$tarball" | awk '{ print $1 }')"
      if [ -n "$want" ] && [ "$want" != "$got" ]; then
        echo "::warning::[OpenClash] $kind 内核校验失败（期望 $want，实际 $got），跳过"
        rm -rf "$tmp"
        continue
      fi
      [ -n "$want" ] && echo "[OpenClash] $kind sha256 校验通过: $got"
    fi

    tar -zxf "$tmp/$tarball" -C "$tmp"
    if [ ! -f "$tmp/clash" ]; then
      echo "::warning::[OpenClash] $kind 压缩包结构变化（没找到 clash），跳过"
      rm -rf "$tmp"
      continue
    fi

    install -m 0755 "$tmp/clash" "$core_dir/$dest"
    rm -rf "$tmp"
    echo "[OpenClash] 已预置: $core_dir/$dest ($(du -h "$core_dir/$dest" | cut -f1))"
  done

  echo "[OpenClash] 内核目录:"
  ls -lh "$core_dir" 2>/dev/null || true
}


# ---- aurora 主题 ----
clone_pkg https://github.com/eamonxg/luci-theme-aurora.git master luci-theme-aurora
clone_pkg https://github.com/eamonxg/luci-app-aurora-config.git master luci-app-aurora-config

# ---- OpenClash（运行时开关控制，关闭时不拉包也不拉内核）----
if [ "${OpenWrt_OPENCLASH:-false}" = "true" ]; then
  clone_pkg https://github.com/vernesong/OpenClash.git master luci-app-openclash
  # 立即预置内核（此时无 .config，架构从平台配置读）
  fetch_openclash_core
else
  # 关闭时也删同名包，避免 feeds install 装回旧版
  remove_pkg luci-app-openclash
  remove_pkg openclash
  echo "[OpenClash] 本次运行未启用，跳过克隆与内核预置"
fi

# ---- Nikki（运行时开关控制；三个子包缺一不可）----
if [ "${OpenWrt_NIKKI:-false}" = "true" ]; then
  rm -rf /tmp/nikki-src
  if git clone --depth=1 --single-branch --branch main \
       https://github.com/nikkinikki-org/OpenWrt-nikki.git /tmp/nikki-src; then
    for pkg in luci-app-nikki nikki mihomo-meta; do
      if [ -d "/tmp/nikki-src/$pkg" ]; then
        remove_pkg "$pkg"
        mv "/tmp/nikki-src/$pkg" "./$pkg"
        echo "已放入 Nikki 子包: $pkg"
      else
        echo "::warning::[Nikki] 上游缺少子包 $pkg"
      fi
    done
    rm -rf /tmp/nikki-src
  else
    echo "::warning::[Nikki] 克隆失败，luci-app-nikki 配置项将被忽略"
  fi
else
  echo "[Nikki] 本次运行未启用，跳过克隆"
fi

# ---- rtp2httpd：用官方 versioned Makefile（上游发版自动升级）----
remove_pkg rtp2httpd
remove_pkg luci-app-rtp2httpd
rm -rf /tmp/rtp2httpd-src
if git clone --depth=1 --single-branch --branch main \
     https://github.com/stackia/rtp2httpd.git /tmp/rtp2httpd-src; then
  mv /tmp/rtp2httpd-src/openwrt-support/rtp2httpd ./rtp2httpd
  mv /tmp/rtp2httpd-src/openwrt-support/luci-app-rtp2httpd ./luci-app-rtp2httpd
  rm -rf /tmp/rtp2httpd-src

  if [ -f ./rtp2httpd/Makefile.versioned ] && [ -f ./luci-app-rtp2httpd/Makefile.versioned ]; then
    mv -f ./rtp2httpd/Makefile.versioned ./rtp2httpd/Makefile
    mv -f ./luci-app-rtp2httpd/Makefile.versioned ./luci-app-rtp2httpd/Makefile
    echo "已拉取 rtp2httpd v$(sed -n 's/^RELEASE_VERSION:=//p' ./rtp2httpd/Makefile | head -n1)"
  else
    # 缺 versioned 就跳过，避免 in-tree Makefile 拷整棵源码树
    echo "::warning::上游缺少 Makefile.versioned，跳过 rtp2httpd（避免 in-tree Makefile 破坏构建）"
    rm -rf ./rtp2httpd ./luci-app-rtp2httpd
  fi
else
  echo "::warning::rtp2httpd 克隆失败，构建继续（该插件将缺失）"
fi

# ---- gecoosac ----
clone_pkg https://github.com/laipeng668/luci-app-gecoosac.git main luci-app-gecoosac

# ---- lucky（拉整仓自动取包，所有平台都拉）----
clone_repo https://github.com/gdy666/luci-app-lucky.git main

# ---- AN758X 专用插件 ----
if is_airoha; then
  clone_pkg https://github.com/naoki66/luci-app-airoha.git main luci-app-airoha
  clone_pkg https://github.com/qwe-qaq/luci-app.git main luci-app-pon-status
fi

# 重建 feeds 索引，避免 feeds install -a 按旧索引找包
if [ -x ../scripts/feeds ]; then
  (cd .. && ./scripts/feeds update -i) >/dev/null 2>&1 || true
fi

echo "Plugins.sh 执行完成"
