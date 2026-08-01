# 使用说明 · Usage Guide

面向 Apple Silicon 的原生 iSCSI 客户端。把远程 iSCSI 存储挂成 Mac 上的本地磁盘。
Native iSCSI initiator for Apple Silicon — mount remote iSCSI storage as a local disk.

---

## 1. 打开 App / Launching

> ⚠️ **这是菜单栏 App，没有 Dock 图标。** 双击后不会弹窗，请看**屏幕右上角菜单栏**的磁盘图标。
> **This is a menu-bar app with no Dock icon.** After launching, look for the drive icon in the **top-right menu bar**, not the Dock.

- 点菜单栏图标 → 弹出快速面板（连接/断开、添加、打开管理窗口）。
- 首次启动、或还没添加过 target 时，会自动打开**管理窗口**。
- Click the menu-bar icon for the quick panel; the management window opens automatically on first run.

## 2. 一次性系统设置 / One-time setup

第三方内核扩展要求关闭 SIP。App 内置了设置向导，会实时检测并一步步引导：
Third-party kexts require SIP off. The built-in setup guide detects state and walks you through it:

1. 关机 → 长按电源键进入**恢复模式** → 终端 → `csrutil disable`
2. **启动安全性实用工具** → 选你的磁盘 → **降低安全性** + 允许被认可开发者的内核扩展
3. 重启 → 回到 App，向导里点「重新检测」，三项全绿即就绪
4. 首次加载扩展时若被系统拦截，到**系统设置 › 通用 › 登录项与扩展**点「允许」，按提示重启

> 用 `.pkg` 安装时，扩展和后台服务会自动装好并加载；只有首次批准是必须的人工步骤。

## 3. 添加并连接 Target / Add & connect

菜单栏或管理窗口 → **添加 Target**：

| 字段 | 说明 |
|------|------|
| 显示名称 Name | 随便起，列表里显示用 |
| 门户 Portal | NAS/存储的 IP，如 `192.168.1.100`，端口默认 `3260` |
| 目标 IQN | 目标名，如 `iqn.2010-01.com.example:target0`；留空可点「发现」自动探测 |
| CHAP 用户名/密码 | 需要认证才填，否则留空 |
| 开机自动连接 | 勾上后，每次开机自动登录并挂载 |

点 **保存并连接**。几秒后磁盘会挂载到 `/Volumes/…`，详情页显示容量与**实时吞吐**。

## 4. 日常操作 / Everyday use

- **断开**：详情页或菜单栏点「断开」——会先安全卸载卷再登出。
- **在访达中显示**：已挂载时可一键跳转到卷。
- **开机自动连接**：勾选后由 App 在启动时自动重连（App 需随登录启动）。
- **实时吞吐**：详情页显示当前 MB/s 与迷你波形图。

## 5. 卸载 / Uninstall

```bash
sudo iscsictl logout <你的target-iqn>          # 先登出所有 target
sudo rm -rf /Applications/iSCSI.app \
            /Library/Extensions/iSCSIInitiator.kext \
            /Library/Frameworks/iSCSI.framework \
            /usr/local/libexec/iscsid /usr/local/bin/iscsictl \
            /Library/LaunchDaemons/com.github.iscsi-osx.iscsid.plist \
            /etc/sudoers.d/iscsi-mac-silicon
sudo kmutil unload -b com.github.iscsi-osx.iSCSIInitiator   # 或重启
```

## 6. 常见问题 / Troubleshooting

| 现象 | 处理 |
|------|------|
| 双击 App 没反应 | 正常——它是菜单栏 App，看右上角图标 |
| 菜单栏提示「需要先完成设置」 | SIP 没关或扩展没加载，点进去按向导做 |
| 连接失败 | 检查 Portal/IQN 拼写、NAS 是否允许该发起端、CHAP 是否必填 |
| 连上了但盘没出现 | 目标上的 LUN 可能还没分区/格式化；用「磁盘工具」抹成 APFS/exFAT |
| 速度不理想 | 多半是链路瓶颈：确认网卡、交换机、网线三方都支持你期望的速率（如 2.5G 需全链路 NBASE-T），千兆上限约 118 MB/s |
| 升级 macOS 后失效 | 大版本升级可能重置 SIP/扩展策略，重跑一遍设置向导 |

---

遇到问题欢迎提 Issue。 Questions or bugs → open an issue.
