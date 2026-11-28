#!/bin/bash
# SPDX-License-Identifier: MIT

set -euo pipefail

RUST_FEED="$PWD/feeds/packages/lang/rust"
RUST_MAKEFILE="$RUST_FEED/Makefile"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPORT_DIR="${GITHUB_WORKSPACE:-$PWD}/build-reports"

# 没有 rust feed 的平台直接跳过，不影响 AN758X
if [ ! -f "$RUST_MAKEFILE" ]; then
  echo "::notice::未找到 $RUST_MAKEFILE，跳过 Rust 工具链准备"
  exit 0
fi

mkdir -p "$REPORT_DIR"

# target triple 让源码/feed 自己算，避免写死 aarch64-unknown-linux-musl
RUST_TARGET=$(make --no-print-directory -s -f - TOPDIR="$PWD" ci-rust-target <<'MAKE'
include $(TOPDIR)/rules.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-values.mk
.PHONY: ci-rust-target
ci-rust-target:
	@printf '%s\n' '$(RUSTC_TARGET_ARCH)'
MAKE
)
if [ -z "$RUST_TARGET" ]; then
  echo "::error::无法从 rust-values.mk 推导 Rust target" >&2
  exit 1
fi

RUSTUP_BIN=$(command -v rustup || true)
if [ -z "$RUSTUP_BIN" ]; then
  for candidate in "$HOME/.cargo/bin/rustup" /usr/bin/rustup; do
    if [ -x "$candidate" ]; then RUSTUP_BIN=$candidate; break; fi
  done
fi
if [ -z "$RUSTUP_BIN" ]; then
  # 只有真正需要 Rust 的平台才报错，避免把不需要 Rust 的构建弄挂
  if grep -qE '^CONFIG_PACKAGE_(rtl9617c-pon-control|rust)=y' .config 2>/dev/null; then
    echo "::error::runner 缺少 rustup，RTL9617C 的 pon-control 无法编译" >&2
    exit 1
  fi
  echo "::warning::runner 缺少 rustup，跳过 Rust 工具链准备" >&2
  exit 0
fi

PATH="$(dirname "$RUSTUP_BIN"):$PATH"
export PATH
RUST_TOOLCHAIN=$(rustup show active-toolchain | awk '{print $1}')
printf 'Rust toolchain: %s\nRust target: %s\n' "$RUST_TOOLCHAIN" "$RUST_TARGET" \
  | tee "$REPORT_DIR/rust-toolchain.txt"

rustup target add --toolchain "$RUST_TOOLCHAIN" "$RUST_TARGET"
RUST_ROOT=$(rustup run "$RUST_TOOLCHAIN" rustc --print sysroot)
test -d "$RUST_ROOT/lib/rustlib/$RUST_TARGET/lib"
for tool in cargo rustc rustdoc; do
  test -x "$RUST_ROOT/bin/$tool"
done

# 把 runner 现成的 Rust 接进 staging_dir，避免 OpenWrt 再自编译一套 host rust
if grep -Fq '$(eval $(call HostBuild))' "$RUST_MAKEFILE"; then
  {
    printf 'CI_RUST_ROOT:=%s\n' "$RUST_ROOT"
    cat "$SCRIPT_DIR/rust-prebuilt.mk"
  } > "$RUST_FEED/ci-prebuilt.mk"
  # shellcheck disable=SC2016 # 这里的 $(...) 是 Makefile 语法，不能展开
  sed -i '/^include \.\/ci-prebuilt.mk$/d; /^$(eval $(call HostBuild))$/i include ./ci-prebuilt.mk' "$RUST_MAKEFILE"
  grep -Fxq 'include ./ci-prebuilt.mk' "$RUST_MAKEFILE"
else
  echo "::notice::rust feed 没有 HostBuild，跳过 prebuilt 接入"
fi

"$RUST_ROOT/bin/rustc" --version | tee -a "$REPORT_DIR/rust-toolchain.txt"
echo "Using runner Rust $RUST_TOOLCHAIN for $RUST_TARGET" | tee -a "$REPORT_DIR/rust-toolchain.txt"
sha256sum "$RUST_MAKEFILE" >> "$REPORT_DIR/rust-toolchain.txt"
