# iSCSI 性能优化设计：命令流水线 + 协商参数 + HBA 约束

日期：2026-09-08
状态：已批准（用户确认）

## 1. 背景与根因

重新安装 kext 后，`dd` 测速读写仍卡在 ~155MB/s（写 155.9 / 读 158.1）。排查证据链：

| 检查项 | 结果 | 含义 |
|---|---|---|
| 本地 TCP 窗口 | `rhiwat=524288 / shiwat=525624`（512KB） | SO_RCVBUF **已生效** |
| RTT | `ping` 平均 0.67ms | 窗口上限 ≈ 764MB/s，**窗口不是瓶颈** |
| 实际吞吐 | 155.9 / 158.1 MB/s | 155MB/s × 0.67ms ≈ 104KB 在途 ≈ 一个命令 |
| 并发写（t_1+t_2） | 76.7 + 78.2 ≈ 155MB/s 总量 | 总吞吐不变 → **全局串行化点** |

**根因**：`iSCSITaskQueue` 单任务串行派发，有效队列深度 = 1。任意时刻只有一条 SCSI 命令在途，吞吐被 RTT 锁死。

代码印证：
- [iSCSITaskQueue.cpp](Source/Kernel/iSCSITaskQueue.cpp) `checkForWork()` 一次只派发队列头一个任务后 `return false`。
- `queueTask()` 仅在队列为空时触发派发；`completeCurrentTask()` 才触发下一条。
- 虽然 `ReportMaximumTaskCount()=10`，但从未用满。

次要瓶颈（写路径叠加）：
- `InitialR2T=true`：写数据前强制等 R2T 往返。
- `MaxOutstandingR2T=1`：写 burst 无法并发。

## 2. 优化方案

### 方案 1：命令流水线（核心，读写都受益）

把 taskQueue 从"串行调度器"改为"立即排空"：

- `checkForWork()` 循环派发**所有**排队任务，派发即出队（每条任务发一条 SCSI 命令）。
- `completeCurrentTask()` 退化为 no-op（任务派发时已出队）。

**为什么安全**：
- `cmdSN` 在 `SendPDU()` 已是 `OSIncrementAtomic`，多命令并发天然唯一序号。
- 完成乱序由 SCSI 子系统 `FindTaskForControllerIdentifier` 按 task tag 处理，不依赖队列。
- 队列深度上限仍受 `ReportMaximumTaskCount()=10` 约束。

**改动文件**：`Source/Kernel/iSCSITaskQueue.cpp`（`checkForWork`、`queueTask` 信号逻辑）、必要时 `iSCSITaskQueue.h`。

### 方案 2：InitialR2T = No

- `Source/Kernel/iSCSIRFC3720Defaults.h:42` → `kRFC3720_InitialR2T = false`
- `Source/User/iscsid/iSCSISession.c:136` → `kRFC3720_Value_Yes` 改 `kRFC3720_Value_No`

### 方案 3：MaxOutstandingR2T = 16

- `Source/Kernel/iSCSIRFC3720Defaults.h:111` → `kRFC3720_MaxOutstandingR2T = 16`
- daemon 用共享常量，自动生效，无需额外改。

### 方案 4：override `ReportHBAConstraints`

在 `iSCSIVirtualHBA` 新增 override，显式上报更大的单次 I/O 上限：

- `MaximumSegmentByteCountRead/Write` = 1MB（0x100000，对齐 MaxBurstLength）
- `MaximumSegmentCountRead/Write` = 256
- `MaximumSegmentAddressableBitCount` = 64
- `MinimumSegmentAlignmentByteCount` = 4
- `MinimumHBADataAlignmentMask` = 0

实现时对照基类默认值与实际 key 类型补齐。

## 3. 测试策略

新建 `tests/` 目录，两类：

### ① 可自动测（宿主侧，无需 kext）

- `test_config_defaults.c`：编译期断言共享头新默认值，防回归。
- `test_task_tag.c`：task tag 编解码纯逻辑。
- `test_pdu_fields.c`：PDU BHS 字段计算纯逻辑（视可提取程度）。

### ② 手动流程文档（需 kext + target）

- `tests/manual/perf_write.md`、`perf_read.md`：单流 + 并发 dd 测速流程。
- `tests/manual/stability_concurrent.md`：并发稳定性、无 panic 判据。
- `tests/manual/negotiation_verify.md`：`iscsictl list target` 验证协商参数。

## 4. 实施顺序

1. 低风险方案 2+3+4（配置 + 约束），重编译验证协商参数生效。
2. 核心方案 1（流水线），单独重测稳定性 + 性能。
3. 每步配测试，手动流程文档同步写。

## 5. 风险与缓解

- **use-after-free 前科**（见 PROJECT-CONTEXT 问题 1/7）：保留全部现有 NULL 校验；方案 1 完成后重点做并发稳定性测试。
- **并发竞态**：taskQueue 的 `queue_enter`/`queue_remove` 无锁，需确认 `ProcessParallelTask`（SCSI 线程）与 `checkForWork`（workloop）的线程关系，必要时用 workloop 的 command gate 序列化。
- **协商参数是否被 target 接受**：InitialR2T=No 依赖 Synology 支持（一般支持），用 `iscsictl list target` 验证。
