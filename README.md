# OpenWRT-CI2

基于 GitHub Actions 的 OpenWrt / ImmortalWrt 云编译方案：**一个通用核心 + 每个平台一个精简工作流 + 每个平台一个配置文件**，带工具链双级缓存，第二次起编译显著变快。

参考代码：[VIKINGYFY/OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI)

[yhlh9982/Actions-OpenWrt-MT798X](https://github.com/yhlh9982/Actions-OpenWrt-MT798X)

当前维护设备：`ponwrt-pbs05` —— [pbs05/ponwrt](https://github.com/pbs05/ponwrt)（Airoha AN7581 PON 光猫，分支 `master`），默认管理地址 `192.168.1.1`，主机名 `ImmortalWrt`，无密码。

## 特性

- **一次定义，多平台复用**：全部编译逻辑收敛在 `OpenWrt-CORE.yml`（可复用工作流），新增平台只需加两个小文件，不碰核心。
- **一个平台一个配置文件**：机型取舍、插件开关、源码配置引用全部写在 `Config/<TARGET>.txt`，平台之间互不影响。
- **工具链双级缓存**：优先 `actions/cache`，未命中再读 `toolchain-cache` Release 备份；命中后省掉约 30~40 分钟的 tools/toolchain 编译。
- **自动发布**：产物同时上传 Artifact与 Release，附带 sha256sums 和配置快照。
- **安全清理**：只清本平台的旧 Run / 旧 Release，绝不误删共享的 `toolchain-cache`。

## 快速开始

**触发一次编译**：仓库页面 → `Actions` → 左侧选 `ponwrt-pbs05` → 右侧 `Run workflow` → `Run branch: main` → 确认。全程约 1~2.5 小时（工具链缓存命中时明显更快）。

**下载固件**：优先看本平台的 Release（tag 形如 `ponwrt-pbs05_ponwrt_25.11.06_15.05.52`）；Release 没有就去对应 Run 的 Artifacts。刷机前确认机型与分区。

## 架构

```
.github/workflows/
  OpenWrt-CORE.yml            通用编译核心（workflow_call，被平台工作流调用）
  ponwrt-pbs05.yml            平台工作流：只管传参
  Delete-tag-and-release.yml  手动清理：旧 Release / 旧运行记录 / 旧工具链备份
Config/
  ponwrt-pbs05.txt            该平台的全部配置（源码配置引用 + 额外配置）
Scripts/
  Settings.sh                 feeds install 前：删旧包 / 默认主题 / IP / 主机名 / 时区
  Plugins.sh                  feeds install 前：克隆 feeds 里没有的插件
  Renames.sh                  批量重命名产物（默认未启用）
```

一次构建的完整流程：

1. `actions/checkout` 拉本仓库（Config / Scripts）
2. 释放磁盘空间、建 16G Swap、安装编译依赖
3. 克隆源码 → `feeds update` → `Settings.sh` → `Plugins.sh` → `feeds install`
4. 生成 `.config`（见下节）→ `make defconfig` → 校验目标平台
5. 计算工具链缓存 Key → 恢复缓存（actions/cache）→ 未命中则读 Release 备份
6. `make download` → 缓存仍未命中才编译 tools + toolchain → 回写两级缓存
7. `make -j$(nproc)` 编译 → 产物打包到 `openwrt/upload`
8. 上传 Artifact + 发布 Release
9. 清理旧运行记录、旧固件 Release（**不动 `toolchain-cache`**）

## 配置文件：一个平台一个文件

`Config/<TARGET>.txt` 由三部分组成：

```
#AN7581                              ← ① 首行 # 之后 = 发布说明里的「平台」字段
#!DEFCONFIG=configs/an7581.config    ← ② 先加载源码自带的完整配置
CONFIG_PACKAGE_luci-app-lucky=y      ← ③ 其余都是本平台的额外配置，
CONFIG_PACKAGE_rtp2httpd=y              追加到 .config 末尾，后写覆盖先写
```

最终 `.config` 的拼装顺序：

```
源码 configs/an7581.config
  → Config/ponwrt-pbs05.txt 的额外配置
  → make defconfig
```

平台差异全部写进各自的 `Config/<TARGET>.txt`。

不写 `#!DEFCONFIG=` 时，`.config` 直接使用本文件内容——适合源码没有自带完整配置的情况（需要自己写全 `CONFIG_TARGET_*`）。

### 只编译部分机型

源码的 `configs/an7581.config` 默认把该子平台**所有机型**设为 `=y`。因为本配置文件是追加在它后面的，用 Kconfig 的"不选"语法逐个关掉即可（后写覆盖先写）：

```
# 保留：fiberhome_hg5585f-ct / nokia_xg-040g-md-ubi / unionman_ung00a / znxt_zn504xg-d
CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_fiberhome_hg5382a=n
CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_gemtek_xg2010g=n
```

## 新增一个平台

1. **配置**：新建 `Config/<TARGET>.txt`，按需引用源码 defconfig、开关插件、裁剪机型；
2. **工作流**：复制 `ponwrt-pbs05.yml`，改 `name` 和 `with:` 里的参数（TARGET / 源码 URL / 分支 / 主题 / IP 等）；
3. **依赖脚本**：如有 feeds 里没有的插件，在 `Scripts/Plugins.sh` 里追加克隆。

推送后在 Actions 里手动跑一次即可；同一平台的工作流自带 concurrency 保护，同时只会跑一个构建。

## 常见问题

**DEFCONFIG 行被写进了 .config？**
必须带 `#!` 前缀（`#!DEFCONFIG=...`）；只写 `DEFCONFIG=` 会被当作配置内容追加，导致目标平台识别错乱——核心已内置防呆报错。

## 本地自检

提交前跑这两条，确认 workflow 语法与脚本可执行：

```bash
python -c "import yaml,sys;[yaml.safe_load(open(f,encoding='utf-8')) for f in sys.argv[1:]]" .github/workflows/*.yml
bash -n Scripts/*.sh
```
