# 审查修复基准与设计

Spec：task-state.json（REVIEW-FIX-SPEC-1）。源码基线保存在 evidence/baseline-source，哈希见 evidence/baseline-manifest.json。

## 固定用例

- F1：两个 StudioModel 共享 registry/repository；B 将唯一初始临时空间命名并保存；从 A 归档 B。断言 B 的活动空间有效且能新建资源、A 的活动空间不变、被归档运行时关闭且磁盘归档标记为 true。
- F1 边界：B 还有其他空间时切换到剩余空间；保存失败保持原空间；窗口整体关闭与应用退出不产生替代空间。不能通过在每次 activeSession=nil 时无条件创建空间实现。
- F2：保存未加载空间，用可控 continuation 延迟 loader；分别点击新网页/新终端，释放 loader 后恰好创建一个资源。加载失败、表单阻止、切换到其他空间时不得误建；既有其他窗口持有的目标仅定位且不创建。
- F3：隔离根中放置正常、损坏、未来 schema 三种配置。有效空间仍出现，另外两种错误分别显示UUID/原因与文件定位入口；原文件哈希不变。修复夹具后重扫，诊断消失且可用空间进入目录。扫描中重试应防重，不能覆盖现有 live session 的草稿或配置。

## 验证层次

1. coder 先补测试，仅运行测试基准，主线程审查原始日志后放行产品实现。模型断言不能代替 F3 界面可见性；现有 registry.diagnostics 已可能通过。
2. 产品修复后复跑完全相同的基准，加受影响 Workspace*、AgentController、ResourceRead 回归。测试应用使用隔离根与provider配置。
3. 主线程执行区分性检查并用原生UI走查三个场景；记录实际应用路径/二进制哈希、配置根、AX/截图和结果。不得对用户原应用或真实配置做测试。
4. 原生运行失败单独记 undetermined，不能用编译或测试源码存在代替。

## 责任

WindowCoordinator拥有窗口内有效活动空间及关闭状态；Registry拥有共享目录、配置加载及扫描诊断；StudioModel编排用户意图和异步资源创建；SwiftUI层呈现诊断与操作。配置文件格式、ResourceStore与终端后端保持原契约。

主线程维护Spec/记录/UX文档；coder串行修改产品及测试，完成后由主线程审查。修复基于已有未提交实现增量完成，不重置工作区。
