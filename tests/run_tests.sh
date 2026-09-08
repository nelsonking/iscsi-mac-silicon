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
