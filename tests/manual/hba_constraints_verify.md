# 验证 ReportHBAConstraints（方案4）

## 目的
确认块层下发的单次 I/O 请求变大（从 ~128KB 提升到接近 1MB）。

## 前置
- 已安装新 kext（`sudo ./install.sh` 并重载）。
- iSCSI 卷已挂载（`/Volumes/istore`）。

## 步骤
1. 清理页缓存，确保测到真实磁盘 I/O：`sudo purge`
2. 后台启动单条顺序读，同时采样 iSCSI 磁盘的 iostat：
   ```
   dd if=/Volumes/istore/t.bin of=/dev/null bs=1m count=2000 &
   iostat -w 1 -c 4 disk5
   ```
   （若 `iostat` 报 `could not record 'disk5'`，用 `iostat -w 1 -c 4` 看全部磁盘，或 `diskutil list` 确认 iSCSI 卷的磁盘号。）

## 判定
- `KB/t` 列（平均每次请求字节）应明显大于改动前的 ~128KB，接近 1024（KB）。
- 若仍 ~128KB，说明约束未生效，回到代码检查 `ReportHBAConstraints` 是否被基类调用。
