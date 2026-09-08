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
    iSCSITask * task = (iSCSITask*)IOMalloc(sizeof(iSCSITask));
    task->initiatorTaskTag = initiatorTaskTag;

    if(!onThread())
        IOLog("iscsi: WARNING taskQueue op off workloop\n");

    IOLockLock(queueLock);
    queue_enter(&taskQueue,task,iSCSITask *,queueChain);
    IOLockUnlock(queueLock);

    // Always signal so checkForWork drains the queue promptly (pipelining).
    newTask = true;

    if(getWorkLoop())
        signalWorkAvailable();
}

/*! Removes a task from the queue (either the task has been successfully
 *  completed or aborted).
 *  @return the iSCSI task tag for the task that was just completed. */
UInt32 iSCSITaskQueue::completeCurrentTask()
{
    // With pipelining, tasks are dequeued at dispatch time (see checkForWork),
    // so completion needs no queue bookkeeping. Completion is tracked by the
    // SCSI subsystem (FindTaskForControllerIdentifier). Kept as a no-op to
    // preserve the call sites.
    return 0;
}


bool iSCSITaskQueue::checkForWork()
{
    if(!isEnabled())
        return false;

    if(!newTask)
        return false;

    newTask = false;

    if(action && owner) {
        if(!onThread())
            IOLog("iscsi: WARNING taskQueue op off workloop\n");

        // Dequeue tasks one at a time under the lock — queueTask runs on the
        // SCSI stack thread and can enqueue concurrently — then dispatch
        // outside the lock so socket I/O doesn't hold it. This pipelines
        // multiple commands so the connection is no longer RTT-bound by a
        // single outstanding task. ('action' is cast back to the concrete
        // Action type for the register-based calling convention; see the
        // original note about Apple arm64 variadic-call panics.)
        while(true) {
            iSCSITask * task = NULL;
            UInt32 taskTag = 0;

            IOLockLock(queueLock);
            if(queue_empty(&taskQueue)) {
                IOLockUnlock(queueLock);
                break;
            }
            task = (iSCSITask *)queue_first(&taskQueue);
            taskTag = task->initiatorTaskTag;
            queue_remove_first(&taskQueue, task, iSCSITask *, queueChain);
            IOLockUnlock(queueLock);

            if(!owner || !session || !connection) {
                IOLog("iscsi: TaskQueue action bad args (owner=%p session=%p conn=%p)\n",
                      owner, session, connection);
                IOFree(task, sizeof(iSCSITask));
                break;
            }
            ((iSCSITaskQueue::Action)action)((iSCSIVirtualHBA*)owner,session,connection,taskTag);
            IOFree(task, sizeof(iSCSITask));
        }
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
