/* 断言 iSCSIRFC3720Defaults.h 中性能相关的默认值，防止被无意改回。 */
#include <stdio.h>
#include <stdbool.h>
#include "iSCSIRFC3720Defaults.h"

static int failures = 0;
#define CHECK(cond, msg) do { \
    if(!(cond)) { printf("FAIL: %s\n", msg); failures++; } \
} while(0)

int main(void)
{
    /* 方案2: InitialR2T 必须为 No，消除写路径的 R2T 往返 */
    CHECK(kRFC3720_InitialR2T == false, "InitialR2T 应为 false");
    /* 方案3: MaxOutstandingR2T 提升到 16，允许写 burst 并发 */
    CHECK(kRFC3720_MaxOutstandingR2T == 16, "MaxOutstandingR2T 应为 16");
    /* 早前已调大的 PDU/burst 参数，一并锁定 */
    CHECK(kRFC3720_MaxRecvDataSegmentLength == 262144, "MaxRecvDataSegmentLength 应为 256KB");
    CHECK(kRFC3720_MaxBurstLength == 1048576, "MaxBurstLength 应为 1MB");
    CHECK(kRFC3720_FirstBurstLength == 262144, "FirstBurstLength 应为 256KB");

    if(failures) {
        printf("%d 项断言失败\n", failures);
        return 1;
    }
    printf("config defaults 全部通过\n");
    return 0;
}
