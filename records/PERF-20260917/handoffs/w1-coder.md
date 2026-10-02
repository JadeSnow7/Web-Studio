# W1 isolated candidate handoff

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

状态：准备完成，待主线程串行执行构建、smoke、像素和 GUI 矩阵；本交接未修改生产源码，也未运行构建、性能或 GUI 检查。

## 隔离输入

- 冻结源码归档：`records/PERF-20260917/evidence/source-baseline.tar.gz`
- 归档 SHA-256：`7f03e8ee925eddd01a00539c0c696ae8676cd0e8896e121d773831cfbf8cea4b`
- 归档解压得到 control 与 candidate 两棵树：`/private/tmp/web-studio-perf-w1-20260917/control`、`/private/tmp/web-studio-perf-w1-20260917/candidate`
- 两棵树的 `Vendor` 都是指向当前 pinned `Vendor` 的只读符号链接；没有复制或修改依赖。
- Vendor 归一化目录指纹（相对路径 + 文件 SHA-256）：`c4b2bbcd46015aa1d9bb514d4ed508575dc02cd6e7836ad7b5c776598fffd11a`
- 关键依赖：`Vendor/GhosttyVT/DEPENDENCY.lock` `d158ab3bb4cd70bde91f4402791a7ce4fcd91148ca170a4a86c94cd5841331a1`；`Vendor/GhosttyKit.xcframework/Info.plist` `fadac8e5e9ae13d77d25177d24d0ae51de3f0cbd8876e3272a798cd74c0b4aaf`；`Vendor/GhosttyVT/lib/libghostty-vt.a` `dc8b44f3591acd227c1176b67238287ea894fe8af37cb114bf2a45a7669ce10b`。

## Patch 核验

- 候选：`output/terminal-vt-migration/evidence/performance-investigation-20260916/experiments/font-frame-cache.patch`
- Patch SHA-256：`db16b3e5fa878066ef8a82ec1825e81444e9612360944bfaa20dec87192cded`
- 在 control 上执行 `git apply --check`：通过（退出码 0）。
- candidate 上只应用该 patch；`git diff --name-only` 只有 `Web Studio/TerminalMetalRenderer.swift`，`git diff --check` 通过。
- control renderer SHA-256：`44f7702330e5b4f5dde3ec817ed4f79017c3733afa09aaa3225c57a7cfe44c0d`
- candidate renderer SHA-256：`ee006eb4878dc2b562e6a15e731954923ec3d6a3fa3e7076ed1aece26d303578`
- 精确差异：render 内增加 `[Int: NSFont]` 的四键缓存，key 为 regular/bold/italic/bold-italic 的 bold/italic 位；请求收集和 cell 绘制两处 `font(for:)` 改为使用同一帧缓存。miss 仍调用原 `font(for:)`，所以字号、fallback 与 italic 转换语义不变。
- 未改变 `PreparedAtlas`、atlas 失效和重建、`inflightGate`、command completion handler、texture 生命周期、提交/呈现顺序或 `prepareGlyphs`。缓存只在单次 `render` 调用内存在，天然有界，下一帧不会复用旧对象。

## 主线程可复跑命令

以下命令必须由主线程通过冻结记录的 `record_execution.py` 串行执行，并为每次输出使用新的 `/private/tmp` 路径：

```sh
scripts/test-terminal-font-frame-equivalence.sh --source-root /private/tmp/web-studio-perf-w1-20260917/control --output /private/tmp/perf-w1-control-font-<run-id>
scripts/test-terminal-font-frame-equivalence.sh --source-root /private/tmp/web-studio-perf-w1-20260917/candidate --output /private/tmp/perf-w1-candidate-font-<run-id>
scripts/test-terminal-unicode-diagnostic.sh --source-root /private/tmp/web-studio-perf-w1-20260917/control --output /private/tmp/perf-w1-control-unicode-<pair-id>
scripts/test-terminal-unicode-diagnostic.sh --source-root /private/tmp/web-studio-perf-w1-20260917/candidate --output /private/tmp/perf-w1-candidate-unicode-<pair-id>
```

Unicode diagnostic应分别按 control/candidate 新建六对、交替顺序运行；它是离屏诊断，不替代计划要求的 App 八类场景。候选与 control 的 Release arm64 构建应使用关闭 coverage/sanitizer 的独立 derived data，例如：

```sh
xcodebuild -project 'Web Studio.xcodeproj' -scheme 'Web Studio VT' -configuration Release -sdk macosx -arch arm64 -derivedDataPath /private/tmp/perf-w1-control-derived-<run-id> CODE_SIGNING_ALLOWED=NO GCC_GENERATE_TEST_COVERAGE_FILES=NO CLANG_ENABLE_CODE_COVERAGE=NO
xcodebuild -project 'Web Studio.xcodeproj' -scheme 'Web Studio VT' -configuration Release -sdk macosx -arch arm64 -derivedDataPath /private/tmp/perf-w1-candidate-derived-<run-id> CODE_SIGNING_ALLOWED=NO GCC_GENERATE_TEST_COVERAGE_FILES=NO CLANG_ENABLE_CODE_COVERAGE=NO
```

完整矩阵仍须覆盖中文 IME、宽字符/组合字符/Emoji、选区、亮暗主题、缩放、隐藏恢复、双栏 resize 和资源压力，并记录反向结果。采用仍 pending：需完整 control/candidate 数据、GUI 与资源生命周期证据；无收益或有可重复回归时丢弃隔离 candidate 即可回滚。
