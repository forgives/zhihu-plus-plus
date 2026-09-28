# macOS 本地编译指南

本文记录在 macOS（Apple Silicon）上本地编译 Zhihu++ Android lite 包的环境要求、一键脚本用法，以及实际踩过的构建陷阱和对应方案。CI 不受本文影响，全量 instrument 测试仍交给 GitHub Actions。

## 一键脚本

```bash
./build-lite-macos.sh [debug|release] [arm64-v8a|armeabi-v7a|x86|x86_64|all]
# 默认 release + 全 ABI；例如只构建 arm64-v8a：
./build-lite-macos.sh release arm64-v8a
```

脚本自动处理 JDK 选择、签名变量加载、SDK 路径兜底、Gradle 选择（本机 Gradle 9.7.1 → PATH 中的 gradle → 项目 wrapper），并在结束时打印产物路径和 APK 内的 native 库列表，便于确认 ABI 过滤是否生效。

## 环境要求

| 依赖 | 要求 |
|---|---|
| JDK | 17+，且必须是 **arm64 原生**（Apple Silicon） |
| Android SDK | 默认位置 `~/Library/Android/sdk`，缺失 `local.properties` 时脚本自动生成 |
| Gradle | 脚本优先用 `~/tools/gradle-9.7.1`，也可用 wrapper |
| 签名 | release 签名环境变量 `signingKey` / `keyAlias` / `keyStorePassword` / `keyPassword`，定义在 `~/.zshenv`，脚本会自动加载 |

### JDK 相关的两个陷阱

1. **shell 全局固定 JDK 8**：本机 `~/.zshrc` 将 `JAVA_HOME` 固定为 JDK 8，直接执行 `./gradlew` 会报 `Gradle requires JVM 17 or later to run`。脚本内用 `/usr/libexec/java_home -v 17` 强制切换；手动执行 Gradle 命令时需要先 `export JAVA_HOME=$(/usr/libexec/java_home -v 17)`。
2. **Intel JDK 伪装问题**：Apple Silicon 上如果 Gradle 使用了 Intel (x86_64) 架构的 JDK，Kotlin/Native 会把 host 误判为 `macos_x64`，产生难懂的编译错误。用 `/usr/libexec/java_home -v 17 -a arm64` 或 `file $(java -home)/bin/java` 确认二进制架构。

### 网络代理

`maven.google.com` 等仓库在部分网络下直连不通，需在 `~/.gradle/gradle.properties` 中配置代理（本机使用 `127.0.0.1:7890` 的 HTTP/HTTPS 代理）。

## ABI 过滤（v8a-only 等单架构构建）

**不要使用** `./gradlew assembleLiteRelease -Pandroid.injected.build.abi=arm64-v8a`。项目使用 AGP 9.4，实测存在两个问题：

1. AGP 9 移除了大量注入属性与废弃 DSL 的支持，`android.injected.build.abi` 在 9.x 上不再生效——构建成功但 APK 仍包含全部 4 个 ABI 的 native 库。参见 [AGP 9.0 release notes](https://developer.android.com/build/releases/agp-9-0-0-release-notes) 与 [issuetracker #280831521](https://issuetracker.google.com/issues/280831521)（injected 属性在逐步移除）。
2. 该属性即使在受支持的 AGP 版本上也不参与任务的 up-to-date 指纹：切换属性后打包任务可能直接 `UP-TO-DATE`，**拿到一个 mtime 更旧的"新产物"**，极具迷惑性。

**正确方案**：用 Gradle init script 显式配置 `packaging.jniLibs.excludes`（AGP 9 支持的稳定 API），排除目标 ABI 之外的目录：

```groovy
// abi-filter.init.gradle，例如仅保留 arm64-v8a
allprojects {
    plugins.withId("com.android.application") {
        android {
            packaging {
                jniLibs {
                    excludes += ['lib/armeabi-v7a/**', 'lib/x86/**', 'lib/x86_64/**']
                }
            }
        }
    }
}
```

```bash
./gradlew :app:assembleLiteRelease -I abi-filter.init.gradle
```

`build-lite-macos.sh` 传 ABI 参数时自动生成并使用该 init script，构建完成后删除。

## 产物验证

构建成功不等于产物正确（见上面的旧产物陷阱），分发前至少检查：

```bash
# 1. native 库只含目标 ABI
unzip -l app/build/outputs/apk/lite/release/app-lite-release.apk | grep "lib/"

# 2. 签名有效且证书正确（V2，证书 SHA-256 前几位应与发布证书一致）
~/Library/Android/sdk/build-tools/<version>/apksigner verify --print-certs \
    app/build/outputs/apk/lite/release/app-lite-release.apk

# 3. 确认 mtime 是本次构建时间，而不是历史残留
ls -lh app/build/outputs/apk/lite/release/
```

## 本地测试范围

本地只做必要的构建与定向验证，与 AGENTS.md 的验证边界一致：

```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 17)

./gradlew :shared:jvmTest                            # 共享模块单元测试（含 common tests）
./gradlew :app:compileLiteDebugAndroidTestKotlin      # androidTest 编译验证（不运行）
./gradlew ktlintFormat                                # 格式化
```

完整 `connectedLiteDebugAndroidTest` 交给 CI；需要设备复现个别失败时，按 AGENTS.md 的 AVD 选择流程做定向验证。
