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
