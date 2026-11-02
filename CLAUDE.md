# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

### 项目背景和目标

把废弃的 [iscsi-osx/iSCSIInitiator](https://github.com/iscsi-osx/iSCSIInitiator)（Nareg Sinenian 出品，BSD-2-Clause）移植到 Apple Silicon（macOS 13+，arm64e）的原生 iSCSI 发起器，并补上 SwiftUI 图形界面、一键安装包与设置引导。把远程 iSCSI 存储（NAS/SAN/TrueNAS/fnOS/LIO）挂载成 Mac 本地磁盘。

### 技术栈说明

| 层 | 语言/技术 | 目录 |
|---|---|---|
| 内核扩展 kext | C++17（无异常无 RTTI，`-fapple-kext -mkernel`，arm64e） | `Source/Kernel/` |
| 后台服务 iscsid | C（Objective-C + ARC） | `Source/User/iscsid/` |
| 共享框架 iSCSI.framework | C / Objective-C | `Source/User/iSCSI Framework/` |
| 命令行 iscsictl | Objective-C | `Source/User/iscsictl/` |
| 图形界面 | SwiftUI（AppKit / Combine / IOKit） | `App/Sources/` |
| 构建 | 仅 Command Line Tools（无需 Xcode/KDK），bash 脚本 | 根目录各 `*.sh` |

## 构建 / 测试 / 安装

```bash
./build_all.sh                       # 全量：kext(arm64e) + framework + iscsid + iscsictl
./build_kext.sh                      # 仅 kext；DEBUG=1 开启内核 DBLog 日志
./build_user.sh                      # 仅用户态（framework / iscsid / iscsictl）
cd App && ./build_app.sh             # SwiftUI App → build/iSCSI.app
cd Installer && ./build_installer.sh 1.0.0   # 打包 .pkg/.dmg（依赖前三步产物）

./tests/run_tests.sh                 # 宿主侧 C 单测（无需 kext），任一失败退出码非零
sudo ./install.sh                    # 就地安装并加载 kext + daemon + CLI + framework
open App/build/iSCSI.app             # 运行图形界面（菜单栏 App，无 Dock 图标）
```

- 产物都在 `./build/`；`ARCH` 环境变量可覆盖架构（kext 默认 `arm64e`、用户态默认 `arm64`）。
- 需 kext + target 的集成/性能测试写成流程文档放 `tests/manual/*.md`（见 `tests/README.md`）。
- 调试 CLI：`iscsictl add target <iqn>,<ip>:3260` → `iscsictl login <iqn>` → `iscsictl list targets/luns`。
- 清理残留 target：`iscsictl remove target <iqn>`（**必须带 `target` 子命令**）。

### Command Line Tools 的 modulemap 缺陷（构建 App 时）

较新 CLT 在 `usr/include/swift/` 同时带 `module.modulemap` 和 `bridging.modulemap`，两者都定义模块 `SwiftBridging`，导致任何导入 Foundation/SwiftUI 的 Swift 文件无法编译。`App/build_app.sh` 会自动检测并清空过期的 `module.modulemap`（保留 `.bak`）。详见 README「从源码构建」节。

## 架构

```
SwiftUI App ──► iscsictl ──► iscsid（launchd 后台服务）──► iSCSIInitiator.kext
（图形界面）   （命令行）    （会话 / 发现 / 认证 / 重连）  （虚拟 SCSI HBA，内核态 TCP）
                                                                   │
diskutil / iostat ◄── macOS 存储栈 ◄───────────────────────────────┘
```

- **内核扩展** 实现虚拟 SCSI HBA：`iSCSIVirtualHBA` 继承 `IOSCSIParallelInterfaceController`，内核态 BSD socket 直接收发 iSCSI PDU（RFC 3720），把远端 LUN 呈现为 `/dev/diskN`。**SCSI 数据路径完全在内核态**。
- **iscsid** 只负责会话/连接生命周期（登录协商、CHAP、SendTargets 发现、断线重连），不碰数据。
- **App** 不直接和内核通信，驱动 `iscsictl`，用 `diskutil` 读挂载点/容量、`iostat` 采样实时吞吐。

### 数据路径（全内核态）

- 写：`ProcessParallelTask → iSCSITaskQueue → BeginTaskOnWorkloopThread → SendPDU`
- 读：`RecvPDUHeader → ProcessDataIn → CompleteParallelTask`

### 线程模型与竞态不变量（改 kext 前必读）

- HBA 有一个 IOWorkLoop，`taskQueue` 与 `dataRecvEventSource` 挂其上，数据路径全在 workloop 线程。
- **任何触碰 `taskQueue` / `iSCSIConnection` / `iSCSISession` 的路径都必须序列化到 workloop**（用 command gate 的 `runAction`）：`HandleTimeout`、`ProcessParallelTask`、teardown（`DeactivateConnection`/`ReleaseConnection`）、以及基类的任务队列访问。
- 违反此不变量 → use-after-free → 内核 panic（本仓库有多次前科：Spotlight 索引 panic、recvBuffer 预分配 panic、corrupt list panic）。最近一批提交（`8530415`、`380223d` 等）正是在把各处序列化到 workloop。
- 命令流水线已启用：`iSCSITaskQueue` 从「单任务串行」改为「立即排空」（队列深度 > 1，受 `ReportMaximumTaskCount()=10` 约束）。该改动有「回退再恢复」的历史（`f2b9a7f` revert → `7b9960f` 恢复）；若再遇竞态，优先怀疑流水线引入的并发路径。

### 关键坑（详见 docs/PROJECT-CONTEXT.md「调试经验/坑」）

- `SO_SNDBUF`/`SO_RCVBUF` 必须在 `sock_connect` **之前**设置，否则 TCP 窗口缩放不生效（吞吐卡 ~155MB/s）。
- 热路径（`SendPDU`/`RecvPDUHeader`）禁止无条件 `IOLog`，用 `DBLog`（正式构建不打印）。
- IORegistry 的 BSD name key 是 `"BSD Name"`（大写 N）；Device Stats 的 key = `SCSI Target Identifier + 1` 的 `%016llx`（多 target 不能遍历取第一个）。
- 共享参数默认值集中在 `Source/Kernel/iSCSIRFC3720Defaults.h`（内核 + daemon 都生效）。

## 关键文件

| 文件 | 作用 |
|---|---|
| `Source/Kernel/iSCSIVirtualHBA.cpp` | 核心 HBA：数据路径、超时/teardown 序列化、socket 参数、HBAData |
| `Source/Kernel/iSCSITaskQueue.cpp` | 命令队列 + 流水线派发 + workloop 序列化 |
| `Source/Kernel/iSCSITypesKernel.h` | `iSCSISession` / `iSCSIConnection` 结构体 |
| `Source/Kernel/iSCSIRFC3720Defaults.h` | 共享 PDU/burst/协商默认值（已调大） |
| `App/Sources/ISCSIController.swift` | 连接 / 状态 / 速率采样（iostat） |
| `App/Sources/IOKitDiskFinder.swift` | findDisk、累计读写（Device Stats） |
| `docs/PROJECT-CONTEXT.md` | 完整本地改动史 + 调试经验 + 勿还原清单 |

### 记忆规范
1、 所有记忆内置到项目中，放到docs/memory中（没有则新建）
2、 个人敏感信息不记录到记忆中，如果一定要记录征询用户同意

### 文档记录规范
1、规则性文档需求文档统一放到docs中按分类进行存储
2、在分析代码的过程中如果发现了复杂规则，且文档无记录则先补充文档
3、如果代码的规则和文档不一样则询问用户采用那个规则，代码错了改代码，文档错了改文档
4、文档寻址规范，优先查看目录下的docs.index映射关系去分析查那个文档
5、某一个分类较多时则在对应的目录下建立 docs.index 创建映射关系 
6、docs 下记录 docs.index 记录映射关系，由Agent自动创建

### CLAUDE 行为规范
#### 1. 在编码前三思，别妄下定论。不要掩饰困惑。表面权衡。
在实施之前：
* 明确表达你的假设。如果不确定，可以问。
* 如果存在多种解读，就提出来——不要默默选择。
* 如果有更简单的方法，请说明。必要时反驳。
* 在我提出和项目由差异的想法时，先考虑我的想法是否正确，不能盲目的按照我的想法往下走。
如果有什么不清楚的地方，就停止。说出什么让人困惑。问吧。
 
#### 2. 简洁优先
#### 只需最小限度的代码来解决问题。没有任何猜测性内容。
除了被要求的部分，没有其他特征。
* 一次性代码不做抽象。
* 不可能的情景无需错误处理。
* 如果你写了200行，如果50能搞定，那就重写。
问问自己：“高级工程师会说这太复杂了吗？”如果是，那就简化。
 
#### 3. 手术变更
只触碰你必须触碰的部分。只收拾你自己的烂摊子。
编辑现有代码时：
* 不要“改进”相邻的代码、注释或格式。
* 不要重构那些没有坏掉的东西。
* 即使你会用不同的方式，也要匹配现有的风格。
* 如果你发现了无关的死代码，要提一提——不要删除。
测试：每一行更改的线条都应直接追踪到用户的请求。
 
#### 4. 目标驱动执行
定义成功标准。循环直到确认。
将任务转化为可验证的目标：
* “添加验证”→“为无效输入写测试，然后让它们通过”
* “修复 bug”→“写一个复现它的测试，然后让它通过”。
* “重构 X”→“确保测试在前后通过”
对于多步骤任务，请提出简要计划：
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
 
#### 5. CLAUDE.md文件自适应进化
* 如发现CLAUDE.md文件有误，就按真实情况修正
* 判断新增的内容是否需要记忆，如需要则记录到到CALUDE.md中
 
#### 6. 文档文件自适应进化
* 默认说明放到代码注释中为第一优先级，如修改内容涉及文件较多，联调较长，则代码注释简写，总览放到文档中
* 需求涉及内容较多无法放到代码中，将内容放到当前目录下docs文件夹中，简化文件标题
* 其他类型文档，例如规则说明，算法说明、排序说明、环境说明等，简化文件标题放到docs文件夹中
 
### 7. 权限申请策略
申请权限时，按当前工作目录的最高权限级别申请，避免逐文件单独授权。
 
#### 8.SQL处理规范
永远不要尝试执行SQL变更，SQL按日期写到sprintf文件夹中
 
```
sprintf目录格式/
└── sprintf/                    # SQL变更文件夹
    ├── YYYY-MM-DD-description.sql
    └── YYY-MM-DD-another-change.sql
```
 
## 开发规范
### 代码风格约定
- **语言要求**: 代码注释统一使用中文，代码标识符使用英文
- **命名规范**:
  - 变量和函数: `camelCase`
  - 类名和接口: `PascalCase`
  - 常量: `UPPER_SNAKE_CASE`
  - 文件命名: `kebab-case`
- **文件组织原则**:
  - 按功能模块划分，每个模块独立文件夹
  - 避免单个文件超过500行
  - 公共组件和工具函数放在共享目录
 
### 代码注释规范
* 用中文写注释，不论是工具类还是项目中，统一使用中文写注释，不要被原有项目的注释风格带偏
#### 1. 函数方法注释
```typescript
// 需求: 用户登录功能
// 详细说明: 实现基于JWT的用户认证，支持邮箱/密码登录，返回访问令牌
// 特殊要求: 需要记录登录日志，支持登录失败次数限制，会话有效期7天
```
 
### 测试规范
- **单元测试**: 宿主侧 C 单测放 `tests/test_*.c`，用 `./tests/run_tests.sh` 编译运行（无需 kext）
- **集成/手动测试**: 需 kext + target 的写成可执行流程文档放 `tests/manual/*.md`，判定标准明确
- **测试数据**: 避免硬编码；共享头默认值用编译期断言验证（如 `test_config_defaults.c`）
 
### 特殊说明
权限规则用通配符放宽，同类权限只申请一次
