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
    // The SCSI parallel task to process. NULL for latency-measurement tasks.
    // Carried through the queue so BeginTaskOnWorkloopThread can get the task
    // directly on the workloop, instead of calling FindTaskForControllerIdentifier
    // (which would require the base-class task queue to already be populated).
    SCSIParallelTaskIdentifier parallelTask;
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
 *  @param parallelTask the SCSI parallel task to process (NULL for latency).
 *  @param initiatorTaskTag the iSCSI task tag associated with the task. */
void iSCSITaskQueue::queueTask(SCSIParallelTaskIdentifier parallelTask, UInt32 initiatorTaskTag)
{
    iSCSITask * task = (iSCSITask*)IOMalloc(sizeof(iSCSITask));
    task->initiatorTaskTag = initiatorTaskTag;
    task->parallelTask = parallelTask;

    // NOTE: queueTask runs on the SCSI stack thread (dispatched via
    // ProcessParallelTaskGated -> runAction), NOT the workloop thread. That is
    // expected — the queue is protected by queueLock, and the base-class task
    // queue is only touched later on the workloop. onThread() would be false
    // here and is not a sign of a bug, so no onThread() check.

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
    // With pipelining, checkForWork dequeues tasks at dispatch time, so this is
    // normally a no-op during steady-state I/O. It is still used by teardown
    // (DeactivateConnection) to drain any tasks that were queued but not yet
    // dispatched, so it must dequeue-and-return the next tag under the same lock
    // as checkForWork.
    UInt32 taskTag = 0;

    IOLockLock(queueLock);
    if(!queue_empty(&taskQueue)) {
        iSCSITask * task = (iSCSITask *)queue_first(&taskQueue);
        taskTag = task->initiatorTaskTag;
        queue_remove_first(&taskQueue, task, iSCSITask *, queueChain);
        IOFree(task, sizeof(iSCSITask));
    }
    IOLockUnlock(queueLock);

    return taskTag;
}

bool iSCSITaskQueue::removeTask(UInt32 initiatorTaskTag)
{
    bool removed = false;

    IOLockLock(queueLock);
    // Walk the queue manually (not queue_iterate) because queue_remove clobbers
    // the element's next/prev pointers, which would break the macro's advance
    // step; save the next pointer before removing.
    iSCSITask * task = (iSCSITask *)queue_first(&taskQueue);
    while(!queue_end(&taskQueue, (queue_entry_t)task)) {
        iSCSITask * next = (iSCSITask *)queue_next(&task->queueChain);
        if(task->initiatorTaskTag == initiatorTaskTag) {
            queue_remove(&taskQueue, task, iSCSITask *, queueChain);
            IOFree(task, sizeof(iSCSITask));
            removed = true;
            break;
        }
        task = next;
    }
    IOLockUnlock(queueLock);

    return removed;
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

        // Dequeue tasks one at a time under the lock, then dispatch OUTSIDE
        // the lock (so socket I/O doesn't hold it). This pipelines multiple
        // commands so the connection is no longer RTT-bound by a single
        // outstanding task. ('action' is cast back to the concrete Action type
        // for the register-based calling convention; see the original note
        // about Apple arm64 variadic-call panics.)
        while(true) {
            iSCSITask * task = NULL;
            UInt32 taskTag = 0;
            SCSIParallelTaskIdentifier parallelTask = NULL;

            IOLockLock(queueLock);
            if(queue_empty(&taskQueue)) {
                IOLockUnlock(queueLock);
                break;
            }
            task = (iSCSITask *)queue_first(&taskQueue);
            taskTag = task->initiatorTaskTag;
            parallelTask = task->parallelTask;
            queue_remove_first(&taskQueue, task, iSCSITask *, queueChain);
            IOLockUnlock(queueLock);

            if(!owner || !session || !connection) {
                IOLog("iscsi: TaskQueue action bad args (owner=%p session=%p conn=%p)\n",
                      owner, session, connection);
                IOFree(task, sizeof(iSCSITask));
                break;
            }
            ((iSCSITaskQueue::Action)action)((iSCSIVirtualHBA*)owner,session,connection,parallelTask,taskTag);
            IOFree(task, sizeof(iSCSITask));
        }
    }

    return false;
}
