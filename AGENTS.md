# AGENTS.md

本文件为 AI 代理（及人类贡献者）提供项目上下文，说明项目目标、设计哲学、架构和关键约束。

## 项目目标

为 Android Emulator / AVD 的 `x86_64` 虚拟设备内核编译集成了 **ReSukiSU**（KernelSU 分支）的内核，使 AVD 获得 kernel-level root 权限。使用 ReSukiSU 官方发布的 **prebuilt manager APK**（带原开发者签名），而非从源码自行构建 manager。

当前已验证的目标：`common-android14-6.1`（内核 6.1.23）x86_64，ReSukiSU v4.1.0（commit `0d27e685c`），prebuilt APK versionCode `34990`。

## 设计哲学

### 1. 上游源码零侵入

所有对 AOSP 内核源码（`common/`、`common-modules/`、`build/`）的修改通过 `patches/` 重放，不把手工编辑留在仓库里。ReSukiSU 的集成（`drivers/Kconfig`/`Makefile` 入口 + symlink）是**临时工作区改动**，`setup.sh --cleanup` 可完全还原上游 clean 状态。

### 2. 可复现的 CI 对齐

`prepare.sh` 解析 AVD 的 `/proc/version`，从 Android CI `BUILD_INFO` 获取精确的 repo manifest commit，对所有本地仓库执行 `git checkout` 到 CI 构建时的确切 commit。`build.sh` 在构建前会验证 checkout 一致性，不一致则直接失败。

### 3. 最小改动原则

仅修改实现目标所必需的最少上游文件。当前对上游内核的唯一实质性改动是 `tools/lib/subcmd/Makefile`（glibc C23 兼容，仅 6.1 需要）。KernelSU 自身的改动全部隔离在 `patches/kernelsu/` 中，作用于 submodule 而非上游内核。

### 4. 版本确定性

ReSukiSU 的 Kbuild 原始版本公式依赖 `curl` 调用 GitHub API（网络请求），这在 Bazel hermetic 构建中不可用且不可复现。本项目移除了网络依赖，改用确定性本地 git 公式。当使用 prebuilt APK 时，通过 `ksu_version.override.mk` pin 版本号以匹配 APK 的 versionCode。

## 架构

### 工作流

```text
prepare.sh → setup.sh → build.sh → package.sh
```

| 阶段 | 脚本 | 作用 |
|---|---|---|
| 准备 | `prepare.sh` | 解析 `/proc/version` → 确定 repo branch / build id / commit → `repo init/sync` → checkout 到 CI 精确 commit → 生成 `out/target.json` + `out/target.env` |
| 集成 | `setup.sh` | 应用 patch series → 写入临时 driver 入口（`drivers/Kconfig`/`Makefile`）→ 创建 symlink `drivers/kernelsu` → 写入版本 override |
| 构建 | `build.sh` | 验证 checkout 一致性 → Bazel/Kleaf（modern）或 `build/build.sh`（legacy）→ 产物到 `dist/` |
| 打包 | `package.sh` | 从 `dist/` 收集 `bzImage` + `.ko` → 生成 `avd-resukisu-deploy.tar.gz` |

### 目录结构

```text
android-kernel/
├── AGENTS.md                  # 本文件
├── README.md                  # 用户文档
├── prepare.sh                 # 版本解析 + repo sync + CI commit checkout
├── setup.sh                   # patch 应用 + ReSukiSU 集成 + 版本 pin
├── build.sh                   # Bazel/Kleaf 或 legacy 构建
├── package.sh                 # 部署包打包（不编译）
├── .gitmodules                # KernelSU submodule 定义
├── scripts/
│   └── avd_kernel_meta.py     # 版本解析 / CI BUILD_INFO 元数据 / checkout 验证
├── patches/                   # patch series（按目标分类）
│   ├── common/                # 跨版本通用 patch
│   ├── common-android14-6.1/  # 仅 6.1 分支
│   ├── common-android15-6.6/  # 仅 6.6 分支
│   └── kernelsu/              # ReSukiSU submodule patch
├── KernelSU/                  # ReSukiSU git submodule
├── common/                    # repo sync: kernel/common（gitignore）
├── common-modules/            # repo sync: virtual-device modules（gitignore）
├── build/                     # repo sync: kernel/build（gitignore）
├── tools/                     # repo sync: build tools（gitignore）
├── prebuilts/                 # repo sync: prebuilt toolchains（gitignore）
├── external/                  # repo sync: external deps（gitignore）
├── out/                       # 构建中间产物 + target.json/target.env（gitignore）
├── dist/                      # 构建产物 bzImage/.ko（gitignore）
└── ReSukiSU_v4.1.0_*.apk      # prebuilt manager APK（gitignore）
```

### Patch 策略

- `patches/common/`：跨所有内核版本通用的 patch。
- `patches/<repo-branch>/`：仅适用于特定分支（如 `common-android14-6.1`）。
- `patches/kernelsu/`：应用于 `KernelSU/` submodule，不触碰上游内核。

`setup.sh` 按 `out/target.env` 中的 `AVD_REPO_BRANCH` 选择对应分支的 patch 目录。`--cleanup` 会反向所有已知分支的 patch，确保切换 AVD 版本后不留残留。

### 当前 patch

```text
patches/common-android14-6.1/0001-tools-lib-subcmd-avoid-glibc-c23-strtol-redirect.patch
patches/kernelsu/0001-add-resukisu-cert-and-version-pin.patch
```

**`0001-tools-lib-subcmd`**：规避 glibc 2.38+ 的 C23 strtol redirect 与旧 Android host sysroot 的链接冲突，仅 6.1 需要。

**`0001-add-resukisu-cert-and-version-pin`** 做三件事：

1. **Kbuild 版本公式**：移除 `curl` GitHub API 网络依赖，改用本地 git 公式 `40000 + rev-list --count HEAD - 2815`，并加入 `-include ksu_version.override.mk` 支持外部版本 pin。
2. **ReSukiSU 证书**：在 `manager_sign.h` 添加 ReSukiSU 签名证书（size=`0x377`），在 `apk_sign.c` 的 `apk_sign_keys[]` 中注册（index 1），使 prebuilt APK 被内核识别为合法 manager。
3. **seccomp 修复**：`disable_seccomp_for_task()` 在 `CONFIG_GENERIC_ENTRY`（x86 6.1+）下使用 `clear_task_syscall_work(tsk, SECCOMP)` 替代 `clear_tsk_thread_flag(tsk, TIF_SECCOMP)`，因为开启 `GENERIC_ENTRY` 后 x86 不再定义 `TIF_SECCOMP`。

### 版本匹配机制

| 组件 | 公式 | 当前值 |
|---|---|---|
| prebuilt APK versionCode | `30000 + commit_count + 700`（旧 SukiSU 公式） | `34990` |
| Kbuild 自然公式 | `40000 + commit_count - 2815`（新 ReSukiSU 公式） | `40199` |
| 实际驱动版本 | `ksu_version.override.mk` pin | `34990`（匹配 APK） |

prebuilt APK 与当前 submodule 使用不同版本公式，无法自然对齐。`setup.sh` 写入 `ksu_version.override.mk` 将 `KSU_VERSION` pin 为 APK 的 versionCode（默认 `34990`，可通过 `KSU_VERSION_PIN` 环境变量覆盖）。`KSU_VERSION_FULL`（显示字符串）不受 pin 影响，走自然 git 公式。

### Manager 识别

- **主 manager**：`apk_sign_keys[]` 中硬编码的证书（index 0 = ShirkNeko/SukiSU，index 1 = ReSukiSU）。prebuilt APK 通过 ReSukiSU 证书被识别。
- **多 manager**：v4.1.0 的 `dynamic_manager` 机制（`dynamic_manager.c`）在运行时经 `KSU_IOCTL_DYNAMIC_MANAGER` ioctl 启用，可注册额外 manager 签名。不依赖 Kconfig 开关，总是编译进内核。注意：`CONFIG_KSU_MULTI_MANAGER_SUPPORT` 是旧版（88e7f51c）的 Kconfig，v4.1.0 已移除。

### 构建系统

- **Modern（Android 13+ / 5.10+）**：Bazel/Kleaf，目标 `//common-modules/virtual-device:virtual_device_x86_64_dist`。
- **Legacy（Android 11 / 5.4）**：`build/build.sh` + `BUILD_CONFIG`。
- `build.sh` 自动检测：存在 `common-modules/virtual-device/BUILD.bazel` 则用 Bazel。
- Bazel 构建注入 host-tools 兼容参数（`HOSTCFLAGS=--sysroot= -std=gnu11` 等），规避 glibc C23 链接错误。
- 构建后 `verify_ksu_enabled()` 检查 `.config` 中 `CONFIG_KSU=y`，防止 KSU 静默未编译。

### CONFIG_KSU

`CONFIG_KSU` 在 `KernelSU/kernel/Kconfig` 中 `default y`，因此无需额外 defconfig fragment。只要 `setup.sh` 正确写入 `drivers/Kconfig` source 入口，`make defconfig` 后 `CONFIG_KSU` 会自动启用。`build.sh` 在构建后验证这一点。

## 关键约束

1. **不要直接编辑 `common/`、`common-modules/`、`build/` 中的文件**——这些是 repo 管理的上游源码。所有改动通过 `patches/` + `setup.sh` 重放。
2. **不要在 `KernelSU/` 中直接修改并提交**——它是 git submodule，改动通过 `patches/kernelsu/` 应用。`setup.sh --cleanup` 会还原。
3. **更换 prebuilt APK 时**：更新 APK 文件，用 `KSU_VERSION_PIN=<versionCode> bash setup.sh` 设置匹配的版本号。
4. **切换 AVD 内核版本时**：先 `setup.sh --cleanup`（清理旧分支 patch），再 `prepare.sh`（新版本），再 `setup.sh`。
5. **ARM64 主机构建 x86_64**：需要 binfmt/QEMU（`podman run --privileged --rm docker.io/tonistiigi/binfmt --install amd64`），legacy 构建可能需要 `QEMU_LD_PREFIX`。

## 验证命令

```bash
# 检查 patch 可应用性
bash setup.sh --check

# Dry-run 构建
bash build.sh --dry-run

# 验证版本匹配
grep '^KSU_VERSION' KernelSU/kernel/ksu_version.override.mk
aapt dump badging ReSukiSU_*.apk | grep versionCode

# 验证 submodule 版本
git -C KernelSU describe --tags HEAD
```

## Git 仓库结构

本仓库只追踪：构建脚本（`*.sh`）、元数据工具（`scripts/`）、patch series（`patches/`）、文档（`README.md`/`AGENTS.md`）、KernelSU submodule 引用（`.gitmodules`）。

不追踪：repo 管理的上游源码（`common/`、`build/` 等）、构建产物（`out/`、`dist/`）、Bazel 符号链接（`bazel-*`、`WORKSPACE`）、prebuilt APK、KernelSU backup 目录。详见 `.gitignore`。
