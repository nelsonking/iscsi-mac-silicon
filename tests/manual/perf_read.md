# 读性能测试（方案1 流水线后）

## 目的
验证单流读吞吐从 ~155MB/s 显著提升（目标接近网卡/目标上限）。

## 前置
- 已安装新 kext。
- iSCSI 卷已挂载，且已有测试文件 `t.bin`。

## 步骤
1. 生成测试文件（若无）：`dd if=/dev/zero of=/Volumes/istore/t.bin bs=1m count=5000`
2. 清缓存，确保测到真实磁盘 I/O：`sudo purge`
3. 单流读：`dd if=/Volumes/istore/t.bin of=/dev/null bs=1m`
   记录吞吐。
4. （可选）并发读两条不同文件，记录总吞吐。

## 判定
- 改造前基线：~158 MB/s。
- 期望：显著高于基线；若仍 ~155MB/s，回到 `iSCSITaskQueue::checkForWork` 确认循环派发生效。
- 并发读总吞吐应比单流更高（流水线真正生效的标志）。

## 注意
- 必须 `sudo purge`，否则读到的是页缓存（会看到虚高的几百 MB/s，误导）。
