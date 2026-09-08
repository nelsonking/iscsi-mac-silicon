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
