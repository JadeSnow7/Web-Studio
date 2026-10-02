# Web Studio 性能优化执行进度

> 2026-09-26 复核：生产 renderer 哈希仍与 W1 记录一致，候选未采用，W0/W1 仍部分完成。没有新增性能实测；本机测试包属于原候选交付，不能视为当前 B1 修复的构建。跨路线现状见 [STATUS](../../STATUS.md)。

已按 Veriflow L2 启动第一批 W0/W1。字体帧内复用候选在六组离屏进程配对中，四种负载固定 100 次热提交 CPU 中位数下降 77.3%–82.4%，各六对均改善；九幅 BGRA 逐字节一致。**这些结果不能外推为 App/输入延迟收益，字体候选尚未采用。**

W0 采样入口及七项边界测试完成；默认产品与 VT 控制组的真实 20 秒进程试采通过，但 GUI readiness 与场景未对齐，只作为工具集成验证。无 coverage 的默认/VT 构建与最终二进制已核验。

真实 App mixed 矩阵仅完成 1 个控制窗口，候选就绪超时，完整配对为 0。GUI 工具调用长时间阻塞且请求超时未按预期生效；其余八场景覆盖、IME/隐藏恢复/压力和 W2-W5 尚未完成。当前状态为继续调查，不能标完整验收或迁移完成。

- [W0 结果与缺口](W0-RESULTS.md)
- [W1 效果与采用边界](W1-RESULTS.md)
- [场景目录](SCENARIOS.json)
- [离屏原始配对汇总](evidence/offscreen-results.json)
- [GUI 阻塞回执](evidence/gui-blocker.json)
- [结构化状态](task-state.json)

生产 Swift 与原有未提交工作保留；新增采样脚本和独立 records/PERF-20260917 证据。默认后端仍为 GhosttyKit，没有提交、推送、迁移或部署。成本与 token 实耗未知，未估算。下一步为恢复有界 GUI 观察并补完整 W0/W1 验证，之后才决定采用及后续优化。

Veriflow record gate 已通过（两项报告位于 evidence 目录外的指纹提示保留）；这只验证记录一致性，整体产品验收仍未判定。原始清单3513项，其中3510项要求保持的输入逐一核验不变，3项可变缓存/profraw单列；计数说明见 evidence/preservation-count-detail.json。

## 本机测试包交付（2026-09-17）

用户在获知发布缺口后明确选择本机测试包，现已交付 `output/test-releases/2026.09.17-test1/Web-Studio-VT-2026.09.17-test1-arm64.zip`。包含同一已测字体优化候选，采用独立测试 bundle ID，生产源码与默认后端未改。压缩包解压后逐文件 hash、签名与候选二进制身份核验通过，解压副本实际存活5秒的进程启动检查通过；GUI readiness 未判定。

本项为 Veriflow L1 的有界原样打包，操作命令/退出码/时间与原始输出位于 evidence/local-test1；完整优化计划仍按原 L2 记录继续。新增工件改变全局 revision，旧记录保留历史通过事实并标记 stale，没有借测试包交付降低原性能/迁移门槛。
