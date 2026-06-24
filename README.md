# ReSukiSU AVD Kernel Builder

构建带 [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) 的 Android Virtual Device (AVD / Goldfish) x86_64 内核，用于在 ARM64 VPS 上交叉编译。

## 目录结构

```
android-kernel/
├── common/                  # Android Common Kernel 源码 (repo sync)
├── common-modules/          # 外部内核模块 (virtual-device, etc.)
├── resukisu-kernel/         # ReSukiSU 内核模块源码
├── patches/                 # 内核集成补丁
├── prebuilts/               # Clang/GCC 预编译工具链 (repo sync)
├── build/                   # 构建工具
├── ksu.fragment             # ReSukiSU 内核配置片段
├── setup.sh                 # 集成设置脚本
├── build.sh                 # 构建脚本
├── README.md                # 本文件
├── out/                     # 构建输出 (git ignored)
└── dist/                    # 最终产物 (git ignored)
```

## 前提条件

- ARM64 或 x86_64 Linux 主机
- `repo` 工具 (Android 源码管理)
- ARM64 主机需要 QEMU user-mode 支持以运行 x86_64 工具链

### 安装 repo

```bash
mkdir -p ~/bin
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
chmod a+x ~/bin/repo
export PATH="$HOME/bin:$PATH"
```

### ARM64 主机: 安装 QEMU x86_64 支持

```bash
# 使用 tonistiigi/binfmt 注册 x86_64 binfmt
docker run --privileged --rm tonistiigi/binfmt --install x86_64

# 或手动安装 qemu-user-static
sudo dnf install -y qemu-user-static  # RHEL/AlmaLinux
sudo apt-get install -y qemu-user-static  # Debian/Ubuntu
```

## 快速开始

### 1. 首次设置 — 同步内核源码

```bash
cd /path/to/android-kernel

# 初始化 repo (android14-6.1 GKI 分支)
repo init -u https://android.googlesource.com/kernel/manifest -b common-android14-6.1

# 同步内核源码和工具链
repo sync -c kernel/common kernel/common-modules/virtual-device kernel/configs \
    prebuilts/clang/host/linux-x86 platform/prebuilts/build-tools \
    kernel/prebuilts/build-tools platform/prebuilts/clang-tools
```

### 2. 集成 ReSukiSU

```bash
bash setup.sh
```

此脚本会：
- 将 `resukisu-kernel/kernel/` 复制到 `common/drivers/resukisu/`
- 应用 `patches/` 目录下的补丁（修改 drivers/Kconfig 和 drivers/Makefile）

### 3. 构建内核

```bash
bash build.sh
```

产物在 `dist/` 目录中：
- `bzImage` — 内核镜像
- `*.ko` — 内核模块
- `vmlinux` — 未压缩内核 (调试用)
- `System.map` — 符号表
- `build-info.txt` — 构建信息

### 4. 部署到 AVD

```bash
# 在本地机器上 (需要 Android SDK)
adb root
adb remount
adb push dist/bzImage /data/local/tmp/
adb push dist/*.ko /vendor/lib/modules/

# 加载内核模块 (在 adb shell 中)
su -c "insmod /vendor/lib/modules/<module>.ko"

# 验证
adb shell cat /proc/version
adb shell su -c "id"
```

## 切换内核版本

当你需要为不同的 AVD 内核版本构建时：

### 1. 获取目标 AVD 的内核版本

在已启动的 AVD 上运行：

```bash
adb shell cat /proc/version
```

输出示例：
```
Linux version 6.1.23-android14-4-00257-g7e35917775b8-ab9964412 ...
```

关键信息：
- **内核版本**: 6.1.23-android14-4 → GKI 分支 `android14-6.1`
- **Build ID**: ab9964412
- **Commit**: 7e35917775b8

### 2. 重新初始化 repo

```bash
# 切换到对应的 GKI 分支
repo init -u https://android.googlesource.com/kernel/manifest -b common-android14-6.1

# 或指定其他分支，如:
# repo init -u ... -b common-android15-6.6    (Android 15, kernel 6.6)
# repo init -u ... -b common-android13-5.15   (Android 13, kernel 5.15)

repo sync -c
```

### 3. 检出精确的内核 commit (可选)

```bash
cd common
git checkout <commit-hash>  # 例如: 7e35917775b8
cd ..
```

### 4. 重新集成和构建

```bash
bash setup.sh
bash build.sh
```

### GKI 版本对照

| Android 版本 | GKI 分支 | 内核版本 |
|-------------|----------|---------|
| Android 14 | common-android14-6.1 | 6.1.x |
| Android 14 | common-android14-5.15 | 5.15.x |
| Android 13 | common-android13-5.15 | 5.15.x |
| Android 12 | common-android12-5.10 | 5.10.x |
| Android 11 | common-android11-5.4 | 5.4.x |

## ReSukiSU 配置选项

在 `ksu.fragment` 中可配置：

```conf
# 基础 KSU 支持 (必须)
CONFIG_KSU=y

# Hook 模式 (默认 tracepoint, 适用于 GKI 2.0 5.10+)
# CONFIG_KSU_TRACEPOINT_HOOK=y    # 默认

# 调试
# CONFIG_KSU_DEBUG=y

# 多管理器支持
# CONFIG_KSU_MULTI_MANAGER_SUPPORT=y

# SuSFS (需要内核侧 susfs 补丁)
# CONFIG_KSU_SUSFS=y
```

## 自定义 ReSukiSU 管理器签名

在构建时设置环境变量：

```bash
export KSU_EXPECTED_SIZE=<size>
export KSU_EXPECTED_HASH=<hash>
export KSU_MANAGER_PACKAGE=<package.name>
bash build.sh
```

## 故障排除

### QEMU/clang 无法运行 (ARM64)

```bash
export QEMU_LD_PREFIX=/opt/aosp-x86_64-sysroot
```

### repo sync 失败

```bash
# 减少并发数
repo sync -c -j2
```

### 内核模块签名错误

在 `ksu.fragment` 中确认：
```conf
# CONFIG_MODULE_SIG_ALL is not set
```

### ReSukiSU 编译错误

1. 检查内核版本兼容性 (ReSukiSU 支持 Linux 3.4+)
2. 确认所有依赖的 Kconfig 选项已启用 (如 `CONFIG_KALLSYMS`)
3. 查看 ReSukiSU 文档: https://resukisu.github.io
