# OpenWRT-CI2

基于 GitHub Actions 的 OpenWrt / ImmortalWrt / Uboot 云编译方案：通用核心 + 每平台一个工作流 + 每平台一个配置文件，带工具链双级缓存、Rust 交叉编译自动就绪和构建报告。

参考：[VIKINGYFY/OpenWRT-CI](https://github.com/VIKINGYFY/OpenWRT-CI)、[yhlh9982/Actions-OpenWrt-MT798X](https://github.com/yhlh9982/Actions-OpenWrt-MT798X)

## 平台

| 工作流 | 源码 | 设备 | 分支 |
| --- | --- | --- | --- |
| `op-an758x-pbs05` | [pbs05/ponwrt](https://github.com/pbs05/ponwrt) | Airoha AN7581 PON 光猫 | `master` |
| `op-rtl9617c-crysister` | [crysister/rtl9617c-immortalwrt](https://github.com/crysister/rtl9617c-immortalwrt) | Realtek RTL9617C（PT1500-H10 / TYFZA1） | `master` |
| `uboot-an758x-pbs05` | [pbs05/uboot-an758x](https://github.com/pbs05/uboot-an758x) | Airoha AN758X U-Boot | `main` |
| `uboot-rtl9617c-lyq1996` | [lyq1996/rtl9617c-uboot](https://github.com/lyq1996/rtl9617c-uboot) | Realtek RTL9617C U-Boot | `main` |

默认管理地址 `192.168.1.1`，主机名 `ImmortalWrt`，无密码。

## 优化点

- **Rust 交叉编译开箱即用**：`prepare-rust.sh` 从源码 `rust-values.mk` 推导 target 并安装到 runner，同时把 runner 现成 Rust 接入 staging_dir。
- **构建报告**：编译时写入 `BUILD_TIME_LOG`；失败也收集 `.config`、耗时 TSV、ccache / Rust / Go / Python 工具链信息，作为 Artifact 保留 7 天。
- **缓存轮转**：成功构建后只保留当前平台最新一份工具链缓存，避免 actions/cache 10G 配额被旧 key 占满。

## 使用

- **编译**：Actions → 选平台工作流 → `Run workflow` → 选 `main` 分支 → 确认。
- **下载**：优先该平台的 Release，没有就看对应 Run 的 Artifacts。刷机前确认机型与分区。

## 目录

```
.github/workflows/
  OpenWrt-CORE.yml     通用编译核心（workflow_call）
  op-an758x-pbs05.yml / op-rtl9617c-crysister.yml   平台入口，只传参
  Delete-tag-and-release.yml  手动清理旧 Release / 旧 Run
  Uboot-CORE.yml       通用 U-Boot 编译核心（一次编译全部机型）
  uboot-an758x-pbs05.yml / uboot-rtl9617c-lyq1996.yml  两个 U-Boot 平台入口
  Update-Uboot-Boards.yml  定时同步上游 U-Boot 机型名单
.github/scripts/
  prepare-rust.sh      按源码 rust-values.mk 推导 target、安装 runner target、接入 prebuilt Rust
  rust-prebuilt.mk     让 OpenWrt 直接软链 runner 的 cargo/rustc，跳过自举
  collect-build-reports.sh  收集耗时、缓存和工具链报告（失败时也执行）
Config/<TARGET>.txt    该平台全部配置（插件开关、机型取舍、defconfig 引用）
Config/uboot-an758x-boards.txt / uboot-rtl9617c-boards.txt  U-Boot 机型名单（自动生成）
Patches/<平台>/*.patch|*.diff  克隆源码后、feeds 前打补丁（兼容 git diff / git format-patch）
ReplacementFiles/<平台>/<源码相对路径>  供 Settings.sh 覆盖源码（如 op-an758x-pbs05/package/emortal/autocore；.gitkeep 忽略）
Scripts/Settings.sh    feeds install 前：默认主题、IP、主机名、时区，并按平台覆盖文件
Scripts/Plugins.sh     feeds install 前：克隆 feeds 里没有的插件
Scripts/Renames.sh     产物重命名（默认未启用）
```

## 新增平台

1. 新建 `Config/<TARGET>.txt`：写完整 `CONFIG_TARGET_*`，或用 `#!DEFCONFIG=configs/xxx.config` 引用源码自带配置；其余行追加插件 `=y`，后写覆盖先写。首行 `#平台名` 用于 Release 说明。
2. 复制一个平台 yml，改 `name` 和 `with:` 参数；核心 `OpenWrt-CORE.yml` 不用动。
3. 需要打补丁时，把 `*.patch` / `*.diff`（支持 `git diff` 或 `git format-patch` 输出）放到 `Patches/<TARGET>/`，核心会在克隆源码后、feeds 更新前按文件名顺序应用：优先 `git apply`（支持二进制补丁），失败时回退 `patch -p1`；平台目录不存在或目录内没有补丁文件时均跳过。
4. 需要覆盖源码文件时，在 `ReplacementFiles/<TARGET>/` 下按源码内相对路径放同名文件，例如 `ReplacementFiles/op-an758x-pbs05/package/emortal/autocore/files/tempinfo` 对应源码的 `package/emortal/autocore/files/tempinfo`；`Settings.sh` 会在 feeds install 前复制过去。`.gitkeep` 只用于让空目录入库，不会覆盖到源码；平台目录不存在或目录内无覆盖文件时均跳过。
5. 有 feeds 里没有的插件，在 `Scripts/Plugins.sh` 加一条克隆；是否编译由 config 里的 `=y` 决定。

U-Boot 同理：复制一个 `uboot-*.yml`，改源码/分支/构建脚本/机型名单 txt 路径，核心 `Uboot-CORE.yml` 不用动。机型名单由 `Update-Uboot-Boards.yml` 每周同步上游，也可手动触发。AN758X 签名需在仓库 Secrets 配 `AIROHA_SIGN_KEY`（不配则跳过签名）。

## 自检

```bash
python -c "import yaml,sys;[yaml.safe_load(open(f,encoding='utf-8')) for f in sys.argv[1:]]" .github/workflows/*.yml
bash -n Scripts/*.sh .github/scripts/*.sh
```
