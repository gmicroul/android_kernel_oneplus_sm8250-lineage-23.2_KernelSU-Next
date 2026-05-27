#!/bin/bash

# =======================================================
# 一加 9R (SM8250) 内核编译脚本 - KernelSU Next 纯净内建版
# =======================================================

# 1. 路径配置
NDK_DIR="${NDK_DIR:-$HOME/toolchains/android-ndk-r29}"
GCC_64_DIR="${GCC_64_DIR:-$HOME/toolchains/aarch64-linux-android-4.9}"
GCC_32_DIR="${GCC_32_DIR:-$HOME/toolchains/arm-linux-androideabi-4.9}"

KERNEL_DIR="$(pwd)"
OUT_DIR="${KERNEL_DIR}/out"
CLANG_DIR="${CLANG_DIR:-${NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64}"

if [ "${1:-}" != "--prepare-only" ]; then
    # 环境校验
    if [ ! -d "$CLANG_DIR/bin" ]; then
        echo "❌ 错误: 找不到 Clang 路径，请检查 NDK 路径！"
        exit 1
    fi

    export PATH="${CLANG_DIR}/bin:${GCC_64_DIR}/bin:${GCC_32_DIR}/bin:${PATH}"
fi
export ARCH=arm64
export SUBARCH=arm64

DEFCONFIG="vendor/kona-perf_defconfig"
OPLUS_CONFIG="arch/arm64/configs/vendor/oplus.config"

MAKE_ARGS=(
    O=${OUT_DIR}
    ARCH=${ARCH}
    SUBARCH=${SUBARCH}
    CC="clang"
    LD="ld.lld"
    AR="llvm-ar"
    NM="llvm-nm"
    OBJCOPY="llvm-objcopy"
    OBJDUMP="llvm-objdump"
    STRIP="llvm-strip"
    CROSS_COMPILE="aarch64-linux-android-"
    CROSS_COMPILE_ARM32="arm-linux-androideabi-"
    CLANG_TRIPLE="aarch64-linux-gnu-"
    LLVM=1
    LLVM_IAS=1
)

# ==========================================
# 2. KernelSU Next 源码获取与注入
# ==========================================
echo ">>> 正在处理 KernelSU Next 源码..."

# 确保源码被正确放置在 drivers/kernelsu。
# 这个仓库的 upstream 带有坏的 KernelSU gitlink 和 drivers/kernelsu symlink，
# CI/本地构建时统一替换成真实源码目录，避免复制进自身。
if [ -d "KernelSU-Next/kernel" ]; then
    rm -rf drivers/kernelsu
    cp -a KernelSU-Next/kernel drivers/kernelsu
    if [ -d "KernelSU-Next/uapi" ]; then
        cp -a KernelSU-Next/uapi drivers/kernelsu/uapi
    fi
elif [ -d "KernelSU" ]; then
    rm -rf drivers/kernelsu
    mv KernelSU drivers/kernelsu
fi

if [ -d "drivers/kernelsu" ] && { [ ! -f "drivers/kernelsu/uapi/app_profile.h" ] || [ ! -d "drivers/kernelsu/.git" ]; }; then
    echo ">>> KernelSU Next uapi/.git 缺失，重新浅克隆 ${KERNELSU_NEXT_REF:-legacy} 分支补齐 public headers 和版本信息..."
    tmp_ksu="$(mktemp -d)"
    git clone --depth=1 --branch "${KERNELSU_NEXT_REF:-legacy}" \
        https://github.com/KernelSU-Next/KernelSU-Next.git "$tmp_ksu"
    if [ -d "$tmp_ksu/uapi" ]; then
        rm -rf drivers/kernelsu/uapi
        cp -a "$tmp_ksu/uapi" drivers/kernelsu/uapi
    fi
    if [ -d "$tmp_ksu/.git" ]; then
        rm -rf drivers/kernelsu/.git
        cp -a "$tmp_ksu/.git" drivers/kernelsu/.git
    fi
    rm -rf "$tmp_ksu"
fi

if [ -d "drivers/kernelsu" ] && [ ! -f "drivers/kernelsu/uapi/app_profile.h" ]; then
    echo "❌ 错误: KernelSU Next uapi/app_profile.h 仍然缺失"
    exit 1
fi
if [ -d "drivers/kernelsu" ] && [ ! -d "drivers/kernelsu/.git" ]; then
    echo "❌ 错误: KernelSU Next .git 仍然缺失，版本号会 fallback 到 v0.0.1"
    exit 1
fi

# 注入 Makefile
if ! grep -q "kernelsu" drivers/Makefile; then
    echo "obj-\$(CONFIG_KSU) += kernelsu/" >> drivers/Makefile
    echo "✅ Makefile 已注入 kernelsu 路径"
fi

# 注入 Kconfig
if ! grep -q "kernelsu" drivers/Kconfig; then
    sed -i '$i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    echo "✅ Kconfig 已注入 kernelsu 路径"
fi

if [ "${1:-}" = "--prepare-only" ]; then
    echo "✅ KernelSU Next 源码准备完成。"
    exit 0
fi

# ==========================================
# 3. 构建环境准备与配置
# ==========================================
echo ">>> 清理旧的构建产物..."
rm -rf ${OUT_DIR}
mkdir -p ${OUT_DIR}

echo ">>> 生成基础配置..."
make "${MAKE_ARGS[@]}" ${DEFCONFIG}

if [ -f "$OPLUS_CONFIG" ]; then
    echo ">>> 合并厂商配置碎片..."
    ARCH=arm64 ./scripts/kconfig/merge_config.sh -m -O ${OUT_DIR} ${OUT_DIR}/.config ${OPLUS_CONFIG}
fi

# ==========================================
# 4. 强制内建宏注入 (非 GKI 必须 Built-in)
# ==========================================
echo ">>> 注入 KernelSU Next 内建配置..."
{
    echo "CONFIG_OPLUS_DEVICE_INFO=y"
    echo "CONFIG_OPLUS_SYSTEM_KERNEL=y"
    echo "CONFIG_OPLUS_PROJECT_INFO=y"
    echo "CONFIG_OPLUS_CHG=y"
    echo "CONFIG_OPLUS_CHG_KONA=y"
    echo "CONFIG_OPLUS_SM8250_CHARGER=y"
    echo "CONFIG_QPNP_SMB5=y"
    echo "CONFIG_OPLUS_SENSOR_SMEM=y"
    echo "CONFIG_SND_SOC_WCD_MBHC=y"

    # KernelSU Next 核心配置：必须设为 y (内建)
    echo "CONFIG_KSU=y"
    # 可选：禁用 KPROBES 检查，因为我们使用的是手动 Hook
    echo "CONFIG_KSU_MANUAL_HOOK=y" 
} >> ${OUT_DIR}/.config

echo ">>> 同步 olddefconfig..."
make "${MAKE_ARGS[@]}" olddefconfig

# ==========================================
# 5. 执行编译
# ==========================================
JOBS=$(nproc --all)
echo ">>> 启动多线程编译 (Jobs: ${JOBS})..."
START_TIME=$(date +%s)

# 注意：这里去掉了 modules，只编译 Image
make -j${JOBS} "${MAKE_ARGS[@]}" Image

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# ==========================================
# 6. 产物校验
# ==========================================
IMAGE_PATH="${OUT_DIR}/arch/arm64/boot/Image"

echo "----------------------------------------------------"
if [ -f "$IMAGE_PATH" ]; then
    echo "✅ 内核编译成功！"
    echo "📦 镜像位置: $IMAGE_PATH"
    echo "💡 KernelSU Next 已成功内建入 Image 中。"
else
    echo "❌ 错误: 内核镜像生成失败，请检查上方日志。"
fi
echo "⏱️ 耗时: $((ELAPSED / 60)) 分 $((ELAPSED % 60)) 秒"
echo "----------------------------------------------------"

