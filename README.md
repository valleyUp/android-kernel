# SukiSU-Ultra AVD Kernel Builder

用于为 Android Emulator / AVD 的 `x86_64` virtual-device 内核准备、集成、构建和打包 SukiSU-Ultra。设计目标是：切换 AVD 内核版本时只改输入的 `/proc/version`，上游源码修改全部通过 `patches/` 重放，不把临时改动混进 AOSP 仓库。

## 目录结构

```text
android-kernel/
├── prepare.sh                 # 解析 /proc/version，repo init/sync，按 CI commit 对齐
├── setup.sh                   # checkout KernelSU 版本、应用 patch、创建 symlink 和 driver 入口
├── build.sh                   # 调用 Bazel/Kleaf 或 legacy build.sh，支持 --dry-run
├── package.sh                 # 从 dist/ 打包部署包，不编译
├── scripts/
│   └── avd_kernel_meta.py     # 版本解析和 CI BUILD_INFO 元数据工具
├── patches/                   # 按分支和 submodule 分类的 patch series
├── KernelSU/                  # SukiSU-Ultra submodule
├── common/                    # repo sync 得到的 kernel/common
├── common-modules/            # repo sync 得到的 virtual-device modules
├── out/                       # 生成的 target.json/target.env/ksu.env 和中间产物
└── dist/                      # 构建产物
```

## 典型流程

### 1. 准备目标版本

推荐把 AVD 的完整 `/proc/version` 保存到文件后传给 `prepare.sh`，避免长字符串里的括号、`#`、空格或复制引号被 shell 误处理：

```bash
cat > proc-version.txt <<'EOF'
Linux version 6.6.66-android15-8-gb66429556fb8-ab13070261 (kleaf@build-host) (Android (11368308, +pgo, +bolt, +lto, +mlgo, based on r510928) clang version 18.0.0 (https://android.googlesource.com/toolchain/llvm-project 477610d4d0d988e69dbc3fae4fe86bff3f07f2b5), LLD 18.0.0) #1 SMP PREEMPT Fri Feb 14 22:29:59 UTC 2025
EOF

bash prepare.sh --proc-version-file proc-version.txt -j16
```

该示例会解析为：

```text
repo branch : common-android15-6.6
build id    : 13070261
commit      : b66429556fb8
```

`prepare.sh` 会生成：

```text
out/target.json   # 完整元数据和 CI 状态
out/target.env    # build/setup 脚本可 source 的环境变量
```

脚本会读取 Android CI `BUILD_INFO` 的 `repo-dict`，并按当前 repo manifest checkout 所有本地已同步仓库的精确 commit。不同 Android 版本的 prebuilts 列表会变化，例如 Android 14 可能包含 `platform/prebuilts/bazel/linux-x86_64`，Android 15 则可能改由其他 Bazel/Rust/NDK prebuilts 组合提供；脚本会按当前 BUILD_INFO 和 manifest 动态对齐，不再依赖固定仓库列表。Android CI 的 `view/BUILD_INFO` 页面有时返回 Artifact Viewer HTML，脚本会自动解析其中的签名 artifact URL 再下载真实 JSON。

对 Android 13/14/15 的 Bazel/Kleaf 分支，不能只对齐 `kernel/common`。如果 `common-modules/virtual-device`、`kernel/build` 或 Bazel/JDK prebuilts 留在 branch tip，会出现类似 `//common:modules.bzl does not contain symbol get_gki_modules_list` 或 `@local_jdk//:runtime_toolchain_definition` 的版本错配。`prepare.sh` 和 `build.sh` 会在这种不完整状态下直接失败，要求重新执行准备步骤。

### 2. 集成 SukiSU-Ultra

```bash
bash setup.sh
```

默认将 KernelSU submodule checkout 到 versionCode `40796`（与官方 Release APK 对齐）。指定其他版本：

```bash
bash setup.sh --manager-version 40796
```

`setup.sh` 会做五类事情：

- 根据 versionCode 反算 commit count，checkout KernelSU 到精确 commit；
- 如果 `patches/` 中存在 patch，则通过 `git apply` 应用；
- 临时向 `common/drivers/Kconfig` 和 `common/drivers/Makefile` 写入 KernelSU 入口；
- 创建未跟踪 symlink：`common/drivers/kernelsu -> ../../KernelSU/kernel`；
- 生成 `out/ksu.env` 记录版本对齐状态。

清理集成：

```bash
bash setup.sh --cleanup
```

检查 patch 状态：

```bash
bash setup.sh --check
```

### 3. 构建

先 dry-run，确认会调用什么：

```bash
bash build.sh --dry-run
```

Android 13/14/15 的 modern kernel 会使用 Bazel/Kleaf：

```bash
bash build.sh -j4
```

`build.sh` 会给 Kleaf action 注入 host-tools 兼容参数：

```text
HOSTCFLAGS=--sysroot= -std=gnu11
HOSTLDFLAGS=--sysroot=
EXTRA_CFLAGS=-std=gnu11
```

这是为了避免新发行版 glibc 头文件和旧 Android host sysroot 混用时出现 `__isoc23_strtol` / `__isoc23_strtoul` 链接错误。需要覆盖时可设置 `BAZEL_HOSTCFLAGS`、`BAZEL_HOSTLDFLAGS`、`BAZEL_EXTRA_CFLAGS`。

`build.sh` 会先校验 `out/target.json` 中记录的 CI commit 是否与当前源码 checkout 一致。如果你更新了脚本或换了 `/proc/version`，先重新运行：

```bash
bash prepare.sh --proc-version-file proc-version.txt -j16
bash setup.sh --cleanup 2>/dev/null || true
bash setup.sh
bash build.sh -j16
```

如果之前已经失败过 host tools 编译，建议先清理一次旧 Kbuild cache：

```bash
rm -rf out/cache
bash build.sh -j16
```

等价核心目标：

```bash
//common-modules/virtual-device:virtual_device_x86_64_dist
```

Android 11 / 5.4 等 legacy 分支才会退回 `build/build.sh`。

### 4. 打包与部署

```bash
bash package.sh
```

生成：

```text
avd-sukisu-deploy/
avd-sukisu-deploy.tar.gz
```

`package.sh` 不编译，只从现有 `dist/` 收集 `bzImage` 和 `.ko`，并附带 `kernel.parameters`、`AVD_DEPLOY.txt`、`ksu.env`。

**6.6 x86_64 启动要求**：KernelSU syscall hook 需要 `syscall_hardening=off`：

```bash
# 方法 1：config.ini（推荐）
# ~/.android/avd/<AVD>.avd/config.ini
kernel.parameters = syscall_hardening=off

# 方法 2：Emulator 36+ CLI（通过 QEMU，非顶层 -append）
emulator ... -kernel ~/android-kernel/dist/bzImage -qemu -append syscall_hardening=off
```

验证：

```bash
adb shell cat /sys/devices/system/cpu/syscall_hardening
# 期望输出: Disabled
```

## 版本映射

| `/proc/version` 模式 | repo branch |
|---|---|
| `6.6.x-android15-*` | `common-android15-6.6` |
| `6.1.x-android14-*` | `common-android14-6.1` |
| `5.15.x-android14-*` | `common-android14-5.15` |
| `5.15.x-android13-*` | `common-android13-5.15` |
| `5.10.x-android12-*` | `common-android12-5.10` |
| `5.4.x-android11-*` | `common-android11-5.4` |

## Patch 策略

不要把手工编辑留在 `common/`、`common-modules/` 或 `build/` 里作为长期定制。确实需要额外上游改动时：

1. 在临时工作区修改并确认 diff；
2. 跨版本通用 patch 放到 `patches/common/`，只适用于单一内核分支的 patch 放到 `patches/<repo-branch>/`；
3. 让 `setup.sh` 通过 `git apply` 应用；
4. 用 `setup.sh --cleanup` 验证可反向恢复。

当前默认包含这些 patch：

```text
patches/common-android14-6.1/0001-tools-lib-subcmd-avoid-glibc-c23-strtol-redirect.patch
patches/common-android15-6.6/0001-x86-syscall-hardening-bypass-for-kernelsu.patch
patches/kernelsu/0001-kbuild-deterministic-version.patch
patches/kernelsu/0002-fix-x86-patch-memory-includes.patch
```

`tools/lib/subcmd` patch 规避新 glibc 头文件（2.38+）和旧 Android host sysroot 混用时的 `__isoc23_strtol` 链接错误，仅 Android 14 / 6.1 需要。

`syscall-hardening-bypass` patch 为 6.6 x86_64 KernelSU 引入 `X86_FEATURE_INDIRECT_SAFE` 和 `syscall_hardening=off` cmdline 支持。这是较大的上游改动（8 个文件），但是 KSU syscall hook 的必需条件。

`kernelsu/0001` 移除 Kbuild 中的 `curl` GitHub API 网络依赖，改用确定性本地 git 公式。

`kernelsu/0002` 修复 x86 `patch_memory.h` 缺少 `linux/bug.h` 导致的编译错误。

### 版本匹配（driver vs manager）

SukiSU-Ultra manager APK 和内核驱动使用同一公式：

```text
versionCode = 40000 + git rev-list --count HEAD - 2815
```

`setup.sh` 根据目标 versionCode 反算 commit count，checkout KernelSU submodule 到产生该 versionCode 的精确 commit。驱动 `KSU_VERSION` 与 manager APK versionCode 自然一致，无需 override pin。

当前默认状态：

| 项 | 值 |
|---|---|
| prebuilt APK | SukiSU-Ultra GitHub Release（ShirkNeko 签名） |
| APK versionCode | `40796` |
| submodule commit | `0ca744a8`（rev-list count = 3611） |
| 驱动 KSU_VERSION | `40796` |

更换 prebuilt APK 版本时：

```bash
# 下载新 Release APK 到仓库根目录（SukiSU_*.apk）
bash setup.sh --cleanup 2>/dev/null || true
bash setup.sh --manager-version <new_versionCode>
bash build.sh -j16
```

验证版本号：

```bash
cat out/ksu.env
aapt dump badging SukiSU_*.apk | grep versionCode
```

### Manager 识别

官方 SukiSU-Ultra Release APK 使用 ShirkNeko 签名，已在 `apk_sign_keys[]`（index 0）中硬编码，内核驱动可直接识别。

多 manager 能力由运行时 `dynamic_manager` 机制提供（`dynamic_manager.c`），通过 `KSU_IOCTL_DYNAMIC_MANAGER` ioctl 注册额外签名。

新增 patch 后可用 `bash setup.sh --check` 检查可应用性。

## ARM64 VPS 注意事项

ARM64 主机运行 AOSP x86_64 预编译工具链需要 binfmt/QEMU。构建脚本不会自动安装系统依赖；推荐先准备：

```bash
sudo dnf install -y git curl python3 bison flex bc cpio rsync zip unzip tar
sudo podman run --privileged --rm docker.io/tonistiigi/binfmt --install amd64
```

如果使用 legacy `build/build.sh` 且 host tools 需要 x86_64 sysroot，可设置：

```bash
export QEMU_LD_PREFIX=/opt/aosp-x86_64-sysroot
```

## 常用命令

只解析版本，不同步：

```bash
bash prepare.sh --proc-version-file proc-version.txt --no-sync
```

已有 branch/build id 时准备：

```bash
bash prepare.sh \
  --repo-branch common-android15-6.6 \
  --build-id 13070261 \
  --common-commit b66429556fb8
```

只同步，不 checkout CI commit：

```bash
bash prepare.sh --proc-version-file proc-version.txt --no-checkout
```