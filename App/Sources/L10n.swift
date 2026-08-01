import Foundation

// Lightweight bilingual localization that follows the system language at
// runtime. We intentionally avoid .strings bundles so the whole app can be
// compiled with the Command Line Tools alone (no Xcode asset pipeline).
enum Lang { case zh, en }

enum L10n {
    static let lang: Lang = {
        let prefs = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return prefs.hasPrefix("zh") ? .zh : .en
    }()

    // key -> (zh, en)
    private static let table: [String: (String, String)] = [
        // App / general
        "app.name":            ("iSCSI", "iSCSI"),
        "app.tagline":         ("面向 Apple Silicon 的原生 iSCSI 客户端", "Native iSCSI initiator for Apple Silicon"),
        "common.connect":      ("连接", "Connect"),
        "common.disconnect":   ("断开", "Disconnect"),
        "common.cancel":       ("取消", "Cancel"),
        "common.save":         ("保存", "Save"),
        "common.remove":       ("移除", "Remove"),
        "common.done":         ("完成", "Done"),
        "common.retry":        ("重试", "Retry"),
        "common.refresh":      ("刷新", "Refresh"),
        "common.open":         ("打开", "Open"),
        "common.continue":     ("继续", "Continue"),
        "common.reveal":       ("在访达中显示", "Reveal in Finder"),
        "common.quit":         ("退出", "Quit"),
        "common.settings":     ("管理窗口", "Manage"),
        "common.none":         ("无", "None"),
        "common.optional":     ("可选", "Optional"),
        "common.copy":         ("拷贝", "Copy"),
        "common.copied":       ("已拷贝", "Copied"),
        "common.working":      ("处理中…", "Working…"),

        // Menu bar
        "menu.connected.n":    ("%d 个 target 已连接", "%d target(s) connected"),
        "menu.none":           ("未连接", "Nothing connected"),
        "menu.addTarget":      ("添加 Target…", "Add Target…"),
        "menu.openManager":    ("打开管理窗口", "Open Manager"),

        // Status
        "status.connected":    ("已连接", "Connected"),
        "status.mounted":      ("已挂载", "Mounted"),
        "status.connMounted":  ("已连接 · 已挂载", "Connected · Mounted"),
        "status.disconnected": ("未连接", "Not connected"),
        "status.connecting":   ("连接中…", "Connecting…"),
        "status.error":        ("连接失败", "Failed"),
        "status.saved":        ("已保存未连接", "Saved · offline"),

        // Detail
        "detail.connInfo":     ("连接信息", "Connection"),
        "detail.portal":       ("门户 Portal", "Portal"),
        "detail.iqn":          ("目标 IQN", "Target IQN"),
        "detail.auth":         ("身份验证", "Authentication"),
        "detail.autoconnect":  ("开机自动连接", "Connect at login"),
        "detail.on":           ("已开启", "On"),
        "detail.off":          ("已关闭", "Off"),
        "detail.disk":         ("磁盘 · 实时吞吐", "Disk · Live throughput"),
        "detail.mountedAt":    ("挂载于", "Mounted at"),
        "detail.notMounted":   ("已连接，磁盘未挂载", "Connected, not mounted"),
        "detail.empty.title":  ("选择一个 Target", "Select a target"),
        "detail.empty.sub":    ("从左侧选择，或添加一个新的 iSCSI 目标。", "Pick one on the left, or add a new iSCSI target."),
        "detail.sessionFor":   ("会话已建立", "Session up"),

        // Add target
        "add.title":           ("添加 Target", "Add Target"),
        "add.sub":             ("输入 iSCSI 服务器地址与目标名称", "Enter the server address and target name"),
        "add.name":            ("显示名称", "Display name"),
        "add.name.ph":         ("例如 nas磁盘", "e.g. My NAS"),
        "add.portal":          ("门户地址 Portal", "Portal address"),
        "add.portal.hint":     ("NAS 或存储服务器的 IP，端口默认 3260", "IP of your NAS/storage. Port defaults to 3260."),
        "add.iqn":             ("目标 IQN", "Target IQN"),
        "add.iqn.hint":        ("留空则通过 SendTargets 自动发现该门户下的目标", "Leave blank to auto-discover via SendTargets"),
        "add.chapUser":        ("CHAP 用户名", "CHAP username"),
        "add.chapSecret":      ("CHAP 密码", "CHAP secret"),
        "add.discover":        ("发现目标…", "Discover…"),
        "add.discovered":      ("发现的目标", "Discovered targets"),
        "add.connectNow":      ("保存并连接", "Save & Connect"),
        "add.saveOnly":        ("仅保存", "Save only"),

        // Onboarding / SIP
        "onb.welcome":         ("欢迎使用 iSCSI", "Welcome to iSCSI"),
        "onb.welcome.sub":     ("把远程 iSCSI 存储挂成 Mac 上的原生磁盘。开始前需要完成一次性系统设置。", "Mount remote iSCSI storage as native disks. A one-time system setup is required first."),
        "onb.step":            ("步骤 %d / %d", "Step %d of %d"),
        "onb.sip.title":       ("关闭系统完整性保护 (SIP)", "Disable System Integrity Protection"),
        "onb.sip.why":         ("本工具依赖一个内核扩展 (kext) 来实现 iSCSI。Apple 要求加载第三方 kext 前先降低安全策略并关闭 SIP。这是一次性操作。", "This tool uses a kernel extension (kext) to speak iSCSI. Apple requires lowering the security policy and disabling SIP before loading third-party kexts. One-time only."),
        "onb.sip.steps":       ("操作步骤", "How to"),
        "onb.sip.s1":          ("关机，长按电源键进入「恢复模式」（开机选项）。", "Shut down. Hold the power button to enter Recovery (startup options)."),
        "onb.sip.s2":          ("选择「选项」→「实用工具」→「终端」。", "Choose Options → Utilities → Terminal."),
        "onb.sip.s3":          ("在终端输入下面这条命令并回车：", "Type this command in Terminal and press Return:"),
        "onb.sip.s4":          ("再打开「启动安全性实用工具」，选中你的磁盘 →「降低安全性」并勾选「允许用户管理来自被认可开发者的内核扩展」。", "Open Startup Security Utility, pick your disk → Reduced Security, and check \u{201C}Allow user management of kernel extensions from identified developers.\u{201D}"),
        "onb.sip.s5":          ("重启回到 macOS，回到本 App 继续。", "Reboot back into macOS and return here."),
        "onb.sip.enabled":     ("SIP 已开启 — 需要先关闭", "SIP is ON — must be disabled"),
        "onb.sip.disabled":    ("SIP 已关闭 ✓", "SIP is disabled ✓"),
        "onb.sip.recheck":     ("我已重启，重新检测", "I rebooted — re-check"),
        "onb.kext.title":      ("允许并加载内核扩展", "Approve & load the kernel extension"),
        "onb.kext.why":        ("首次加载时 macOS 会拦截并要求你批准。到「系统设置 › 通用 › 登录项与扩展 / 隐私与安全性」点击「允许」，按提示重启。", "On first load macOS blocks the kext and asks you to approve it. Go to System Settings › General › Login Items & Extensions (or Privacy & Security), click Allow, and reboot if prompted."),
        "onb.kext.openSettings":("打开系统设置", "Open System Settings"),
        "onb.kext.load":       ("加载内核扩展", "Load kernel extension"),
        "onb.kext.notLoaded":  ("内核扩展未加载", "Kernel extension not loaded"),
        "onb.kext.loaded":     ("内核扩展已加载 ✓", "Kernel extension loaded ✓"),
        "onb.daemon.notRunning":("后台服务未运行", "Background service not running"),
        "onb.daemon.running":  ("后台服务运行中 ✓", "Background service running ✓"),
        "onb.ready.title":     ("一切就绪", "You're all set"),
        "onb.ready.sub":       ("系统设置已完成，现在可以添加并连接 iSCSI 目标了。", "System setup is complete. You can now add and connect iSCSI targets."),
        "onb.ready.go":        ("开始使用", "Get started"),
        "onb.copy":            ("拷贝命令", "Copy command"),

        // Errors / help
        "err.title":           ("出错了", "Something went wrong"),
        "err.needSetup":       ("需要先完成系统设置", "Finish the system setup first"),
        "banner.sipOn":        ("SIP 已开启，iSCSI 无法工作 — 点此查看如何修复", "SIP is on — iSCSI can't work. Click to fix."),
        "banner.kextOff":      ("内核扩展未加载 — 点此加载", "Kernel extension not loaded — click to load."),
        "help.title":          ("帮助与故障排查", "Help & troubleshooting"),
    ]

    static func t(_ key: String) -> String {
        guard let pair = table[key] else { return key }
        return lang == .zh ? pair.0 : pair.1
    }
    // formatted
    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }
}

// Shorthand
func L(_ key: String) -> String { L10n.t(key) }
func L(_ key: String, _ args: CVarArg...) -> String { String(format: L10n.t(key), arguments: args) }
