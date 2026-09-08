/*
 * iSCSI initiator task tag 的纯位运算，与 IOKit 无关，可被宿主侧单测复用。
 *
 * task tag 布局（32 位）:
 *   [31:24] 任务类型  [23:16] LUN  [15:0] 任务 id
 */
#ifndef __ISCSI_TASK_TAG_H__
#define __ISCSI_TASK_TAG_H__

#include <stdint.h>

typedef enum {
    iSCSITaskTypeSCSITask = 0,
    iSCSITaskTypeLatency  = 1,
    iSCSITaskTypeTaskMgmt = 2
} iSCSITaskType;

static inline uint32_t iSCSIBuildInitiatorTaskTag(uint32_t taskType,
                                                  uint64_t LUN,
                                                  uint32_t taskId)
{
    return (uint32_t)(taskId | ((uint32_t)LUN << 16) | (taskType << 24));
}

static inline uint32_t iSCSIParseInitiatorTaskTagForTaskType(uint32_t tag)
{
    return (tag >> 24) & 0xFF;
}

static inline uint64_t iSCSIParseInitiatorTaskTagForLUN(uint32_t tag)
{
    return (tag >> 16) & 0xFF;
}

static inline uint32_t iSCSIParseInitiatorTaskTagForTaskId(uint32_t tag)
{
    return tag & 0xFFFF;
}

#endif /* __ISCSI_TASK_TAG_H__ */
