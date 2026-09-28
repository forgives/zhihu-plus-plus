#!/bin/bash
# Zhihu++ lite 版本 macOS 一键编译脚本
# 用法: ./build-lite-macos.sh [debug|release] [arm64-v8a|armeabi-v7a|x86|x86_64|all]
#   默认 release + 全 ABI。ABI 参数只保留单一架构，产物更小（详见 docs/build-macos.md）。
set -euo pipefail
cd "$(dirname "$0")"

usage() { echo "用法: $0 [debug|release] [arm64-v8a|armeabi-v7a|x86|x86_64|all]" >&2; exit 1; }

BUILD_TYPE="${1:-release}"
case "$BUILD_TYPE" in
    debug) TASK="assembleLiteDebug" ;;
    release) TASK="assembleLiteRelease" ;;
    *) usage ;;
esac

ABI="${2:-all}"
ALL_ABIS="arm64-v8a armeabi-v7a x86 x86_64"
case "$ABI" in
    all|arm64-v8a|armeabi-v7a|x86|x86_64) ;;
    *) usage ;;
esac

# 全局 ~/.zshrc 将 JAVA_HOME 固定为 JDK 8，Gradle daemon 需要 JDK 17，这里强制指定。
# Apple Silicon 上必须用 arm64 原生 JDK，Intel JDK 会让 Kotlin/Native 误判 host 为 macos_x64。
if ! JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null)"; then
    echo "错误: 未找到 JDK 17，请先安装" >&2
    exit 1
fi
export JAVA_HOME
echo ">> JAVA_HOME=$JAVA_HOME"

# 签名环境变量（signingKey/keyAlias/keyStorePassword/keyPassword）定义在 ~/.zshenv，
# 非 zsh 环境执行本脚本时手动加载
if [ -z "${signingKey:-}" ] && [ -f "$HOME/.zshenv" ]; then
    . "$HOME/.zshenv"
fi

# SDK 路径兜底（macOS 默认位置）
if [ ! -f local.properties ] && [ -d "$HOME/Library/Android/sdk" ]; then
    echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties
fi

# 优先用本机安装的 Gradle 9.7.1，其次 PATH 中的 gradle，最后项目 wrapper
if [ -x "$HOME/tools/gradle-9.7.1/bin/gradle" ]; then
    GRADLE="$HOME/tools/gradle-9.7.1/bin/gradle"
elif command -v gradle >/dev/null 2>&1; then
    GRADLE="gradle"
else
    GRADLE="./gradlew"
fi
echo ">> Gradle: $GRADLE"

# AGP 9 已移除 android.injected.build.abi 注入属性的支持，且该属性不参与任务
# up-to-date 检查（改动后打包任务不会失效，容易拿到旧的全 ABI 产物）。
# 因此用 init script 显式配置 packaging.jniLibs.excludes 排除其余 ABI。
GRADLE_ARGS=()
if [ "$ABI" != "all" ]; then
    EXCLUDES=""
    for a in $ALL_ABIS; do
        [ "$a" = "$ABI" ] || EXCLUDES+="${EXCLUDES:+, }\"lib/${a}/**\""
    done
    INIT_SCRIPT="build/abi-filter.init.gradle"
    mkdir -p build
    cat > "$INIT_SCRIPT" <<EOF
// 由 build-lite-macos.sh 生成：仅保留 ${ABI}，构建后自动删除
allprojects {
    plugins.withId("com.android.application") {
        android {
            packaging {
                jniLibs {
                    excludes += [$EXCLUDES]
                }
            }
        }
    }
}
EOF
    GRADLE_ARGS+=(-I "$INIT_SCRIPT")
    echo ">> ABI: 仅保留 $ABI"
fi

"$GRADLE" ":app:$TASK" "${GRADLE_ARGS[@]}"
if [ "$ABI" != "all" ]; then
    rm -f "build/abi-filter.init.gradle"
fi

APK_DIR="app/build/outputs/apk/lite/$BUILD_TYPE"
APK="$(ls -t "$APK_DIR"/*.apk 2>/dev/null | head -1)"
if [ -z "$APK" ]; then
    echo "错误: 未找到产物 APK" >&2
    exit 1
fi
case "$APK" in
    *unsigned*) echo ">> 警告: 产物未签名（~/.zshenv 中缺少签名环境变量？）" ;;
    *) echo ">> 已签名" ;;
esac
echo ">> 产物: $APK"
echo ">> 产物 native 库:"
unzip -l "$APK" | grep "lib/" || echo ">>   （无 native 库）"
