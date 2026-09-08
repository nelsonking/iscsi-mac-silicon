/* task tag 编解码 round-trip 测试。 */
#include <stdio.h>
#include "iSCSITaskTag.h"

static int failures = 0;
#define CHECK(cond, msg) do { \
    if(!(cond)) { printf("FAIL: %s\n", msg); failures++; } \
} while(0)

int main(void)
{
    uint32_t tag = iSCSIBuildInitiatorTaskTag(iSCSITaskTypeSCSITask, 3, 0x1234);
    CHECK(iSCSIParseInitiatorTaskTagForTaskType(tag) == iSCSITaskTypeSCSITask, "type 还原");
    CHECK(iSCSIParseInitiatorTaskTagForLUN(tag) == 3, "LUN 还原");
    CHECK(iSCSIParseInitiatorTaskTagForTaskId(tag) == 0x1234, "taskId 还原");

    tag = iSCSIBuildInitiatorTaskTag(iSCSITaskTypeLatency, 0, 0);
    CHECK(iSCSIParseInitiatorTaskTagForTaskType(tag) == iSCSITaskTypeLatency, "latency type");
    CHECK((tag >> 24) == iSCSITaskTypeLatency, "type 在 [31:24]");

    tag = iSCSIBuildInitiatorTaskTag(iSCSITaskTypeTaskMgmt, 0xFF, 0);
    CHECK(iSCSIParseInitiatorTaskTagForLUN(tag) == 0xFF, "LUN 高值");

    if(failures) { printf("%d 项断言失败\n", failures); return 1; }
    printf("task tag 测试全部通过\n");
    return 0;
}
