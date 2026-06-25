# ReSukiSU AVD Kernel Builder

用于为 Android Emulator / AVD 的 `x86_64` virtual-device 内核准备、集成、构建和打包 ReSukiSU。设计目标是：切换 AVD 内核版本时只改输入的 `/proc/version`，上游源码修改全部通过 `patches/` 重放，不把临时改动混进 AOSP 仓库。

## 目录结构

```text
android-kernel/
├── prepare.sh                 # 解析 /proc/version，repo init/sync，按 CI commit 对齐
├── setup.sh                   # 应用 patch series，创建 ReSukiSU symlink
├── build.sh                   # 调用 Bazel/Kleaf 或 legacy build.sh，支持 --dry-run
├── package.sh                 # 从 dist/ 打包部署包，不编译
├── scripts/
│   └── avd_kernel_meta.py     # 版本解析和 CI BUILD_INFO 元数据工具
├── patches/                   # 可选 patch 目录；默认可以为空
├── ksu.fragment               # ReSukiSU Kconfig 片段
├── KernelSU/                  # ReSukiSU submodule
├── common/                    # repo sync 得到的 kernel/common
├── common-modules/            # repo sync 得到的 virtual-device modules
├── out/                       # 生成的 target.json/target.env 和中间产物
└── dist/                      # 构建产物
```

## 典型流程

### 1. 准备目标版本

把 AVD 的完整 `/proc/version` 直接传给 `prepare.sh`：

```bash
bash prepare.sh --proc-version \
'Linux version 6.1.23-android14-4-00257-g7e35917775b8-ab9964412 (build-user@build-host) ...'
```

该示例会解析为：

```text
repo branch : common-android14-6.1
build id    : 9964412
commit      : 7e35917775b8
```

`prepare.sh` 会生成：

```text
out/target.json   # 完整元数据和 CI 状态
out/target.env    # build/setup 脚本可 source 的环境变量
```

脚本会读取 Android CI `BUILD_INFO` 的 `repo-dict`，并 checkout `kernel/common`、`kernel/common-modules/virtual-device`、`kernel/build`、`kernel/configs` 等仓库的精确 commit。Android CI 的 `view/BUILD_INFO` 页面有时返回 Artifact Viewer HTML，脚本会自动解析其中的签名 artifact URL 再下载真实 JSON。

对 Android 13/14/15 的 Bazel/Kleaf 分支，不能只对齐 `kernel/common`。如果 `common-modules/virtual-device` 留在 branch tip，而 `common` 切到旧 commit，会出现类似 `//common:modules.bzl does not contain symbol get_gki_modules_list` 的 Bazel API mismatch。`prepare.sh` 和 `build.sh` 会在这种不完整状态下直接失败，要求重新执行准备步骤。

### 2. 集成 ReSukiSU

```bash
bash setup.sh
```

`setup.sh` 会做三类事情：

- 如果 `patches/` 中存在 patch，则通过 `git apply` 应用；
- 临时向 `common/drivers/Kconfig` 和 `common/drivers/Makefile` 写入 ReSukiSU 入口；
- 创建未跟踪 symlink：`common/drivers/kernelsu -> ../../KernelSU/kernel`。

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

`build.sh` 会先校验 `out/target.json` 中记录的 CI commit 是否与当前源码 checkout 一致。如果你更新了脚本或换了 `/proc/version`，先重新运行：

```bash
bash prepare.sh --proc-version-file proc-version.txt -j16
bash setup.sh --cleanup 2>/dev/null || true
bash setup.sh
bash build.sh -j16
```

等价核心目标：

```bash
//common-modules/virtual-device:virtual_device_x86_64_dist
```

Android 11 / 5.4 等 legacy 分支才会退回 `build/build.sh`。

### 4. 打包

```bash
bash package.sh
```

生成：

```text
avd-resukisu-deploy/
avd-resukisu-deploy.tar.gz
```

`package.sh` 不编译，只从现有 `dist/` 收集 `bzImage` 和 `.ko`。

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

默认情况下 `patches/` 可以为空，ReSukiSU 通过 `setup.sh` 写入临时 driver 入口并创建软链接接入。运行：

```bash
bash setup.sh --cleanup
```

会移除这些临时入口和软链接，让 `common/` 回到 clean 状态。

不要把手工编辑留在 `common/`、`common-modules/` 或 `build/` 里作为长期定制。确实需要额外上游改动时：

1. 在临时工作区修改并确认 diff；
2. 生成 patch 到 `patches/common/` 或 `patches/<repo-branch>/`；
3. 让 `setup.sh` 通过 `git apply` 应用；
4. 用 `setup.sh --cleanup` 验证可反向恢复。

当前默认补丁目录为空；新增 patch 后可用 `bash setup.sh --check` 检查可应用性。

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
  --repo-branch common-android14-6.1 \
  --build-id 9964412 \
  --common-commit 7e35917775b8
```

只同步，不 checkout CI commit：

```bash
bash prepare.sh --proc-version-file proc-version.txt --no-checkout
```
