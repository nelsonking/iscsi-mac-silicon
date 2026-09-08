# 写性能测试（方案1+2+3 后）

## 目的
验证单流写吞吐提升（InitialR2T=No + 流水线 + MaxOutstandingR2T=16）。

## 前置
- 已安装新 kext + 用户态（`sudo ./install.sh` 并重载）。
- iSCSI 卷已挂载（`/Volumes/istore`）。

## 步骤
1. 单流写：
   `dd if=/dev/zero of=/Volumes/istore/t_w.bin bs=1m count=5000`
   记录 `bytes transferred in X secs (Y bytes/sec)`。
2. 并发写：两个终端同时各写一个不同文件：
   ```
   dd if=/dev/zero of=/Volumes/istore/t_w1.bin bs=1m count=5000 &
   dd if=/dev/zero of=/Volumes/istore/t_w2.bin bs=1m count=5000 &
   wait
   ```
   记录各自与总吞吐。

## 判定
- 改造前基线：单流 ~155 MB/s，并发总吞吐仍 ~155 MB/s（全局串行化）。
- 期望：单流明显提升；**并发总吞吐应显著高于单流**——这是流水线真正生效的标志。
- 若并发总吞吐仍 ≈ 单流，说明 `iSCSITaskQueue::checkForWork` 循环排空未生效，回查代码。
