# AGENTS.md

本文件为 AI 代理（及人类贡献者）提供项目上下文，说明项目目标、设计哲学、架构和关键约束。

## 项目目标

为 Android Emulator / AVD 的 `x86_64` 虚拟设备内核编译集成了 **SukiSU-Ultra**（KernelSU 分支）的内核，使 AVD 获得 kernel-level root 权限。使用 SukiSU-Ultra 官方 GitHub Release 的 **prebuilt manager APK**（ShirkNeko 签名），而非从源码自行构建 manager。

当前已验证的目标：`common-android15-6.6`（内核 6.6.x）x86_64，SukiSU-Ultra commit `0ca744a8`，prebuilt APK versionCode `40796`。

## 设计哲学

### 1. 上游源码零侵入

所有对 AOSP 内核源码（`common/`、`common-modules/`、`build/`）的修改通过 `patches/` 重放，不把手工编辑留在仓库里。SukiSU-Ultra 的集成（`drivers/Kconfig`/`Makefile` 入口 + symlink）是**临时工作区改动**，`setup.sh --cleanup` 可完全还原上游 clean 状态。

### 2. 可复现的 CI 对齐

`prepare.sh` 解析 AVD 的 `/proc/version`，从 Android CI `BUILD_INFO` 获取精确的 repo manifest commit，对所有本地仓库执行 `git checkout` 到 CI 构建时的确切 commit。`build.sh` 在构建前会验证 checkout 一致性，不一致则直接失败。

### 3. 最小改动原则

仅修改实现目标所必需的最少上游文件。KernelSU 自身的改动全部隔离在 `patches/kernelsu/` 中，作用于 submodule 而非上游内核。

**例外（6.6 x86_64）**：`patches/common-android15-6.6/0001-x86-syscall-hardening-bypass-for-kernelsu.patch` 触及 8 个上游文件（约 281 行），违反字面"最小改动"，但是 KernelSU syscall hook 在 6.6 x86_64 上的**必需条件**。该 patch 引入 `X86_FEATURE_INDIRECT_SAFE` 和 `syscall_hardening=off` cmdline 支持；缺少它会导致编译失败或 KSU 在 init 阶段 abort。已隔离为分支专属 patch，并在 `package.sh` 部署文件中记录启动要求。

6.1 分支另有 `tools/lib/subcmd/Makefile` glibc C23 兼容 patch（仅 Android 14 / 6.1 需要）。

### 4. 版本确定性

SukiSU-Ultra 的 Kbuild 原始版本公式依赖 `curl` 调用 GitHub API（网络请求），这在 Bazel hermetic 构建中不可用且不可复现。`patches/kernelsu/0001-kbuild-deterministic-version.patch` 移除网络依赖，改用确定性本地 git 公式。

驱动与 manager 版本通过 **git checkout 对齐**（非 override pin）：`setup.sh` 根据目标 versionCode 反算 commit count，checkout 到产生该 versionCode 的精确 commit，使 `KSU_VERSION` 与 prebuilt APK 自然一致。

## 架构

### 工作流

```text
prepare.sh → setup.sh → build.sh → package.sh
```

| 阶段 | 脚本 | 作用 |
|---|---|---|
| 准备 | `prepare.sh` | 解析 `/proc/version` → 确定 repo branch / build id / commit → `repo init/sync` → checkout 到 CI 精确 commit → 生成 `out/target.json` + `out/target.env` |
| 集成 | `setup.sh` | checkout KernelSU 到目标 versionCode → 应用 patch series → 写入临时 driver 入口 → 创建 symlink `drivers/kernelsu` → 生成 `out/ksu.env` |
| 构建 | `build.sh` | 验证 checkout 一致性 → Bazel/Kleaf（modern）或 `build/build.sh`（legacy）→ 产物到 `dist/` |
| 打包 | `package.sh` | 从 `dist/` 收集 `bzImage` + `.ko` → 生成 `avd-sukisu-deploy.tar.gz` |

### 目录结构

```text
android-kernel/
├── AGENTS.md                  # 本文件
├── README.md                  # 用户文档
├── prepare.sh                 # 版本解析 + repo sync + CI commit checkout
├── setup.sh                   # patch 应用 + SukiSU-Ultra 集成 + 版本对齐
├── build.sh                   # Bazel/Kleaf 或 legacy 构建
├── package.sh                 # 部署包打包（不编译）
├── .gitmodules                # KernelSU submodule 定义
├── scripts/
│   └── avd_kernel_meta.py     # 版本解析 / CI BUILD_INFO 元数据 / checkout 验证
├── patches/                   # patch series（按目标分类）
│   ├── common/                # 跨版本通用 patch
│   ├── common-android14-6.1/  # 仅 6.1 分支
│   ├── common-android15-6.6/  # 仅 6.6 分支
│   └── kernelsu/              # SukiSU-Ultra submodule patch
├── KernelSU/                  # SukiSU-Ultra git submodule
├── common/                    # repo sync: kernel/common（gitignore）
├── common-modules/            # repo sync: virtual-device modules（gitignore）
├── build/                     # repo sync: kernel/build（gitignore）
├── tools/                     # repo sync: build tools（gitignore）
├── prebuilts/                 # repo sync: prebuilt toolchains（gitignore）
├── external/                  # repo sync: external deps（gitignore）
├── out/                       # 构建中间产物 + target.json/target.env/ksu.env（gitignore）
├── dist/                      # 构建产物 bzImage/.ko（gitignore）
└── SukiSU_*.apk               # prebuilt manager APK（gitignore）
```

### Patch 策略

- `patches/common/`：跨所有内核版本通用的 patch。
- `patches/<repo-branch>/`：仅适用于特定分支（如 `common-android15-6.6`）。
- `patches/kernelsu/`：应用于 `KernelSU/` submodule，不触碰上游内核。

`setup.sh` 按 `out/target.env` 中的 `AVD_REPO_BRANCH` 选择对应分支的 patch 目录。`requires_common_patch()` 对 `common-android12`、`common-android14-6.1`、`common-android15-6.6` 要求分支 patch 存在，缺失时直接报错而非静默跳过。`--cleanup` 会反向所有已知分支的 patch，确保切换 AVD 版本后不留残留。

### 当前 patch

```text
patches/common-android14-6.1/0001-tools-lib-subcmd-avoid-glibc-c23-strtol-redirect.patch
patches/common-android15-6.6/0001-x86-syscall-hardening-bypass-for-kernelsu.patch
patches/kernelsu/0001-kbuild-deterministic-version.patch
patches/kernelsu/0002-fix-x86-patch-memory-includes.patch
```

**`0001-tools-lib-subcmd`**：规避 glibc 2.38+ 的 C23 strtol redirect 与旧 Android host sysroot 的链接冲突，仅 6.1 需要。

**`0001-x86-syscall-hardening-bypass`**：为 6.6 x86_64 KernelSU syscall hook 引入 `X86_FEATURE_INDIRECT_SAFE` 和 `syscall_hardening=off` cmdline 支持。AVD 启动时必须传递 `syscall_hardening=off`（见 `package.sh` 生成的 `kernel.parameters` 和 `AVD_DEPLOY.txt`）。

**`0001-kbuild-deterministic-version`**：移除 `curl` GitHub API 网络依赖，改用本地 git 公式 `40000 + rev-list --count HEAD - 2815`。

**`0002-fix-x86-patch-memory-includes`**：在 x86 `text-patching.h` 之前添加 `#include <linux/bug.h>`，修复 `BUG_ON` 未声明的编译错误。

### 版本匹配机制

| 组件 | 公式 | 当前值 |
|---|---|---|
| manager APK versionCode | `40000 + commit_count - 2815` | `40796` |
| 驱动 KSU_VERSION | 同上（同一 commit） | `40796` |
| 对齐方式 | `setup.sh` git checkout | commit `0ca744a8`（count=3611） |

`setup.sh --manager-version CODE`（或 `KSU_MANAGER_VERSION`）将 versionCode 反算为 commit count，checkout KernelSU submodule 到产生该 versionCode 的 commit。`out/ksu.env` 记录 `KSU_MANAGER_VERSION`、`KSU_COMMIT`、`KSU_COMPUTED_VERSION`。可选：放置 `SukiSU_*.apk` 并通过 `aapt` 校验 versionCode。

`resolve_manager_commit()` 优先用 `--first-parent --skip` 定位 commit；仅在 skip 结果的 count 与目标不符时触发 O(n²) 线性扫描回退，实际场景几乎不会触发。

### Manager 识别

- **主 manager**：`apk_sign_keys[]` 中硬编码的 ShirkNeko/SukiSU 证书（index 0）。官方 SukiSU-Ultra Release APK 使用该签名，无需额外证书注册。
- **多 manager**：`dynamic_manager` 机制（`dynamic_manager.c`）在运行时经 `KSU_IOCTL_DYNAMIC_MANAGER` ioctl 启用，可注册额外 manager 签名。不依赖 Kconfig 开关，总是编译进内核。

### 构建系统

- **Modern（Android 13+ / 5.10+）**：Bazel/Kleaf，目标 `//common-modules/virtual-device:virtual_device_x86_64_dist`。
- **Legacy（Android 11 / 5.4）**：`build/build.sh` + `BUILD_CONFIG`。
- `build.sh` 自动检测：存在 `common-modules/virtual-device/BUILD.bazel` 则用 Bazel。
- Bazel 构建注入 host-tools 兼容参数（`HOSTCFLAGS=--sysroot= -std=gnu11` 等），规避 glibc C23 链接错误。
- 构建后 `verify_ksu_enabled()` 检查 `.config` 中 `CONFIG_KSU=y`，防止 KSU 静默未编译。

### CONFIG_KSU

`CONFIG_KSU` 在 `KernelSU/kernel/Kconfig` 中 `default y`，因此无需额外 defconfig fragment。只要 `setup.sh` 正确写入 `drivers/Kconfig` source 入口，`make defconfig` 后 `CONFIG_KSU` 会自动启用。`build.sh` 在构建后验证这一点。

### AVD 启动要求（6.6 x86_64）

KernelSU syscall hook 需要 `syscall_hardening=off`：

- **config.ini**（`~/.android/avd/<AVD>.avd/config.ini`）：`kernel.parameters = syscall_hardening=off`
- **Emulator 36+ CLI**（通过 QEMU，非顶层 `-append`）：`emulator ... -kernel path/to/bzImage -qemu -append syscall_hardening=off`

验证：`cat /sys/devices/system/cpu/syscall_hardening` 应显示 `Disabled`。

## 关键约束

1. **不要直接编辑 `common/`、`common-modules/`、`build/` 中的文件**——这些是 repo 管理的上游源码。所有改动通过 `patches/` + `setup.sh` 重放。
2. **不要在 `KernelSU/` 中直接修改并提交**——它是 git submodule，改动通过 `patches/kernelsu/` 应用。`setup.sh --cleanup` 会还原。
3. **更换 prebuilt APK 时**：下载新 Release APK，用 `bash setup.sh --manager-version <versionCode>` 对齐 submodule。
4. **切换 AVD 内核版本时**：先 `setup.sh --cleanup`（清理旧分支 patch），再 `prepare.sh`（新版本），再 `setup.sh`。
5. **ARM64 主机构建 x86_64**：需要 binfmt/QEMU（`podman run --privileged --rm docker.io/tonistiigi/binfmt --install amd64`），legacy 构建可能需要 `QEMU_LD_PREFIX`。

## 验证命令

```bash
# 检查 patch 可应用性
bash setup.sh --check

# Dry-run 构建
bash build.sh --dry-run

# 验证版本匹配
cat out/ksu.env
aapt dump badging SukiSU_*.apk | grep versionCode

# 验证 submodule 版本
git -C KernelSU rev-parse HEAD
git -C KernelSU rev-list --count HEAD
```

## Git 仓库结构

本仓库只追踪：构建脚本（`*.sh`）、元数据工具（`scripts/`）、patch series（`patches/`）、文档（`README.md`/`AGENTS.md`）、KernelSU submodule 引用（`.gitmodules`）。

不追踪：repo 管理的上游源码（`common/`、`build/` 等）、构建产物（`out/`、`dist/`）、Bazel 符号链接（`bazel-*`、`WORKSPACE`、`MODULE.bazel`、`WORKSPACE.bzlmod`）、prebuilt APK、KernelSU backup 目录。详见 `.gitignore`。