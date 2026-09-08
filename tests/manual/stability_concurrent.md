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
3. 反复 3~5 轮，观察是否死机；事后 `sudo dmesg | grep -i panic`。

## 判定
- 全程无 panic、无 `element modified after free` 类报错。
- 若死机：收集 panic 日志，回退方案 1（`git revert`），重新排查并发路径（重点 `ProcessDataIn`/`ReleaseConnection` 与 workloop 的竞态）。
