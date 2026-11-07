#!/bin/bash
# shellcheck disable=SC2154  # OpenWrt_* 变量由 GitHub Actions 注入
# 克隆默认源中没有 / 需要替换的插件
# 执行位置：openwrt/package 目录，在 `feeds install -a` 之前

# 通用克隆函数：clone_pkg <url> <branch> <目标目录名>
clone_pkg() {
  url="$1"
  branch="$2"
  dir="$3"

  if [ -d "./$dir" ]; then
    echo "已存在，跳过: $dir"
    return 0
  fi

  if [ -n "$branch" ]; then
    git clone --depth=1 --single-branch --branch "$branch" "$url" "$dir" \
      || echo "::warning::克隆失败（构建继续，相关配置项会被忽略）: $url ($branch)"
  else
    git clone --depth=1 --single-branch "$url" "$dir" \
      || echo "::warning::克隆失败（构建继续，相关配置项会被忽略）: $url"
  fi
}

# ---------------------------------------------------------------------------
# 探测目标平台：优先用已生成的 .config；还没有就读 CI 配置里 #!DEFCONFIG= 指向的源码配置
# 执行位置是 openwrt/package，所以源码根目录是 ..
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# OpenClash 内核预置：下载 clash 内核 → 校验 → 放进包目录，随固件一起安装
#
# 上游结构（2026-11 核实）：
#   core 分支：master/{meta,smart}/clash-linux-<arch>.tar.gz、dev/{meta,smart}/...
#   - tar 里是名为 clash 的可执行文件；OpenClash 期望它叫 clash_meta
#   - 包内已自带 Country.mmdb / GeoSite.dat，无需再下载；GeoIP.dat 新版已不需要
# ---------------------------------------------------------------------------
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

# ---- luci-app-openclash----
clone_pkg https://github.com/vernesong/OpenClash.git master luci-app-openclash
# 拉完包立刻预置内核（此时还没有 .config，架构从源码 configs/*.config 里读）
fetch_openclash_core

# ---- 视频转播：删掉源码自带的，换成官方 rtp2httpd ----
# 官方仓库根目录没有 OpenWrt Makefile，包在 openwrt-support/ 下；里面有两份：
#   Makefile           给“源码树内”用（Build/Prepare 会 cp $(CURDIR)/../../*）
#   Makefile.versioned 给固件仓库用（锁定 RELEASE_VERSION + PKG_HASH）
# 用 versioned 版本：上游每次发版都会更新它，重新编译即自动升级，无需改本仓库
if [ ! -d ./rtp2httpd ]; then
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
      # 上游若改了目录结构，宁可跳过该插件也不要用 in-tree 的 Makefile（会拷整棵源码树）
      echo "::warning::上游缺少 Makefile.versioned，跳过 rtp2httpd（避免 in-tree Makefile 破坏构建）"
      rm -rf ./rtp2httpd ./luci-app-rtp2httpd
    fi
  else
    echo "::warning::rtp2httpd 克隆失败，构建继续（该插件将缺失）"
  fi
fi

# ---- gecoosac ----
clone_pkg https://github.com/laipeng668/luci-app-gecoosac.git main luci-app-gecoosac

# ---- luci-app-airoha ----
clone_pkg https://github.com/naoki66/luci-app-airoha.git main luci-app-airoha

# ---- luci-app-pon-status ----
clone_pkg https://github.com/qwe-qaq/luci-app.git main luci-app-pon-status

# ---- luci-theme-aurora----
clone_pkg https://github.com/eamonxg/luci-theme-aurora.git master luci-theme-aurora

echo "Plugins.sh 执行完成"
