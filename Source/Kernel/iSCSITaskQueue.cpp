/*
 * Copyright (c) 2016, Nareg Sinenian
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#include "iSCSITaskQueue.h"

#define super IOEventSource

struct iSCSITask {
    queue_chain_t queueChain;
    UInt32 initiatorTaskTag;
};

OSDefineMetaClassAndStructors(iSCSITaskQueue,IOEventSource);

bool iSCSITaskQueue::init(iSCSIVirtualHBA * owner,
                          iSCSITaskQueue::Action action,
                          iSCSISession * session,
                          iSCSIConnection * connection)
{
	// Initialize superclass, check validity and store socket handle
	if(!super::init(owner,(IOEventSource::Action) action))
        return false;

    iSCSITaskQueue::session = session;
    iSCSITaskQueue::connection = connection;

    queueLock = IOLockAlloc();
    if(!queueLock)
        return false;

    // Initialize task queue to store parallel SCSI tasks for processing
    queue_init(&taskQueue);

    newTask = false;

	return true;
}

/*! Queues a new iSCSI task for delayed processing.
 *  @param initiatorTaskTag the iSCSI task tag associated with the task. */
void iSCSITaskQueue::queueTask(UInt32 initiatorTaskTag)
{
    // Signal the workloop thread that work is available only if this is
    // the only task in the queue (otherwise the task preceding this is
    // being processed; we'll get to this once that's done).
    iSCSITask * task = (iSCSITask*)IOMalloc(sizeof(iSCSITask));
    task->initiatorTaskTag = initiatorTaskTag;

    if(!onThread())
        IOLog("iscsi: WARNING taskQueue op off workloop\n");

    bool firstTaskInQueue = false;
    IOLockLock(queueLock);
    if(queue_empty(&taskQueue))
        firstTaskInQueue = true;
    queue_enter(&taskQueue,task,iSCSITask *,queueChain);
    IOLockUnlock(queueLock);

    // Signal the workloop to process a new task...
    if(firstTaskInQueue) {
        newTask = true;

        if(getWorkLoop())
            signalWorkAvailable();
    }
}

/*! Removes a task from the queue (either the task has been successfully
 *  completed or aborted).
 *  @return the iSCSI task tag for the task that was just completed. */
UInt32 iSCSITaskQueue::completeCurrentTask()
{
    UInt32 taskTag = 0;
    iSCSITask * task = NULL;

    if(!onThread())
        IOLog("iscsi: WARNING taskQueue op off workloop\n");

    // Remove the completed task (at the head of the queue) and check whether
    // more tasks remain — both under the lock so queueTask (on the SCSI stack
    // thread) can't interleave and corrupt the list.
    bool hasMore = false;
    IOLockLock(queueLock);
    if(!queue_empty(&taskQueue)) {
        queue_remove_first(&taskQueue,task,iSCSITask *, queueChain);
        if(task)
            taskTag = task->initiatorTaskTag;
        hasMore = !queue_empty(&taskQueue);
    }
    IOLockUnlock(queueLock);

    if(task)
        IOFree(task,sizeof(iSCSITask));

    // If there are still tasks to process let the HBA know...
    if(hasMore) {
        newTask = true;
        if(getWorkLoop())
            signalWorkAvailable();
    }
    return taskTag;
}


bool iSCSITaskQueue::checkForWork()
{
    if(!isEnabled())
        return false;

    if(!newTask)
        return false;

    newTask = false;

    if(action && owner) {
        UInt32 taskTag;
        iSCSITask * task = NULL;

        if(!onThread())
            IOLog("iscsi: WARNING taskQueue op off workloop\n");

        // Peek the head task under the lock, then dispatch it OUTSIDE the lock
        // (so socket I/O in the action doesn't hold the queue lock). The task
        // stays in the queue and is removed later by completeCurrentTask.
        IOLockLock(queueLock);
        if(queue_empty(&taskQueue)) {
            IOLockUnlock(queueLock);
            return false;
        }
        task = (iSCSITask *)queue_first(&taskQueue);
        taskTag = task->initiatorTaskTag;
        IOLockUnlock(queueLock);

        // 'action' is stored in the base class as the variadic
        // IOEventSource::Action; cast it back to our concrete Action type so the
        // call uses the register-based (non-variadic) calling convention. On
        // Apple arm64, calling through the variadic type passes
        // session/connection/taskTag on the stack while the callee reads them
        // from registers -> garbage pointers -> kernel panic. (Same class of bug
        // as iSCSIIOEventSource::checkForWork.)
        if(!owner || !session || !connection) {
            IOLog("iscsi: TaskQueue action bad args (owner=%p session=%p conn=%p)\n",
                  owner, session, connection);
            return false;
        }
        ((iSCSITaskQueue::Action)action)((iSCSIVirtualHBA*)owner,session,connection,taskTag);
    }

    return false;
}

/*! Removes all tasks from the queue. */
void iSCSITaskQueue::clearTasksFromQueue()
{
    // Ensure the event source is disabled before proceeding...
    disable();

    // Iterate over queue and clear all tasks (free memory for each task)
    iSCSITask * task = NULL;

    if(!onThread())
        IOLog("iscsi: WARNING taskQueue op off workloop\n");

    IOLockLock(queueLock);
    while(!queue_empty(&taskQueue))
    {
        queue_remove_first(&taskQueue,task,iSCSITask *, queueChain);
        if(task)
            IOFree(task,sizeof(iSCSITask));
    }
    IOLockUnlock(queueLock);
}
