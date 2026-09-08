# iSCSI 性能优化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 iSCSI initiator 从 ~155MB/s（队列深度=1 的 RTT 受限）提升到接近网卡上限，同时建立测试目录。

**Architecture:** 内核态 kext + 用户态 daemon。核心改动是把 `iSCSITaskQueue` 从串行派发改成"立即排空"实现命令流水线，配合 InitialR2T=No、MaxOutstandingR2T=16、以及 override `ReportHBAConstraints` 扩大单次 I/O。

**Tech Stack:** C++ (kext, arm64e, `-fapple-kext -mkernel`)、C (daemon)、clang + Command Line Tools、bash。

**Spec:** [docs/superpowers/specs/2026-09-08-iscsi-pipelining-performance-design.md](../specs/2026-09-08-iscsi-pipelining-performance-design.md)

## Global Constraints

- 构建只用 Command Line Tools：`./build_all.sh`（= `./build_kext.sh` arm64e + `./build_user.sh` arm64）。
- kext 源码用 C++17（`-std=gnu++17`）、无异常无 RTTI；daemon 是 C。
- 共享头在 `Source/User/iSCSI Framework/` 与 `Source/Kernel/`，参数默认值集中在 `iSCSIRFC3720Defaults.h`（内核+daemon 共享）。
- 热路径（数据路径）禁止无条件 `IOLog`，用 `DBLog`。
- 保留全部现有 NULL 校验（use-after-free 前科，见 PROJECT-CONTEXT）。
- 提交信息用中文，风格对齐现有 `feat:` / `修改描述` 前缀。
- 测试不能跑 kext 的部分写进 `tests/manual/*.md` 作为可执行流程文档。

---

### Task 1: 测试基础设施 + config 默认值测试（红）

**Files:**
- Create: `tests/run_tests.sh`
- Create: `tests/test_config_defaults.c`

**Interfaces:**
- Produces: `tests/run_tests.sh`（编译并运行 `tests/*.c`，任一非零退出即失败）。后续任务复用。

- [ ] **Step 1: 写测试运行脚本 `tests/run_tests.sh`**

```bash
#!/bin/bash
# 编译并运行所有宿主侧单元测试（无需 kext）。
# 用法: ./tests/run_tests.sh   （失败时退出码非零）
set -euo pipefail
cd "$(dirname "$0")"

SHARED_HEADERS="../Source/Kernel"
CC="${CC:-clang}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
for t in test_*.c; do
    exe="$TMP/${t%.c}"
    echo ">> 编译并运行 $t"
    if "$CC" -std=c11 -Wall -Wextra -I"$SHARED_HEADERS" "$t" -o "$exe" \
       && "$exe"; then
        echo "   [PASS] $t"
        pass=$((pass+1))
    else
        echo "   [FAIL] $t"
        fail=$((fail+1))
    fi
done

echo ""
echo "结果: $pass 通过, $fail 失败"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: 写配置默认值测试 `tests/test_config_defaults.c`（断言新值）**

```c
/* 断言 iSCSIRFC3720Defaults.h 中性能相关的默认值，防止被无意改回。 */
#include <stdio.h>
#include "iSCSIRFC3720Defaults.h"

static int failures = 0;
#define CHECK(cond, msg) do { \
    if(!(cond)) { printf("FAIL: %s\n", msg); failures++; } \
} while(0)

int main(void)
{
    /* 方案2: InitialR2T 必须为 No，消除写路径的 R2T 往返 */
    CHECK(kRFC3720_InitialR2T == false, "InitialR2T 应为 false");
    /* 方案3: MaxOutstandingR2T 提升到 16，允许写 burst 并发 */
    CHECK(kRFC3720_MaxOutstandingR2T == 16, "MaxOutstandingR2T 应为 16");
    /* 早前已调大的 PDU/burst 参数，一并锁定 */
    CHECK(kRFC3720_MaxRecvDataSegmentLength == 262144, "MaxRecvDataSegmentLength 应为 256KB");
    CHECK(kRFC3720_MaxBurstLength == 1048576, "MaxBurstLength 应为 1MB");
    CHECK(kRFC3720_FirstBurstLength == 262144, "FirstBurstLength 应为 256KB");

    if(failures) {
        printf("%d 项断言失败\n", failures);
        return 1;
    }
    printf("config defaults 全部通过\n");
    return 0;
}
```

- [ ] **Step 3: 运行测试确认失败（红）**

Run: `./tests/run_tests.sh`
Expected: FAIL — `InitialR2T 应为 false`、`MaxOutstandingR2T 应为 16` 两项失败（当前值仍是 true / 1）。

- [ ] **Step 4: 暂不提交，Task 2 变绿后一起提交**

---

### Task 2: 方案 2（InitialR2T=No）+ 方案 3（MaxOutstandingR2T=16）

**Files:**
- Modify: `Source/Kernel/iSCSIRFC3720Defaults.h:42`（InitialR2T）
- Modify: `Source/Kernel/iSCSIRFC3720Defaults.h:111`（MaxOutstandingR2T）
- Modify: `Source/User/iscsid/iSCSISession.c:136`（daemon 协商发送）

**Interfaces:**
- Consumes: `tests/run_tests.sh`（Task 1）。
- Produces: 修改后 `kRFC3720_InitialR2T=false`、`kRFC3720_MaxOutstandingR2T=16`，daemon 协商发 `InitialR2T=No`。

- [ ] **Step 1: 改内核默认值头文件**

`Source/Kernel/iSCSIRFC3720Defaults.h`：

把第 42 行 `static const bool kRFC3720_InitialR2T = true;` 改为：

```c
static const bool kRFC3720_InitialR2T = false;
```

把第 111 行 `static const unsigned int kRFC3720_MaxOutstandingR2T = 1;` 改为：

```c
static const unsigned int kRFC3720_MaxOutstandingR2T = 16;
```

- [ ] **Step 2: 改 daemon 协商发送（硬编码 Yes → No）**

`Source/User/iscsid/iSCSISession.c` 第 136 行：

把 `CFDictionaryAddValue(sessCmd,kRFC3720_Key_InitialR2T,kRFC3720_Value_Yes);` 改为：

```c
CFDictionaryAddValue(sessCmd,kRFC3720_Key_InitialR2T,kRFC3720_Value_No);
```

（`kRFC3720_Value_No` 已定义于 `Source/User/iSCSI Framework/iSCSIRFC3720Keys.h:104`。）

- [ ] **Step 3: 运行测试确认通过（绿）**

Run: `./tests/run_tests.sh`
Expected: PASS — `config defaults 全部通过`。

- [ ] **Step 4: 构建 kext + 用户态**

Run: `./build_all.sh`
Expected: 退出码 0，无编译错误。

- [ ] **Step 5: 提交**

```bash
git add tests/run_tests.sh tests/test_config_defaults.c \
        Source/Kernel/iSCSIRFC3720Defaults.h \
        Source/User/iscsid/iSCSISession.c
git commit -m "feat: InitialR2T=No + MaxOutstandingR2T=16 提升写吞吐，新增 config 默认值测试"
```

---

### Task 3: 方案 4 —— override `ReportHBAConstraints`

**Files:**
- Modify: `Source/Kernel/iSCSIVirtualHBA.h`（声明 override，放在 `ReportMaximumTaskCount` 附近）
- Modify: `Source/Kernel/iSCSIVirtualHBA.cpp`（实现）
- Create: `tests/manual/hba_constraints_verify.md`（手动验证流程）

**Interfaces:**
- Consumes: 基类 `IOSCSIParallelInterfaceController` 虚方法签名 `virtual void ReportHBAConstraints(OSDictionary * constraints)`。
- Produces: `iSCSIVirtualHBA::ReportHBAConstraints`，上报 1MB 单次 I/O 上限。

- [ ] **Step 1: 头文件声明 override**

`Source/Kernel/iSCSIVirtualHBA.h`，在 `virtual UInt32 ReportMaximumTaskCount();`（第 117 行）后新增：

```cpp
    /*! Reports the I/O constraints for this controller. Overridden to raise
     *  the maximum single-I/O size to 1MB (matching MaxBurstLength) so the
     *  block layer issues larger transfers instead of the base-class default. */
    virtual void ReportHBAConstraints(OSDictionary * constraints);
```

- [ ] **Step 2: 实现**

`Source/Kernel/iSCSIVirtualHBA.cpp`，在 `ReportMaximumTaskCount()`（第 313-316 行）后新增：

```cpp
void iSCSIVirtualHBA::ReportHBAConstraints(OSDictionary * constraints)
{
    // The base class provides conservative defaults; overridden to raise the
    // max single-I/O size to 1MB (== MaxBurstLength) so the SCSI block layer
    // issues larger transfers. All required keys must be set here.
    if(!constraints)
        return;

    const UInt64 kMaxTransferBytes = 1024 * 1024;   // 1MB

    constraints->setObject(kIOMaximumSegmentByteCountReadKey,
        OSNumber::withNumber(kMaxTransferBytes, 64));
    constraints->setObject(kIOMaximumSegmentByteCountWriteKey,
        OSNumber::withNumber(kMaxTransferBytes, 64));
    constraints->setObject(kIOMaximumSegmentCountReadKey,
        OSNumber::withNumber((UInt64)256, 32));
    constraints->setObject(kIOMaximumSegmentCountWriteKey,
        OSNumber::withNumber((UInt64)256, 32));
    constraints->setObject(kIOMinimumSegmentAlignmentByteCountKey,
        OSNumber::withNumber((UInt64)4, 32));
    constraints->setObject(kIOMaximumSegmentAddressableBitCountKey,
        OSNumber::withNumber((UInt64)64, 32));
    constraints->setObject(kIOMinimumHBADataAlignmentMaskKey,
        OSNumber::withNumber((UInt64)0, 32));
}
```

> 注意：key 定义在 `Kernel.framework/Headers/IOKit/IOKitKeys.h`（`kIOMaximumSegmentByteCountReadKey` 等，均为 `(OSNumber)`）。若 `kIOMinimumHBADataAlignmentMaskKey` 名称有出入，以 IOKitKeys.h 实际定义为准。

- [ ] **Step 3: 构建 kext**

Run: `./build_kext.sh`
Expected: 退出码 0。若报未声明 key 或 OSNumber 类型，检查 IOKitKeys.h 的 key 拼写与 `#include <IOKit/IOKitKeys.h>`。

- [ ] **Step 4: 写手动验证流程文档 `tests/manual/hba_constraints_verify.md`**

```markdown
# 验证 ReportHBAConstraints（方案4）

## 目的
确认块层下发的单次 I/O 请求变大（从 ~128KB 提升到接近 1MB）。

## 前置
- 已安装新 kext（`sudo ./install.sh` 并重载）。
- iSCSI 卷已挂载（`/Volumes/istore`）。

## 步骤
1. 清理页缓存，确保测到真实磁盘 I/O：
   `sudo purge`
2. 后台启动单条顺序读，同时采样 iSCSI 磁盘的 iostat：
   ```
   dd if=/Volumes/istore/t.bin of=/dev/null bs=1m count=2000 &
   iostat -w 1 -c 4 disk5
   ```
   （若 `iostat` 报 `could not record 'disk5'`，用 `iostat -w 1 -c 4` 看全部磁盘，
   或 `diskutil list` 确认 iSCSI 卷的磁盘号。）

## 判定
- `KB/t` 列（平均每次请求字节）应明显大于改动前的 ~128KB，接近 1024（KB）。
- 若仍 ~128KB，说明约束未生效，回到代码检查 `ReportHBAConstraints` 是否被基类调用。
```

- [ ] **Step 5: 提交**

```bash
git add Source/Kernel/iSCSIVirtualHBA.h Source/Kernel/iSCSIVirtualHBA.cpp \
        tests/manual/hba_constraints_verify.md
git commit -m "feat: override ReportHBAConstraints 上报 1MB 单次 I/O 上限"
```

---

### Task 4: 提取 task tag 纯函数 + 单元测试

**Files:**
- Create: `Source/Kernel/iSCSITaskTag.h`（纯函数，仅用 stdint，无 IOKit 依赖）
- Modify: `Source/Kernel/iSCSIVirtualHBA.h`（删除内联成员版本，`#include "iSCSITaskTag.h"`）
- Modify: `Source/Kernel/iSCSIVirtualHBA.cpp`（改调用点，共 11 处）
- Create: `tests/test_task_tag.c`

**Interfaces:**
- Produces: 自由函数 `iSCSIBuildInitiatorTaskTag(uint32_t,uint64_t,uint32_t)→uint32_t`、`iSCSIParseInitiatorTaskTagForTaskType(uint32_t)→uint32_t`、`iSCSIParseInitiatorTaskTagForLUN(uint32_t)→uint64_t`、`iSCSIParseInitiatorTaskTagForTaskId(uint32_t)→uint32_t`。
- 原成员枚举 `InitiatorTaskTypes` 的三个值（`kInitiatorTaskTypeSCSITask=0`、`kInitiatorTaskTypeLatency=1`、`kInitiatorTaskTypeTaskMgmt=2`）随函数迁入共享头。

- [ ] **Step 1: 创建共享头 `Source/Kernel/iSCSITaskTag.h`**

```c
#ifndef __ISCSI_TASK_TAG_H__
#define __ISCSI_TASK_TAG_H__

/*! iSCSI initiator task tag 的纯位运算，与 IOKit 无关，可被宿主侧单测复用。
 *  task tag 布局（32 位）:
 *   [31:24] 任务类型  [23:16] LUN  [15:0] 任务 id
 */
#include <stdint.h>

typedef enum iSCSITaskType {
    iSCSITaskTypeSCSITask = 0,
    iSCSITaskTypeLatency  = 1,
    iSCSITaskTypeTaskMgmt = 2
} iSCSITaskType;

static inline uint32_t iSCSIBuildInitiatorTaskTag(uint32_t taskType,
                                                  uint64_t LUN,
                                                  uint32_t taskId)
{
    return (uint32_t)(taskId | ((uint32_t)LUN << 16) | (taskType << 24));
}

static inline uint32_t iSCSIParseInitiatorTaskTagForTaskType(uint32_t tag)
{
    return (tag >> 24) & 0xFF;
}

static inline uint64_t iSCSIParseInitiatorTaskTagForLUN(uint32_t tag)
{
    return (tag >> 16) & 0xFF;
}

static inline uint32_t iSCSIParseInitiatorTaskTagForTaskId(uint32_t tag)
{
    return tag & 0xFFFF;
}

#endif
```

- [ ] **Step 2: 删除 `iSCSIVirtualHBA.h` 里的内联成员版本，改 include**

`Source/Kernel/iSCSIVirtualHBA.h`：删除第 450-486 行的 `enum InitiatorTaskTypes { ... }`、`BuildInitiatorTaskTag`、`ParseInitiatorTaskTagForTaskType`、`ParseInitiatorTaskTagForLUN`、`ParseInitiatorTaskTagForTaskId`（保留第 488 行起的 `SetDataSegmentLength`）。在文件顶部 `#include` 区加入 `#include "iSCSITaskTag.h"`。

> 提示：若其它代码引用了 `InitiatorTaskTypes` 类型名，改用 `iSCSITaskType`；枚举值 `kInitiatorTaskType*` 改为 `iSCSITaskType*`。

- [ ] **Step 3: 改调用点（11 处）**

`Source/Kernel/iSCSIVirtualHBA.cpp`：

- `BuildInitiatorTaskTag(X,Y,Z)` → `iSCSIBuildInitiatorTaskTag(X,Y,Z)`（第 183/206/228/250/272/294/564/838 行）
- `owner->ParseInitiatorTaskTagForTaskType(X)` → `iSCSIParseInitiatorTaskTagForTaskType(X)`（第 596 行）
- `ParseInitiatorTaskTagForTaskId(X)` → `iSCSIParseInitiatorTaskTagForTaskId(X)`（第 859 行）
- `ParseInitiatorTaskTagForLUN(X)` → `iSCSIParseInitiatorTaskTagForLUN(X)`（第 860 行）
- 枚举值 `kInitiatorTaskTypeSCSITask`→`iSCSITaskTypeSCSITask`、`kInitiatorTaskTypeLatency`→`iSCSITaskTypeLatency`、`kInitiatorTaskTypeTaskMgmt`→`iSCSITaskTypeTaskMgmt`。

- [ ] **Step 4: 写单元测试 `tests/test_task_tag.c`**

```c
/* task tag 编解码 round-trip 测试。 */
#include <stdio.h>
#include "iSCSITaskTag.h"

static int failures = 0;
#define CHECK(cond, msg) do { \
    if(!(cond)) { printf("FAIL: %s\n", msg); failures++; } \
} while(0)

int main(void)
{
    uint32_t tag = iSCSIBuildInitiatorTaskTag(iSCSITaskTypeSCSITask, 3, 0x1234);
    CHECK(iSCSIParseInitiatorTaskTagForTaskType(tag) == iSCSITaskTypeSCSITask, "type 还原");
    CHECK(iSCSIParseInitiatorTaskTagForLUN(tag) == 3, "LUN 还原");
    CHECK(iSCSIParseInitiatorTaskTagForTaskId(tag) == 0x1234, "taskId 还原");

    tag = iSCSIBuildInitiatorTaskTag(iSCSITaskTypeLatency, 0, 0);
    CHECK(iSCSIParseInitiatorTaskTagForTaskType(tag) == iSCSITaskTypeLatency, "latency type");
    CHECK((tag >> 24) == iSCSITaskTypeLatency, "type 在 [31:24]");

    tag = iSCSIBuildInitiatorTaskTag(iSCSITaskTypeTaskMgmt, 0xFF, 0);
    CHECK(iSCSIParseInitiatorTaskTagForLUN(tag) == 0xFF, "LUN 高值");

    if(failures) { printf("%d 项断言失败\n", failures); return 1; }
    printf("task tag 测试全部通过\n");
    return 0;
}
```

- [ ] **Step 5: 运行测试**

Run: `./tests/run_tests.sh`
Expected: PASS — `config defaults 全部通过`、`task tag 测试全部通过`。

- [ ] **Step 6: 构建 kext**

Run: `./build_kext.sh`
Expected: 退出码 0。

- [ ] **Step 7: 提交**

```bash
git add Source/Kernel/iSCSITaskTag.h Source/Kernel/iSCSIVirtualHBA.h \
        Source/Kernel/iSCSIVirtualHBA.cpp tests/test_task_tag.c
git commit -m "refactor: 提取 task tag 纯函数到共享头并补充单元测试"
```

---

### Task 5: 方案 1 —— 命令流水线

**Files:**
- Modify: `Source/Kernel/iSCSITaskQueue.cpp`（`checkForWork` 循环派发、`queueTask` 信号逻辑、`completeCurrentTask` 退化为 no-op）
- Create: `tests/manual/perf_write.md`、`tests/manual/perf_read.md`、`tests/manual/stability_concurrent.md`

**Interfaces:**
- Consumes: `iSCSITaskQueue::checkForWork()`（`IOEventSource` 回调）、`iSCSITaskQueue::Action`（指向 `BeginTaskOnWorkloopThread`）。
- Produces: 派发语义从"一次一个"变为"立即排空"；`completeCurrentTask()` 保留但不再触发重新派发。

- [ ] **Step 1: 改 `checkForWork` 为循环排空**

`Source/Kernel/iSCSITaskQueue.cpp`，把 `checkForWork()`（第 122-165 行）整体替换为：

```cpp
bool iSCSITaskQueue::checkForWork()
{
    if(!isEnabled())
        return false;

    if(!newTask)
        return false;

    newTask = false;

    if(action && owner) {
        if(!onThread())
            IOLog("iscsi: WARNING taskQueue op off workloop\n");

        // Drain the entire queue: dispatch every queued task (each sends its
        // SCSI command) and dequeue it. This pipelines multiple commands so
        // the connection is no longer RTT-bound by a single outstanding task.
        while(!queue_empty(&taskQueue)) {
            iSCSITask * task = (iSCSITask *)queue_first(&taskQueue);
            UInt32 taskTag = task->initiatorTaskTag;

            if(!owner || !session || !connection) {
                IOLog("iscsi: TaskQueue action bad args (owner=%p session=%p conn=%p)\n",
                      owner, session, connection);
                break;
            }
            ((iSCSITaskQueue::Action)action)((iSCSIVirtualHBA*)owner,session,connection,taskTag);

            // Dequeue now that the command is dispatched; completion is
            // tracked by the SCSI subsystem (FindTaskForControllerIdentifier),
            // not by this queue.
            queue_remove_first(&taskQueue, task, iSCSITask *, queueChain);
            IOFree(task, sizeof(iSCSITask));
        }
    }

    return false;
}
```

- [ ] **Step 2: 改 `queueTask` 总是触发派发**

`Source/Kernel/iSCSITaskQueue.cpp`，把 `queueTask()`（第 62-86 行）里"仅队列空时才 signal"改为"每次入队都 signal"：

把：

```cpp
    bool firstTaskInQueue = false;
    if(queue_empty(&taskQueue))
        firstTaskInQueue = true;

    queue_enter(&taskQueue,task,iSCSITask *,queueChain);

    // Signal the workloop to process a new task...
    if(firstTaskInQueue) {
        newTask = true;

        if(getWorkLoop())
            signalWorkAvailable();
    }
```

替换为：

```cpp
    queue_enter(&taskQueue,task,iSCSITask *,queueChain);

    // Always signal so checkForWork drains the queue promptly (pipelining).
    newTask = true;

    if(getWorkLoop())
        signalWorkAvailable();
```

- [ ] **Step 3: `completeCurrentTask` 退化为 no-op（保留返回值语义）**

`Source/Kernel/iSCSITaskQueue.cpp`，把 `completeCurrentTask()`（第 91-119 行）整体替换为：

```cpp
UInt32 iSCSITaskQueue::completeCurrentTask()
{
    // With pipelining, tasks are dequeued at dispatch time (see checkForWork),
    // so completion needs no queue bookkeeping. Completion is tracked by the
    // SCSI subsystem. Kept as a no-op to preserve the call sites.
    return 0;
}
```

> 说明：调用点 `ProcessDataIn`/`ProcessTaskMgmtRsp`/`ProcessNOPIn`/`ProcessSCSIResponse` 仍会调用它，返回 0 无害。

- [ ] **Step 4: 构建 kext**

Run: `./build_kext.sh`
Expected: 退出码 0。

- [ ] **Step 5: 写性能测试流程 `tests/manual/perf_read.md` 与 `tests/manual/perf_write.md`**

`tests/manual/perf_read.md`：

```markdown
# 读性能测试（方案1 流水线后）

## 目的
验证单流读吞吐从 ~155MB/s 显著提升（目标接近网卡/目标上限）。

## 步骤
1. 生成测试文件（若无）：`dd if=/dev/zero of=/Volumes/istore/t.bin bs=1m count=5000`
2. 清缓存：`sudo purge`
3. 单流读：`dd if=/Volumes/istore/t.bin of=/dev/null bs=1m`
4. 记录 `bytes transferred in X secs (Y bytes/sec)`。

## 判定
- 改造前基线：~158 MB/s。
- 期望：显著高于基线；若仍 ~155MB/s，回到 `iSCSITaskQueue::checkForWork` 确认循环派发生效。
- 记录并发读（两条 dd 同时读不同文件）的总吞吐，应与单流基本持平或更高。
```

`tests/manual/perf_write.md`：

```markdown
# 写性能测试（方案1+2+3 后）

## 目的
验证单流写吞吐提升（InitialR2T=No + 流水线 + MaxOutstandingR2T=16）。

## 步骤
1. 单流写：`dd if=/dev/zero of=/Volumes/istore/t_w.bin bs=1m count=5000`
2. 记录吞吐。
3. 并发写：两个终端同时 `dd` 写两个不同文件，记录各自与总吞吐。

## 判定
- 改造前基线：单流 ~155 MB/s，并发总吞吐仍 ~155 MB/s。
- 期望：单流明显提升；并发总吞吐应显著高于单流（流水线真正生效的标志）。
```

- [ ] **Step 6: 写稳定性测试流程 `tests/manual/stability_concurrent.md`**

```markdown
# 并发稳定性测试（方案1 后，重点回归 use-after-free）

## 目的
验证多命令在途不触发 panic（本代码库曾因数据路径并发 use-after-free 死机）。

## 前置
- 安装新 kext 后重载。
- 建议先 `sudo nvram boot-args="keepsyms=1 debug=0x100"` 便于捕获 panic 符号（可选）。

## 步骤
1. 挂载 iSCSI 卷，写入两个 5GB 文件（触发大量写命令）。
2. 同时跑读 + 写：
   ```
   dd if=/Volumes/istore/t_1.bin of=/dev/null bs=1m &
   dd if=/dev/zero of=/Volumes/istore/t_2.bin bs=1m count=5000 &
   wait
   ```
3. 反复 3~5 轮，观察是否死机 / `sudo dmesg | grep -i panic`。

## 判定
- 全程无 panic、无 `element modified after free` 类报错。
- 若死机：收集 panic 日志，回退方案 1（`git revert`），重新排查并发路径。
```

- [ ] **Step 7: 提交**

```bash
git add Source/Kernel/iSCSITaskQueue.cpp \
        tests/manual/perf_read.md tests/manual/perf_write.md \
        tests/manual/stability_concurrent.md
git commit -m "feat: iSCSI 命令流水线（taskQueue 立即排空）+ 性能/稳定性测试流程"
```

---

### Task 6: 协商参数验证文档

**Files:**
- Create: `tests/manual/negotiation_verify.md`
- Create: `tests/README.md`

**Interfaces:**
- Consumes: 无（文档）。

- [ ] **Step 1: 写 `tests/manual/negotiation_verify.md`**

```markdown
# 验证协商参数（方案2/3 是否真的被 target 接受）

## 目的
确认 InitialR2T=No、MaxOutstandingR2T=16 在登录协商后生效（而非仅改默认值）。

## 步骤
1. 登录 target 后，列出会话协商结果：
   `iscsictl list target-config <iqn>`
   （iqn 用 `iscsictl list targets` 查询）
2. 观察输出中的 `InitialR2T`、`MaxOutstandingR2T`、`MaxBurstLength`、`FirstBurstLength`。

## 判定
- `InitialR2T` 应为 `No`（若 target 拒绝则仍为 Yes，需确认 Synology 是否支持）。
- `MaxOutstandingR2T` 应为 `16`（或 target 允许的较小值）。
- 若仍是 Yes/1：检查 daemon 是否重新编译（`build_user.sh`），以及协商逻辑 iSCSISession.c 是否改对。
```

- [ ] **Step 2: 写 `tests/README.md`**

```markdown
# 测试目录说明

- 自动测试：`./tests/run_tests.sh` —— 编译并运行 `test_*.c`（无需 kext）。
- 手动测试：`tests/manual/*.md` —— 需要安装 kext + iSCSI target 才能跑，按文档步骤执行并对照判定标准。

| 文件 | 覆盖 |
|---|---|
| `test_config_defaults.c` | 方案2/3 的默认值（InitialR2T、MaxOutstandingR2T 等） |
| `test_task_tag.c` | task tag 编解码纯函数 |
| `manual/perf_write.md` | 方案1/2/3 的写吞吐 |
| `manual/perf_read.md` | 方案1 的读吞吐 |
| `manual/stability_concurrent.md` | 方案1 的并发稳定性（防 use-after-free 回归） |
| `manual/hba_constraints_verify.md` | 方案4 的 HBA 约束生效 |
| `manual/negotiation_verify.md` | 方案2/3 的协商结果 |
```

- [ ] **Step 3: 提交**

```bash
git add tests/manual/negotiation_verify.md tests/README.md
git commit -m "docs: 补充协商参数验证与测试目录说明"
```

---

## 收尾

全部任务完成后：

- [ ] 跑 `./tests/run_tests.sh` 确认全部自动测试通过。
- [ ] 跑 `./build_all.sh` 确认 kext + 用户态编译通过。
- [ ] 提醒用户执行 `sudo ./install.sh` + 重载，并按 `tests/manual/` 文档做实测（尤其 `stability_concurrent.md`）。
