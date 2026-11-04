# third_party/flutter_inappwebview_android

`flutter_inappwebview_android` **1.1.3** 的本地副本，用于绕过 AGP 9 的兼容性阻断。
**除下面 2 行外，本目录与 pub 上的 1.1.3 逐字节一致**（Dart API 与 Kotlin 实现均原样保留）。

## 唯一差异

`android/build.gradle` 第 44、48 行：

```groovy
- proguardFiles getDefaultProguardFile('proguard-android.txt'), 'proguard-rules.pro'
+ proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
```

原因：AGP 9 移除了默认规则文件 `proguard-android.txt`（含 `-dontoptimize`），调用即抛异常，
异常发生在**工程求值**阶段，整个 `assembleRelease` 无法开始。上游稳定线（1.1.3，2024-10 发布）
9 个多月未修，修复只落在 master / `1.2.0-beta.3`。

决策与被否决方案见工作空间文档
`D:\Trae-workspace\SuiDevAgent\technology\adr\037-AGP9不兼容的第三方插件采用本地补丁副本.md`。

## 与上游的另外两处「非代码」差别

* **未收录 `example/`**（24 文件 / 18 KB，与本应用构建无关；IDE 会对其自动 `pub get` 并生成
  `.dart_tool/`、`local.properties` 等派生物，纳入版本库只会制造噪声）；需要时从 pub 包自行取用；
* `.dart_tool/`、`pubspec.lock`、`local.properties` 等**生成物不入库**（仓库 `.gitignore` 已按
  `clients/flutter_app/third_party/**` 忽略）。Dart / Kotlin 源码、`android/` 构建脚本、`pubspec.yaml`
  与许可证等均与上游一致。

## 接入方式

`clients/flutter_app/pubspec.yaml`：

```yaml
dependency_overrides:
  flutter_inappwebview_android:
    path: third_party/flutter_inappwebview_android
```

## 核对（与上游的差异应只有 `android/build.gradle` 的 2 行）

```bash
diff -r "$HOME/.pub-cache/hosted/pub.dev/flutter_inappwebview_android-1.1.3" \
        clients/flutter_app/third_party/flutter_inappwebview_android
```

本机 pub 缓存走 `pub.flutter-io.cn` 镜像时，把上面路径中的 `pub.dev` 换成 `pub.flutter-io.cn`；
另外对比前请先排除本地生成物（`diff -r -x .dart_tool -x pubspec.lock -x local.properties`）。

## 升级 / 退出

1. **上游稳定版修复后**：删除本目录 + 删除 `pubspec.yaml` 的 `dependency_overrides` 块 → `flutter pub get`；
2. **上游小版本升级而仍需补丁**：用新版本覆盖本目录（同样不收录 `example/`）→ 重打同样 2 行 →
   更新本文档的版本号。

## 注意

* 库模块的 `buildTypes.proguardFiles` 不参与 app 的 R8 配置（真正生效的是 app 模块规则与插件的
  `consumerProguardFiles`），因此本补丁**不改变最终 APK 的混淆 / 优化行为**；
* `flutter pub upgrade` 不会升级本包（path 源），这是预期行为；
* 引入 / 升级任何带 android 实现的插件后，**必须立刻跑一次 Android release 构建**（Windows 构建走
  CMake，验不到 Gradle/AGP 层）。
