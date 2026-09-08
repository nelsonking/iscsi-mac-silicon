# iSCSI 项目完整上下文（整次对话记录）

## 项目背景

把废弃的 `iscsi-osx/iSCSIInitiator` 移植到 Apple Silicon 的原生 iSCSI initiator：

- **架构**：内核态 kext（`iSCSIVirtualHBA`，继承 `IOSCSIParallelInterfaceController`，BSD kernel socket 直接收发 iSCSI PDU）+ 用户态 `iscsid` 守护进程 + SwiftUI 菜单栏 App。
- **数据路径全在内核态**：SCSI task 经 `ProcessParallelTask → iSCSITaskQueue → BeginTaskOnWorkloopThread → SendPDU`（写）/ `RecvPDUHeader → ProcessDataIn → CompleteParallelTask`（读）。用户态只管会话生命周期/登录协商，不碰数据。
- **线程模型**：HBA 一个 IOWorkLoop，`taskQueue` 和 `dataRecvEventSource` 挂其上，数据路径全在 workloop 线程。`HandleTimeout` 在 SCSI 栈定时器线程（已序列化，见下）。
- **构建**：仅 Command Line Tools，`./build_all.sh` = `build_kext.sh`（arm64e）+ `build_user.sh`。加载用 `kmutil`，需关 SIP + Reduced Security。
- **用户环境**：纯局域网，2.5G 网卡，Synology target（M.2 SSD），双 target（istore + office），无 CHAP。

## 本次对话的问题线（按时间顺序）

### 1. 内核 panic（Spotlight 索引触发）—— 已修复

- **现象**：登录 iSCSI target 后，Spotlight（mdworker_shared）自动索引卷触发 panic，整机重启。
- **崩溃点**：`BeginTaskOnWorkloopThread`（`iSCSIVirtualHBA.cpp:680`，`brk #1`，lr 落在 udf 填充区 = 返回地址损坏）。
- **根因**：`HandleTimeout` 在 SCSI 栈定时器线程直接操作 taskQueue/`CompleteParallelTask`，与 workloop 数据路径竞态 → use-after-free → 栈污染。
- **修复**（已做，保留）：
  - `P1-1`：`HandleTimeout` 整体序列化到 workloop（`GetCommandGate()->runAction()`），新增 `HandleTimeoutGated`/`HandleTimeoutAction`。
  - `P0-1`/`P0-2`：`BeginTaskOnWorkloopThread`、`iSCSITaskQueue::checkForWork` action 调用前加 NULL 校验。
  - `B1`：`ReportHBASpecificTaskDataSize` 返回 1→4 字节（原来 HBAData 只 1 字节却按 UInt32 读写，3 字节溢出），`ProcessParallelTask`/`HandleTimeout` 改用 `memcpy` 读写 `connection->cid`。
  - `B2`：删掉 `ProcessParallelTask` 里 `connection = session->connections[0]`（负载均衡循环被覆盖）。
  - `E4`：`memset(bytesPerSecondHistory)` 参数纠正；`E5`：`HandleConnectionTimeout` 循环变量遮蔽；`E8`：`2e24` 改 `(1<<24)-1`。

### 2. App 功能补全 —— 已做

- **断线重连**：`doConnect` 里加 `iscsictl modify target-config -auto-login enable -persistent enable`，交给 daemon 的 persistent 机制（不用 App 自己轮询）。
- **失败原因展示**：`MenuBarContent.subtitle` 对 `.failed` 显示具体错误（原只显示"错误"）。
- **读写累计展示**：`IOKitDiskFinder.readWriteCounts` 读 IORegistry `AppleSCSISubsystemGlobals` 的 `Device Stats`（`ReadBlockCount`/`WriteBlockCount` × 512），详情页显示"读 X · 写 Y"。**注意 Device Stats 的 key 是 `SCSI Target Identifier + 1` 的十六进制（`%016llx`），不能遍历取第一个**（多 target 会取错）。

### 3. App 状态/显示 bug —— 已修

- **连接后显示未连接**：`refreshRuntime` 里 probe 返回 nil 时误清状态。修复：probe 重试 + 用 `rr.isMounted` 而非 `rr.bsdDisk` 判断是否真掉线；`doConnect` 回传 disk、`connect` 填 `bsdDisk`。
- **速度不显示**：`IOKitDiskFinder.bsdNameKey` 写成了 `"BSD name"`（小写 n），IORegistry 实际是 `"BSD Name"`（大写 N）→ 读不到 BSD name → findDisk 返回 nil → 状态到不了 `.mounted`。
- **定时器前台化**：状态刷新/速率采样只在主窗口可见时运行（`startPeriodicRefresh`/`stopPeriodicRefresh`，用 `refreshUsers` 引用计数管理主窗口+菜单栏）。
- **菜单栏简化**：移除"断开"按钮（危险），挂载时显示实时速率 `MB/s`。

### 4. 速率显示 bug —— 已修

- **最初用 Device Stats 差值算速率**，出现两个问题：① 大数（`readWriteCounts` 遍历取第一个 entry，多 target 时 NSDictionary 无序取错）；② 恒 0（Device Stats 的计数不是实时的，不适合 1 秒粒度的速率）。
- **最终方案：改用 `iostat` 采样**（和详情页 `DiskMonitor` 一致）。`ISCSIController` 加 `rates: [UUID: Double]` + `rateTimer`（1.4s），`sampleRates` 对每个 mounted target 跑 `iostat -d -w 1 -c 2 <disk>`，`DiskMonitor.parseMBs` 解析 MB/s。Device Stats 只用于累计读写（不用于速率）。

### 5. 性能优化 —— 部分保留

- **目标**：2.5G 网卡跑满（~280MB/s）。测试发现 iSCSI 读写只有 ~155-165MB/s，而 SMB 能到 240MB/s。
- **做的 4 项优化**：
  1. **PDU 数据段调大**：`iSCSIRFC3720Defaults.h` 的 `MaxRecvDataSegmentLength` 8192→262144、`MaxBurstLength` 262144→1048576、`FirstBurstLength` 65536→262144。共享头，内核+daemon 都生效。**保留**。
  2. **recvBuffer 预分配**：`iSCSIConnection` 加 `recvBuffer`，`ProcessDataIn` 复用。**已移除**（引入 use-after-free panic，见问题 7）。
  3. **socket 缓冲区**：`SO_SNDBUF`/`SO_RCVBUF` 512KB。**关键：必须在 `sock_connect` 之前设置**（否则 TCP 窗口缩放不生效，卡在默认 128KB 窗口 ≈ 155MB/s）。**保留**。
  4. **TCP_NODELAY**：禁用 Nagle。**保留**。
- **热路径日志移除**：`SendPDU`/`RecvPDUHeader` 的无条件 `IOLog("ISCSIX:...")` 改成 `DBLog`（正式构建不打印）。原来源头是性能下降主因（每 PDU 一次 IOLog，2.5G 下每秒 ~4 万次带锁日志）。**保留**。

### 6. 用户态崩溃 —— 已修

排查 `iscsictl list target-config` 崩溃时发现多个预先存在的 bug：
- **iscsid use-after-free**：`iSCSIDProcessQueuedLogin`（SCNetworkReachability 回调）free 后没取消回调 → 二次触发 use-after-free。修复：free 前 `SCNetworkReachabilitySetCallback(NULL)`。
- **iscsictl over-release**：`iSCSICtlParseSwitchesToDictionary` 对 `CFArrayGetValueAtIndex` 的 borrowed 引用调 `CFRelease` → 参数字符串提前释放、内存复用。修复：删除这两个 `CFRelease`。
- **CHAPName NULL**：`iSCSIPreferencesCopyTargetCHAPName` 对无 CHAP 的 target 返回 `CFStringCreateCopy(NULL)` 崩溃。修复：加 `if(!name) return NULL;` + 调用方处理。
- **`iSCSICtlListTarget` 的 `:1766`**：`properties = iSCSIDaemonCreateCFPropertiesForConnection(...)` 漏了赋值，导致 portal 级参数（MaxRecvDataSegmentLength 等）不显示。修复：补 `properties =`。

### 7. recvBuffer use-after-free panic —— 已修（最近）

- **现象**：安装新 kext 后整机死机，panic `element modified after free (sz:32)`（mDNSResponder，栈回溯无 kext 帧）。
- **根因**：问题 5 的第 2 项优化（recvBuffer 预分配）让 `ProcessDataIn` 复用 `connection->recvBuffer`，buffer 生命周期绑定到 connection；而 `ReleaseConnection` 在非 workloop 线程（用户态 logout IPC）释放 recvBuffer，与 workloop 上的 `ProcessDataIn` 并发 → use-after-free。
- **修复**：移除 recvBuffer 预分配，恢复 `ProcessDataIn` 每-PDU `IOMalloc`。可接受（第 1 项 PDU 调大已把分配频率从 ~4 万/秒降到 ~1200/秒）。
- **详细分析**：见 `docs/kernel-panic-use-after-free.md`。

## 当前代码状态（最终）

### 保留（勿还原）
- 问题 1 的全部 panic 修复（P0/P1/B1/B2/E4/E5/E8）。
- 问题 2 的 App 功能（断线重连/lastError/读写累计）。
- 问题 3/4 的 App 状态与速率修复（iostat 采样、BSD Name、定时器前台化等）。
- 问题 5 的：PDU 调大、socket 参数（SO_RCVBUF **connect 前**）、TCP_NODELAY、热路径日志 DBLog 化。
- 问题 6 的 daemon/iscsictl 崩溃修复。

### 已移除
- recvBuffer 预分配（问题 5 第 2 项，use-after-free）。

## 后续工作（未做）

1. **control path 同步（use-after-free 的深层根源）**：`DeactivateConnection`/`ReleaseConnection` 从用户态 logout（非 workloop）调用时，与 workloop 数据路径竞态。recvBuffer 只是让它更容易触发。要根除需把这两个函数也序列化到 workloop（类似 `HandleTimeout` 的 runAction）。这是下次要做的核心。
2. **性能验证**：SO_RCVBUF 位置修复（connect 前）后，重新编译安装测速，看读写能否从 ~160MB/s 提升到接近 SMB 的 240MB/s。若还慢，需抓包确认实际 PDU 大小（tcpdump，sudo 需密码）。
3. **移除残留的 inactive target**：`iscsictl remove target <iqn>`（注意带 `target` 子命令），清理 Synology 上 Target-2/Target-11/default-target 等残留。

## 关键文件清单

| 文件 | 作用 / 关键改动 |
|---|---|
| `Source/Kernel/iSCSIVirtualHBA.cpp` | 核心。HandleTimeout 序列化、HBAData 修复、socket 参数（connect 前）、热路径 DBLog、PDU 数据路径 |
| `Source/Kernel/iSCSITypesKernel.h` | `iSCSISession`/`iSCSIConnection` 结构体 |
| `Source/Kernel/iSCSIRFC3720Defaults.h` | PDU 数据段/burst 默认值（已调大，共享头） |
| `Source/Kernel/iSCSITaskQueue.cpp` | 队列 + action 分发（NULL 校验） |
| `Source/User/iscsid/iSCSIDaemon.c` | daemon（use-after-free 修复） |
| `Source/User/iscsictl/iSCSICtl.m` | CLI（over-release、CHAPName、:1766 修复） |
| `Source/User/iSCSI Framework/iSCSIPreferences.c` | 偏好（CHAPName NULL 修复） |
| `App/Sources/ISCSIController.swift` | 连接/状态/速率采样（iostat rates） |
| `App/Sources/IOKitDiskFinder.swift` | findDisk（BSD Name 大写）、readWriteCounts（Device Stats 精确匹配） |
| `App/Sources/MenuBarContent.swift` | 菜单栏（速率显示、移除断开） |

## 调试经验/坑（重要）

- **`findDisk` 的 BSD name 属性是 `"BSD Name"`（大写 N）**，不是 `"BSD name"`。
- **Device Stats 的 key = `SCSI Target Identifier + 1` 的 `%016llx`**，遍历取第一个会因 NSDictionary 无序取错。
- **Device Stats 计数不是实时的**，不能用来算 1 秒粒度的速率，实时速率用 `iostat`。
- **SO_RCVBUF 必须在 `sock_connect` 之前设置**，否则 TCP 窗口缩放不生效。
- **热路径不能有 `IOLog`**（每 PDU 一次会拖垮吞吐）。
- **recvBuffer 预分配引入 use-after-free**，因为 buffer 生命周期绑定 connection，而 connection 可能被非 workloop 线程释放。
- **`iscsictl remove` 要带 `target` 子命令**：`iscsictl remove target <iqn>`。
- **macOS 默认 TCP `recvspace` 128KB**（`sysctl net.inet.tcp.recvspace`），不调大窗口的话吞吐卡在 ~155MB/s（0.8ms RTT）。
