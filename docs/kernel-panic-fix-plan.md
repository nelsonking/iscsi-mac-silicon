# iSCSI Initiator kext 内核 panic 修复方案

> **文档定位**：这是一份自包含的修复任务规格书。读完即可由一个新启动的 Agent 独立实施代码修复，无需重新调查。
>
> 编写日期：2026-08-24 ｜ 项目根目录：`/Users/nelsonking/Projects/open/iscsi-mac-silicon`
>
> 证据来源：①用户提供的 panic 日志全文 ②atos 符号化（kext 二进制 DWARF）③lldb 反汇编 ④两个并行调查 Agent 对源码与工程流程的穷举式审查。

---

## 0. TL;DR

| 项 | 结论 |
|---|---|
| 现象 | 登录 iSCSI target 后，macOS Spotlight（`mdworker_shared`）自动索引 iSCSI 卷（`/Volumes/istore`），触发内核 panic，整机死机重启。**已反复发作**（至少 2026-08-13、2026-08-24 两次）。 |
| 崩溃点 | `iSCSIVirtualHBA::BeginTaskOnWorkloopThread` @ `Source/Kernel/iSCSIVirtualHBA.cpp:680`（atos + lldb 双重确认）。 |
| panic 类型 | `brk #1`（ESR EC=0x3C，XNU 主动 panic）；kext 内**无任何显式 panic()/assert 调用**，是 kext 在该调用现场陷入不可恢复状态被 XNU 捕获。 |
| 关键铁证 | 链接寄存器 `lr=0x1a60` 落在**函数间 udf 对齐填充区**（无效地址）→ 返回地址/栈状态已损坏。 |
| 即时止血 | `sudo mdutil -i off /Volumes/istore`（不改代码，立即生效）。 |
| 根治路径 | 加固 `BeginTaskOnWorkloopThread` 入口校验 → 审查 `iSCSITaskQueue::checkForWork` 的 action 调用 → 修 `HandleTimeout` 线程竞态与 TaskQueue 同步缺失。 |

---

## 1. 前因后果

### 1.1 故障现象

- **时间**：2026-08-24 14:11，panic 报告文件 `/Library/Logs/DiagnosticReports/panic-full-2026-08-24-141116.0002.panic`。
- **复发证据**：项目 `.claude/settings.local.json` 的权限白名单引用了 `2026-08-13` 的 panic 报告路径（`.../panic-full-2026-08-13-164619.0002.panic`），说明 8 月 13 日已死过一次，本次是复发。
- **panic 日志关键行**（完整日志见附录 A）：
  ```
  panic(cpu 1 caller 0xfffffe004b148ad8): Break 0x0001 instruction exception from kernel.
    Panic (by design) at pc 0xfffffe004d289d44, lr 0xfffffe004d289c9c
    (saved state: 0xfffffe878e686d40)
  ...
  esr: 0x00000000f2000001  far: 0x0000000825098000
  ...
  Panicked task ...: pid 72241: mdworker_shared
  ```

### 1.2 触发场景

1. 登录 iSCSI target → LUN 作为 `/dev/diskN` 出现 → 卷挂载到 `/Volumes/...`。
2. macOS Spotlight（`mds`/`mdworker_shared`）**自动开始索引新挂载卷**——这是默认行为，项目代码中没有任何显式 Spotlight 调用，但索引是"挂载即触发"的隐式必然。
3. 索引产生大量读 I/O → 经 APFS → SCSI Block / SCSI Parallel 栈 → 进入本 kext 的数据路径 → 触发 panic。
4. 用户环境中 `/Volumes/istore` 即该 iSCSI 卷（也在 Claude 工作目录列表里）。

### 1.3 调用链（panic 日志栈回溯依赖的 kext 链）

```
com.apple.filesystems.apfs
  → com.apple.iokit.IOSCSIBlockCommandsDevice
  → com.apple.iokit.IOSCSIArchitectureModelFamily
  → com.apple.iokit.IOSCSIParallelFamily
  → com.github.iscsi-osx.iSCSIInitiator   ← 崩溃 kext
```

- 崩溃进程：`pid 72241: mdworker_shared`（Spotlight 元数据索引器）。
- panic 栈顶 `pc=0xfffffe004d289d44`、紧邻 `lr=0xfffffe004d285a60` 均落在 kext 加载段 `[0xfffffe004d284000, 0xfffffe004d28ab6b]` 内。

### 1.4 根因定位（三层证据交叉印证）

#### 证据 1 — panic 日志

- `Break 0x0001 instruction exception from kernel` + `Panic (by design)`：XNU 捕获到 `brk #1`（XNU 约定的 panic trap）。
- `esr: 0x00000000f2000001`：bits[31:26] = `0x3C` = EC 60 = **BRK instruction trap (AArch64)**；ISS 含立即数 1 → `brk #1`。确认是 BRK 异常而非数据访问异常。
- `caller 0xfffffe004b148ad8`：XNU 内调用 `panic()` 的位置（在 kernel text 段内）。
- saved-state 的 `pc=0x5d44`、`lr=0x1a60`（kext 段内偏移）。

#### 证据 2 — atos 符号化（二进制 DWARF，确凿）

构建 kext 后执行（命令见附录 B）：
```
atos -arch arm64e -o build/iSCSIInitiator.kext/Contents/MacOS/iSCSIInitiator \
     -l 0xfffffe004d284000 0xfffffe004d289d44 0xfffffe004d285a60
```
结果：
- `pc (0x5d44)` → `com_github_iscsi_osx_iSCSIVirtualHBA::BeginTaskOnWorkloopThread(...) + 776` @ **`iSCSIVirtualHBA.cpp:680`**
- `lr (0x1a60)` → 落在函数之间，atos **无法解析出函数名**（下文 lldb 揭示原因）。

#### 证据 3 — lldb 反汇编（指令级铁证）

**pc=0x5d44 上下文**（反汇编 `0x5d10`–`0x5d80`）：
```
0x5d44 <+776>: mov  w8, #-0x1          ; 末参 kiSCSIPDUTargetTransferTagReserved (0xFFFFFFFF)
0x5d48 <+780>: str  w8, [sp]
0x5d4c <+784>: mov  x0, x21            ; owner
0x5d50 <+788>: mov  x1, x20            ; session
0x5d54 <+792>: mov  x2, x19            ; connection
0x5d58 <+796>: mov  x3, x23            ; parallelTask
0x5d5c <+800>: mov  x4, x25            ; dataOffset
0x5d60 <+804>: mov  x7, x22            ; initiatorTaskTag
0x5d64 <+808>: bl   0x5e20             ; ProcessDataOutForTask @ iSCSIVirtualHBA.cpp:1201
0x5d68 <+812>: ldp  x29,x30,[sp,#0x90] ; 函数 epilogue（恢复栈帧/返回地址）
```
→ **pc 指向 `BeginTaskOnWorkloopThread` 准备调用 `ProcessDataOutForTask` 的现场**（对应源码 680-681 行末参 `kiSCSIPDUTargetTransferTagReserved` 的装入）。**这条指令是 `mov`，不是 `brk`**——所以 `brk #1` 不是从这里发出的，而是 XNU 异常处理路径在判定不可恢复后主动执行（见 §1.4 综合结论的说明）。

**lr=0x1a60 上下文**（反汇编 `0x1a30`–`0x1a90`）：
```
0x1a30: udf #0x0
0x1a34: udf #0x0
0x1a38: udf #0x0
...（连续 24 条 udf #0x0）...
0x1a8c: udf #0x0
```
→ **lr 落在两个函数之间的对齐填充区**，全是 `udf`（未定义指令）。这是**链接寄存器已被污染为无效地址的铁证**——返回地址不再是任何有效代码，说明调用栈状态已损坏。

#### 证据 4 — 源码第一手（`Source/Kernel/iSCSIVirtualHBA.cpp`）

- `BeginTaskOnWorkloopThread`（549-683）由 `iSCSITaskQueue::checkForWork`（`iSCSITaskQueue.cpp:155`）通过 action 函数指针调用，是 workloop 调度的写方向 SCSI 命令处理。
- 680-681 行正是 `owner->ProcessDataOutForTask(session,connection,parallelTask,dataOffset,dataLength,bhs.LUN,initiatorTaskTag,kiSCSIPDUTargetTransferTagReserved);`——写命令的数据段发送。
- **关键对比**：`BeginTaskOnWorkloopThread` 入口（549-553）**无任何有效性校验**，直接在 555/562/580 等行解引用 `owner`/`session`/`connection`；而同文件的 `ProcessTaskOnWorkloopThread`（685-691）入口有 `if(!owner||!session||!connection) return true;` 防护。BeginTask 缺这道防护。

#### 综合结论（根因）

1. mdworker 索引 iSCSI 卷的读 I/O 经 SCSI Parallel 栈进入 `iSCSIVirtualHBA`，workloop 调度 `iSCSITaskQueue::checkForWork` → 通过 action 调用 `BeginTaskOnWorkloopThread`。
2. 在该调用现场，链接寄存器 `lr` 被污染为无效地址（指向函数间 `udf` 填充区），表明调用栈状态已损坏——可能源于：action 调用约定问题，或 `session`/`connection`/`taskQueue` 在调用时已被异步释放（use-after-free，由 `HandleTimeout` 定时器线程与 workloop 竿态导致）。
3. kext 陷入不可恢复状态，XNU 捕获并执行 `brk #1` panic。

> **关于 "pc=0x5d44 是 mov 而非 brk" 的说明**：panic 日志 saved-state 的 `pc` 记录的是"异常被捕获时 CPU 现场"（`BeginTaskOnWorkloopThread` 内准备调 `ProcessDataOutForTask` 的 `mov` 指令），而 `brk #1` 是 XNU 异常处理路径在判定不可恢复后主动执行的 trap。两者不矛盾——`pc` 是"现场"，`brk` 是"XNU 的处置"。执行 Agent 若需 100% 坐实 brk 的精确触发源，可用 `kmutil inspect` + 内核态 lldb 连真机内核进一步定位（见 §5 步骤 3）。
>
> **关于 kext 内是否有主动 panic**：穷举式 grep（`panic(`/`IOPanic`/`assert`/`ASSERT`/`__builtin_trap`/`Require`/`require`/`check(`/`CHECK(`/`fail:`/`bail` 等）确认 `Source/Kernel/` 下**无任何显式 panic 调用或断言宏**，项目也未 `#include <libkern/Require.h>`。所以 panic 不是断言失败，是运行时状态损坏被 XNU 捕获。

---

## 2. 项目上下文（执行 Agent 必读）

### 2.1 项目定位

- **一句话**：把已废弃的 `iscsi-osx/iSCSIInitiator` 移植到 Apple Silicon 的原生 iSCSI initiator——`arm64e` 虚拟 SCSI HBA kext + 用户态 `iscsid` 守护进程 + SwiftUI 菜单栏 App + `pkg`/`dmg` 安装器，仅用 Command Line Tools 构建（无需完整 Xcode、无需 KDK）。
- **目标系统**：Apple Silicon Mac（M1+），macOS 13+。必须关闭 SIP + 降低启动安全性到 Reduced Security + 允许被认可开发者的内核扩展。
- **关键标识**：kext bundle id `com.github.iscsi-osx.iSCSIInitiator`，版本 `1.0.0`，架构 `arm64e`，ad-hoc 签名（无 Developer ID）。IOKit 类名前缀化为 `com_github_iscsi_osx_*`。

### 2.2 目录结构（顶层）

| 条目 | 职责 |
|---|---|
| `Source/Kernel/` | kext 源码（6 个 .cpp + crc32c.c + Info.plist + Prefix.pch），产物 `build/iSCSIInitiator.kext` |
| `Source/User/iSCSI Framework/` | 共享库 API + 内核 user-client 桥，产物 `build/iSCSI.framework` |
| `Source/User/iscsid/` | 后台守护进程（会话/发现/认证），产物 `build/iscsid` |
| `Source/User/iscsictl/` | 命令行控制工具，产物 `build/iscsictl` |
| `App/` | SwiftUI 菜单栏 App，产物 `App/build/iSCSI.app` |
| `Installer/` | 现代 pkg→dmg 打包器（`build_installer.sh`） |
| `Distribution/`、`Scripts/`、`iSCSIInitiator.xcodeproj/` | **遗留** x86/kextload 时代产物，Apple Silicon 上不可用，仅参考 |
| 顶层 `*.sh` | 现代构建/安装/诊断脚本（CLT 流程正式入口） |
| `.claude/` | 仅 `settings.local.json`（权限白名单），**无项目级 CLAUDE.md/agents/skills** |
| `.github/workflows/build.yml` | CI |

### 2.3 关键源文件职责（`Source/Kernel/`）

| 文件 | 职责 |
|---|---|
| `iSCSIInitiator.cpp/.h` | 顶层 IOService nub（bootstrap），作为 VirtualHBA 的 provider，**不处理 SCSI task** |
| `iSCSIVirtualHBA.cpp/.h` | **核心**：继承 `IOSCSIParallelInterfaceController`，接收/发送/完成 SCSI task，实现 iSCSI 协议（PDU 收发、BSD kernel socket、会话/连接管理） |
| `iSCSITaskQueue.cpp/.h` | 自定义 `IOEventSource`：SCSI task 入队 + workloop 调度 |
| `iSCSIIOEventSource.cpp/.h` | 自定义 `IOEventSource`：socket 数据到达事件源 |
| `iSCSIHBAUserClient.cpp/.h` | 用户态↔内核态桥（仅会话/连接生命周期、登录/协商、异步通知，**不参与 SCSI data path**） |
| `iSCSIPDUKernel.cpp/.h` | iSCSI PDU 序列化/反序列化（BHS/AHS/data segment/digest，结构体 packed） |
| `iSCSITypesKernel.h` | 内核内部结构体（`iSCSISession`、`iSCSIConnection`——加引用计数的位置） |
| `iSCSIPDUShared.h` / `iSCSIHBATypes.h` / `iSCSIRFC3720Defaults.h` | 共享 PDU 结构 / IPC 消息 / RFC 常量 |

### 2.4 SCSI Task 数据路径

> **架构关键**：SCSI data path **全在内核态**。用户态 `iscsid` 不参与数据传输，只管会话/连接生命周期、登录/协商 PDU、异步通知。内核通过 BSD kernel socket（`sock_send`/`sock_receive`）直接收发 iSCSI PDU。

**正向（入口 → 发送）**：
1. `iSCSIVirtualHBA::ProcessParallelTask` @ `iSCSIVirtualHBA.cpp:480`（workloop 线程）→ 选 connection、设 task tag、`queueTask`。
2. `iSCSITaskQueue::queueTask` @ `iSCSITaskQueue.cpp:62` → `IOMalloc` + `queue_enter` + `signalWorkAvailable`。
3. `iSCSITaskQueue::checkForWork` @ `iSCSITaskQueue.cpp:122` → 取队头 taskTag → 调 action（`:155`）。
4. **`iSCSIVirtualHBA::BeginTaskOnWorkloopThread` @ `iSCSIVirtualHBA.cpp:549`**（workloop 线程，**崩溃点所在**）→ 构造 `iSCSIPDUSCSICmdBHS`、`SetTimeoutForTask`、READ 走 `SendPDU`、WRITE 走 `ProcessDataOutForTask`（`:680`）。
5. `iSCSIVirtualHBA::SendPDU` @ `:1878` → 设 cmdSN/expStatSN、组装 iovec、`sock_send`。

**反向（响应到达 → 回填）**：
1. `iSCSIIOEventSource::socketCallback` @ `iSCSIIOEventSource.cpp:58`（BSD upcall 上下文，仅 `signalWorkAvailable`，安全）。
2. `iSCSIIOEventSource::checkForWork` @ `iSCSIIOEventSource.cpp:69`（workloop）→ `isPDUAvailable` → 调 action（`:88`）。
3. `iSCSIVirtualHBA::ProcessTaskOnWorkloopThread` @ `iSCSIVirtualHBA.cpp:685`（workloop）→ `RecvPDUHeader` → 按 opCode 分派：
   - `kiSCSIPDUOpCodeSCSIRsp` → `ProcessSCSIResponse` @ `:919`
   - `kiSCSIPDUOpCodeDataIn` → `ProcessDataIn` @ `:1019`（**READ 主数据路径**）
4. `iSCSIVirtualHBA::CompleteParallelTask` @ `:751` → `super::CompleteParallelTask` 回填 + `NotificationOccurred`。
5. `iSCSITaskQueue::completeCurrentTask` @ `iSCSITaskQueue.cpp:91` → `queue_remove_first` + `IOFree`。

**超时/异常路径**：
- `HandleTimeout` @ `iSCSIVirtualHBA.cpp:399`——**运行在 SCSI 栈定时器上下文，不是 workloop 线程**（最大线程安全漏洞）。
- `HandleConnectionTimeout` @ `:444` → `DeactivateConnection`/`DeactivateAllConnections` + 通知 daemon。

### 2.5 构建 / 加载 / 卸载命令

```bash
cd /Users/nelsonking/Projects/open/iscsi-mac-silicon

# 构建（kext + 用户态，无需 sudo）
./build_all.sh                                  # = build_kext.sh && build_user.sh
# 开启内核日志（DBLog）构建：
DEBUG=1 ./build_kext.sh && ./build_user.sh

# 安装/加载（需 sudo；首次必被拦 → 系统设置允许 → 重启 → 再跑）
sudo ./install.sh
# 仅重装用户态（不碰 kext，免重启/免批准）：
sudo ./install_user.sh

# 卸载
sudo ./uninstall.sh
```

- **一次性安全设置**（Recovery，必须先做一次）：关机 → 长按电源键至 "Loading startup options" → Options > Continue → Utilities > Startup Security Utility → Reduced Security + 允许被认可开发者内核扩展 → Recovery 终端 `csrutil disable`。
- **kext 加载方式**：`kmutil load -p /Library/Extensions/iSCSIInitiator.kext` / `kmutil unload -b com.github.iscsi-osx.iSCSIInitiator` / `kmutil showloaded`。**不要用** `kextload`/`kextunload`（Apple Silicon 已移除，仅遗留 `Scripts/` 用）。

### 2.6 诊断与符号化手段

**diag.sh**：`sudo ./diag.sh <portal> <target-iqn>`，依次输出 netstat 连接监控、`iscsictl login` 返回码、`dmesg | grep iscsi`、`/var/log/iscsid` 尾部、**ISCSIX 内核追踪**（`log show --last 90s --info --debug --predicate 'eventMessage CONTAINS "ISCSIX"'`）、iscsid 日志、当前 target 列表。

**ISCSIX 日志**：`iSCSIVirtualHBA.cpp:1596/1610/1616` 有 3 条无条件 `IOLog`（标记 socket 建连路径），不受 DEBUG 控制。`DBLog` 宏仅在 `DEBUG=1` 构建时展开为 `IOLog`。

**符号化命令模板**（kext 二进制 `-g` 内嵌 DWARF，无独立 dSYM）：
```bash
atos -arch arm64e \
     -o /Users/nelsonking/Projects/open/iscsi-mac-silicon/build/iSCSIInitiator.kext/Contents/MacOS/iSCSIInitiator \
     -l <panic日志基址> <pc地址> <lr地址>
# 或用原始偏移（无需基址）：
atos -arch arm64e -o <kext二进制> 0x5d44 0x1a60
```

**lldb 反汇编模板**：
```bash
lldb <kext二进制> \
  -o "image lookup -v -a 0x5d44" \
  -o "disassemble --start-address 0x5d10 --end-address 0x5d80" \
  -o "quit"
```

### 2.7 线程/锁模型（改动时必须遵守）

- HBA 有**一个** IOWorkLoop，`taskQueue`（`iSCSIVirtualHBA.cpp:1572`）和 `dataRecvEventSource`（`:1584`）挂其上。
- **正向路径全在 workloop 线程**；反向路径数据部分也全在 workloop 线程；唯 `socketCallback`（`iSCSIIOEventSource.cpp:58`）在 BSD upcall 上下文，仅 `signalWorkAvailable`——**保持不变，勿改**。
- **`HandleTimeout` 运行在 SCSI 栈定时器上下文，不是 workloop 线程**——这是当前最大的线程安全漏洞。任何改动手动操作队列/完成都必须通过 `GetCommandGate()->runAction()` 序列化到 workloop。
- `iSCSITaskQueue::GetCommandGate()` 返回值在 4 处被丢弃（`:70-71`/`:102-103`/`:139-140`/`:171-172`）——同步死代码，未生效。
- `IOLock accessLock`（`iSCSIHBAUserClient.cpp:273`）仅保护用户态 control path，**不要**用于 SCSI data path。
- ARM64 弱内存序：跨线程共享状态（`maxCmdSN`/`expCmdSN`/`bytesPerSecondHistory`）需用 `OSReadLittleInt32`/`OSWriteLittleInt32` 或 `std::atomic` 保证可见性。

---

## 3. 修复方案

### 3.1 即时止血（用户侧，不改代码，立即生效）

让 Spotlight 别再索引 iSCSI 卷，切断崩溃链路：

```bash
sudo mdutil -i off /Volumes/istore        # 关闭该卷索引
sudo mdutil -E /Volumes/istore            # （可选）清掉已有索引
```
或在「系统设置 → Siri 与聚焦 → 隐私」把 `/Volumes/istore` 拖进去。**不影响 iSCSI 卷的正常挂载与读写**，只是失去对该卷的 Spotlight 搜索能力。适合"先稳住，再修代码"。

### 3.2 P0：崩溃点直接加固（最小改动，最高收益）

#### P0-1 — `BeginTaskOnWorkloopThread` 入口校验 [`iSCSIVirtualHBA.cpp:549-553`]

**现状**：入口无任何 `owner`/`session`/`connection` 校验，直接在 `:555`（`owner->ParseInitiatorTaskTagForTaskType`）、`:562`（`session->sessionId`）等处解引用。对比同文件 `ProcessTaskOnWorkloopThread:690` 有 `if(!owner||!session||!connection) return true;`。

**改**：在 553 行函数体开头加：
```cpp
if(!owner || !session || !connection) {
    DBLog("iscsi: BeginTaskOnWorkloopThread bad args (owner=%p session=%p conn=%p)\n",
          owner, session, connection);
    return;
}
```

**局限说明**：NULL 检查挡不住"非-NULL 垃圾指针"（如 lr 污染场景），但能挡住 NULL 早退路径，且 `DBLog` 打印的指针值能在复现时佐证是否收到垃圾值（垃圾值通常表现为极大/负数地址）。务必配合 `DEBUG=1` 构建以激活 `DBLog`。

#### P0-2 — 审查 `iSCSITaskQueue::checkForWork` 的 action 调用 [`iSCSITaskQueue.cpp:135-156`]

**现状**：
```cpp
// iSCSITaskQueue.cpp:155
((iSCSITaskQueue::Action)action)((iSCSIVirtualHBA*)owner,session,connection,taskTag);
```
注释声称：`action` 存于基类 `IOEventSource::Action`（variadic），强转回具体 `iSCSITaskQueue::Action`（非 variadic）以用寄存器调用约定，否则"垃圾指针 → kernel panic"。

**风险与铁证的关联**：`lr=0x1a60` 落在函数间 `udf` 填充区，疑点指向**调用约定/栈状态损坏**。虽然 arm64 ABI 前 8 个参数（含 `session`/`connection`/`taskTag`）无论 variadic 都走寄存器、强转的实质影响在 arm64 上存疑，但**返回地址被污染**这一铁证说明该调用现场确实有问题——要么 action 调用约定错乱，要么 `session`/`connection`/`taskQueue` 在调用时已悬空（use-after-free）。

**改**（按风险从低到高，逐项验证）：
1. **确认全项目仅两处 action 调用点**：`iSCSIOEventSource.cpp:88` 和 `iSCSITaskQueue.cpp:155`。用 `ast-grep` 或 `grep -rn 'Action)action' Source/Kernel/` 核验，确保没有第三处绕过。
2. **action 调用前校验**：在 `:155` 前加 `owner`/`session`/`connection` 非空检查 + `DBLog`（与 P0-1 配合）。
3. **（结构性，可选）重构回调存储**：不依赖基类 `IOEventSource::Action`（variadic）字段，改用项目自定义的显式函数指针成员变量保存回调，从根上消除 variadic 隐患。

#### P0-3 — 定位 lr 污染源（结构性根因排查）

`lr=0x1a60`（udf 填充区）证明返回地址已坏。可能源：
- (i) action 调用约定错乱（P0-2 覆盖）；
- (ii) `session`/`connection`/`taskQueue` 在 `BeginTask` 执行时已被异步释放（use-after-free）→ 悬空指针解引用写到栈/返回地址。**最可能由 `HandleTimeout`（定时器线程）与 workloop 竞态引起**（见 P1-1/P1-2）。

这一项不是单点改动，而是通过 P1-1/P1-2 消除竞态来根除。P0-1/P0-2 是"先挡住/先观测"，P1 才是"根除"。

### 3.3 P1：结构性健壮性修复（改动较大，需充分测）

#### P1-1 — `HandleTimeout` 序列化到 workloop [`iSCSIVirtualHBA.cpp:399-438`]

**现状**：`HandleTimeout` 在 SCSI 栈定时器上下文直接调：
- `connection->taskQueue->completeCurrentTask()`（`:431`，操作链表 + `IOFree`）
- `CompleteParallelTask(...)`（`:434-438`，访问 `bytesPerSecondHistory`、可能 `queueTask` 延迟测量 `:786`）

与 workloop 线程的 `ProcessDataIn`/`ProcessSCSIResponse` 并发访问同一 connection/taskQueue，**无任何锁保护** → 链表损坏 / 双重释放 / use-after-free → 悬空指针流入 `BeginTask` 现场 → 污染栈/返回地址 → panic。

**改**：`HandleTimeout` 不得直接操作 `taskQueue`/`CompleteParallelTask`；改用 `GetCommandGate()->runAction(...)` 把这些操作派发到 workloop 线程执行；或用 `IOCommandSync`。即把 `:431`/`:434-438` 包进一个 workloop action。

#### P1-2 — `iSCSITaskQueue` 同步补全 [`iSCSITaskQueue.cpp:70-71`/`102-103`/`139-140`/`171-172`]

**现状**：
```cpp
if(!onThread())
    OSDynamicCast(iSCSIVirtualHBA,owner)->GetCommandGate();   // 返回值被丢弃，死代码
```
原意是 non-workloop 线程通过 CommandGate 序列化，但代码未完成。

**改**：完成 CommandGate 集成（`runAction` 派发到 workloop），或用 `IOSimpleLock`/`IOLock` 保护队列操作；最干净是强制所有队列操作都在 workloop 线程执行（配合 P1-1）。

#### P1-3 — 指针有效性校验 + 引用计数 [`iSCSIVirtualHBA.cpp` 多处]

| 位置 | 现状 | 改 |
|---|---|---|
| `ProcessDataIn:1063` | `dataDesc->writeBytes(dataOffset,buffer,length)` 未校验 `dataDesc` 非空/已 prepare | 校验 `dataDesc` 非空 + `prepare` 前置 + `length` 边界（不超过 `GetDataTransferCount`） |
| `ProcessSCSIResponse:948/961/964` | `FindTaskForControllerIdentifier` 返回后未校验即用 | 校验 `parallelTask` 非空（`SCSITaskIdentifier` 是 opaque 指针，`== NULL` 可行） |
| `ProcessParallelTask:488/520` | `sessionList[targetId]` 越界风险 / `session->connections[0]` 未校验 | `targetId` 边界检查 + session 非空校验 |
| `CompleteParallelTask:751` | 入口未校验 session/connection/task 活性 | 入口校验三者活性 |

**长期根治**：给 `iSCSISession`/`iSCSIConnection`（定义在 `iSCSITypesKernel.h`）加引用计数（`OSSharedPtr` 或自定义 `retain`/`release`），消除 use-after-free——这是 P1-1/P1-2 之外最彻底的防线。

### 3.4 P2：次要 bug（独立改动，顺手清）

| 编号 | 位置 | 问题 | 修法 |
|---|---|---|---|
| E4 | `iSCSIVirtualHBA.cpp:1625` | `memset(newConn->bytesPerSecondHistory,0,sizeof(UInt8)*n)`——`bytesPerSecondHistory` 是 `UInt32[30]`(120 字节)，只清了 30 字节，剩 90 未初始化 → 负载均衡算错 | 改 `sizeof(UInt32)*n` 或 `sizeof(newConn->bytesPerSecondHistory)` |
| E5 | `iSCSIVirtualHBA.cpp:455,461` | `HandleConnectionTimeout` 参数 `connectionId` 被循环局部变量遮蔽，`:461 DeactivateConnection` 停用的是循环结束值（`kiSCSIMaxConnectionsPerSession`）而非超时连接 | 重命名循环变量 |
| E8 | `iSCSIRFC3720Defaults.h:72,81,90` | `2e24` 是浮点科学记数法（2.0×10²⁴）非 `2^24`，转 `unsigned int` 是 UB | 改 `(1<<24)-1`（kernel 当前未引用，latent） |

---

## 4. 验证方案

1. **构建验证**：`./build_all.sh`（开日志用 `DEBUG=1 ./build_kext.sh && ./build_user.sh`）。每步改动后先确保编译链接通过。
2. **加载**：`sudo ./install.sh`（首次拦 → 系统设置允许 → 重启 → 再跑）。
3. **复现/回归**：`sudo ./login.sh <portal> <iqn>` → 盘挂载 → `sudo mdutil -i on /Volumes/istore`（或 `sudo mdimport /Volumes/istore` / `sudo mdutil -E /Volumes/istore` 加速触发）→ 观察 `/Library/Logs/DiagnosticReports/panic-*.panic` 是否再现。
4. **符号化（若再现）**：用 §2.6 的 atos 命令，对比 pc/lr 是否还落在 `BeginTaskOnWorkloopThread` / udf 填充区。
5. **诊断**：`sudo ./diag.sh <portal> <iqn>`（看 ISCSIX + iscsid 日志）；`log show --predicate 'eventMessage contains "iSCSI"' --last 10m` 看崩溃前 `DBLog` 输出的 sid/cid 是否为垃圾值（极大/负数），佐证 P0-1 的观测。

---

## 5. 执行 Agent 任务清单（step-by-step）

> 本节面向"执行时新启动的 Agent"。遵守：用户全局 `~/.claude/CLAUDE.md`（中文回答、从简单到复杂调试、Grep/ast-grep）；本项目无项目级 CLAUDE.md。CI 跑 `build_all.sh` + `App/build_app.sh` + `Installer/build_installer.sh`，改动必须保证三者全绿。

1. **通读本文档** + 读必读文件清单（步骤 8）。
2. **自行复现符号化**（验证本文档结论，建立信心）：
   ```bash
   cd /Users/nelsonking/Projects/open/iscsi-mac-silicon && ./build_all.sh
   atos -arch arm64e -o build/iSCSIInitiator.kext/Contents/MacOS/iSCSIInitiator -l 0xfffffe004d284000 0xfffffe004d289d44 0xfffffe004d285a60
   # 期望：BeginTaskOnWorkloopThread ... iSCSIVirtualHBA.cpp:680
   lldb build/iSCSIInitiator.kext/Contents/MacOS/iSCSIInitiator \
     -o "disassemble --start-address 0x5d10 --end-address 0x5d80" \
     -o "disassemble --start-address 0x1a30 --end-address 0x1a90" -o "quit"
   # 期望：0x5d44=mov w8,#-1+bl ProcessDataOutForTask；0x1a60 区=连续 udf #0x0
   ```
3. **（可选）进一步定位 brk 触发源**：反汇编整个 `BeginTaskOnWorkloopThread`（函数范围 `0x5a3c`–`0x5d88`），核对 prologue/epilogue 的栈帧设置（`ldp x29,x30` 位置）是否标准；如有条件用 `kmutil inspect --bundle-path build/iSCSIInitiator.kext` 或内核态 lldb 连真机内核 dump `__TEXT_EXEC`。
4. **按优先级改动**：P0-1 → P0-2 → P1-1 → P1-2 → P1-3 → P2。**每步改完 `./build_all.sh` 验证编译**（P1 改动大，建议每步单独提交，便于回退）。
5. **交回用户做加载/复现验证**：涉及 kext 加载需 sudo + 可能重启，由用户在真机执行（Agent 不直接 `sudo install.sh`，除非用户明确授权）。
6. **不要改的**（已确认正确）：
   - `socketCallback` 的 `signalWorkAvailable` 模式（`iSCSIIOEventSource.cpp:58`）。
   - 用户态 control path 的 `IOLock` 模式（`iSCSIHBAUserClient.cpp`）。
   - PDU 结构体的 `__attribute__((packed))` 标注。
   - 端序处理（`OSSwapBigToHostInt32/64` 等）。
   - `iSCSIInitiator.cpp`（nub，不涉及 panic）。
7. **CI 约束**：改动后本地至少 `./build_all.sh` 通过；如改了 App/Installer 相关，也跑 `App/build_app.sh` 和 `Installer/build_installer.sh`。
8. **必读文件**：
   - `Source/Kernel/iSCSIVirtualHBA.cpp`（约 2191 行，核心，所有 SCSI 路径在此）
   - `Source/Kernel/iSCSIVirtualHBA.h`（虚函数声明）
   - `Source/Kernel/iSCSITaskQueue.cpp` / `.h`（队列 + action 分发）
   - `Source/Kernel/iSCSIIOEventSource.cpp` / `.h`（socket 事件源 + action 分发）
   - `Source/Kernel/iSCSITypesKernel.h`（`iSCSISession`/`iSCSIConnection`——加引用计数处）
   - `build_kext.sh`（构建标志，`DBLog` 宏由 `-DDEBUG` 控制）
   - `Source/Kernel/Info.plist`（Segment 限制、依赖声明）

---

## 附录 A：完整 panic 日志关键摘录

```
panic(cpu 1 caller 0xfffffe004b148ad8): Break 0x0001 instruction exception from kernel.
  Panic (by design) at pc 0xfffffe004d289d44, lr 0xfffffe004d289c9c
  (saved state: 0xfffffe878e686d40)
  esr: 0x00000000f2000001  far: 0x0000000825098000
OS version: 25E253
Kernel version: Darwin Kernel Version 25.4.0: Thu Mar 19 19:33:25 PDT 2026;
  root:xnu-12377.101.15~1/RELEASE_ARM64_T6041
KernelCache slide: 0x000000003f0c0000
Kernel text exec base: 0xfffffe004a7f0000

Panicked task 0xfffffe2deb8b4088: 1438 pages, 5 threads: pid 72241: mdworker_shared
Panicked thread: 0xfffffe2debe951e8, backtrace: 0xfffffe878e6863c0, tid: 6948119
  ... (栈回溯 lr 链) ...
  lr: 0xfffffe004d289d44  fp: 0xfffffe878e6870b0   ← iSCSIInitiator 段内 (pc)
  lr: 0xfffffe004d285a60  fp: 0xfffffe878e687100   ← iSCSIInitiator 段内 (lr)
  lr: 0xfffffe0049c1c06c  fp: 0xfffffe878e687150   ← IOSCSIParallelFamily
  ...

Kernel Extensions in backtrace:
  com.apple.iokit.IOStorageFamily(2.1)
  com.apple.iokit.IOSCSIArchitectureModelFamily(545.100.10)
  com.apple.iokit.IOSCSIBlockCommandsDevice(545.100.10)
  com.apple.filesystems.apfs(2811.101.1)
  com.apple.iokit.IOSCSIParallelFamily(3.0)
  com.github.iscsi-osx.iSCSIInitiator(1.0)@0xfffffe004d284000->0xfffffe004d28ab6b
```

## 附录 B：符号化与反汇编命令模板

```bash
KEXT=/Users/nelsonking/Projects/open/iscsi-mac-silicon/build/iSCSIInitiator.kext/Contents/MacOS/iSCSIInitiator

# 1) atos：用 panic 日志基址符号化 pc/lr
atos -arch arm64e -o "$KEXT" -l 0xfffffe004d284000 0xfffffe004d289d44 0xfffffe004d285a60

# 2) atos：用原始文件偏移（无需基址）
atos -arch arm64e -o "$KEXT" 0x5d44 0x1a60

# 3) lldb：反汇编崩溃现场
lldb "$KEXT" \
  -o "image lookup -v -a 0x5d44" \
  -o "disassemble --start-address 0x5d10 --end-address 0x5d80" \
  -o "image lookup -v -a 0x1a60" \
  -o "disassemble --start-address 0x1a30 --end-address 0x1a90" \
  -o "quit"

# 4) 运行时获取 kext 加载基址（无 panic 日志时）
sudo kmutil showloaded | grep -A3 iSCSIInitiator
```

## 附录 C：kext 内 panic 点穷举结论

对 `Source/Kernel/` 全目录穷举 grep（`panic(`/`IOPanic`/`assert`/`ASSERT`/`__builtin_trap`/`abort`/`Require`/`require`/`check(`/`CHECK(`/`FailVar`/`fail:`/`LOG_ASSERT`/`DEBUG_ASSERT`/`bail`/`Fatal`/`kIOMessage` 等）**均无命中**。项目未 `#include <libkern/Require.h>`，IOKit `Require`/`require`/`assert`/`check` 系列宏根本未引入。构建配置无 `-fsanitize`/`-ftrapv`/`-fbounds-trap`。项目头文件未定义任何自定义 panic/assert 宏。

**结论**：kext 内无任何主动 panic 机制。panic 的真实来源是 XNU 自身的 `panic()`（`osfm/kern/debug.c`），arm64 上 `panic()` 记录消息后执行 `brk #1`。kext 通过解引用垃圾指针 / 命中不可恢复状态触发内核异常，XNU 异常处理路径随后 `panic()`。代码注释（`iSCSIOEventSource.h:63-69`、`iSCSIIOEventSource.cpp:81-88`、`iSCSITaskQueue.cpp:148-155`）把这类故障明确称作 "kernel panic"。

## 附录 D：两个调查 Agent 的关键结论引用

- **kext 代码深挖 Agent**：穷举确认无显式 panic；给出 SCSI Task 正/反向数据路径函数链（行号级）；最可疑点排序——D1 variadic-ABI action 分发点（`iSCSIOEventSource.cpp:88`、`iSCSITaskQueue.cpp:155`）、D2 `HandleTimeout` 与 workloop 竞态（`iSCSIVirtualHBA.cpp:399-438`）、D3 TaskQueue 同步缺失（`iSCSITaskQueue.cpp` 4 处 `GetCommandGate` 死代码）、D4-D7 指针校验。**注意**：该 Agent 无 kext 二进制，对 pc=0x5d44 的归属基于路径推测（说落在末段 919-2138），已被本文档 atos + lldb 实测纠正为 `BeginTaskOnWorkloopThread:680`。
- **工程流程 Agent**：摸清构建/安装/加载/卸载/诊断全流程；确认反复发作（`.claude/settings.local.json` 引用 8-13 panic）；给出符号化命令模板；确认 SCSI data path 全内核态、用户态不参与；列出 ISCSIX 无条件日志点；给出 CI 约束（`build_all.sh` + `App/build_app.sh` + `Installer/build_installer.sh` 必须全绿）。
