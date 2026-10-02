# 2B 当前实际源码仍存在的待修复项

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

主线程审查 2026-09-17；下列均需实际代码/反例证明，parse不能证明完成。core coder独占Registry/Coordinator/SaveController及ClosePreparationTests。

1. Registry.closeAll 重复请求分支仍 `await task.value; return true`，必须返回实际Bool。函数结尾也应返回task实际结果，不以isClosingAll推断。unowned close的Task应覆盖prepare到cleanup，避免并发prepare两次。
2. window/application批量保存后尚无已通过项配置复核：A保存完成后，等待B时A发生提交配置变更，A不可被直接停止观察后清理。复核所有非discard配置与最后savedConfiguration，必要时再prepare；全批可取消。收集全部sessions，之后同步停止所有controller，再做第一个cleanup await。window批量当前仅逐个cleanup时stop。
3. closeSummary仍读取当前问题run.state，必须用isRequesting，包含后台题和取消尚未清理的任务。
4. loaded archive目前先controller.saveNow再普通close(id)，中间没锁且重新走prepare。归档与关闭应是一项事务：准备前封锁coordinator，更新archived后通过同一controller保存，成功后直接cleanup；失败回滚内存flag并保留会话。临时空间先命名才可归档；无落盘配置不能伪造归档成功。
5. 恢复初始空间在调用前已有草稿/新问题/资源时不应自动替换；仍可扫描目录。现有比较只防await期间变更，不防restore函数开始前已有用户工作。
6. 单空间close→显示下一空间应记录真实activation；window/app批量cleanup不能记录内部fallback的activation。当前cleanup一律false，还缺单关闭区分。
7. concurrent close不同ID/closeAll需避免重复prepare/cleanup与过早解除isClosing。清理任务字典不能把包含prepare的外层task覆盖为内层task后提前nil；取消回执需共享。

已通过的151项checkpoint不覆盖以上2B新功能。完成后回报逐项处理和对应测试名，保留所有失败输出。
