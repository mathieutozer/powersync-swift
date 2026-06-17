import BasicContainers
import DequeModule
import Foundation

/// An asynchronous mutex implemented as a simple actor.
actor AsyncMutex<T: ~Copyable> {
    var inner: T

    init(_ inner: consuming sending T) {
        self.inner = inner
    }

    func withMutex<R>(callback: (_ element: inout T) throws -> R) rethrows -> R {
        try callback(&inner)
    }
}

/// A serialized asynchronous semaphore with associated items.
///
/// Heavily inspired from https://github.com/powersync-ja/powersync-js/blob/main/packages/common/src/utils/mutex.ts.
final class AsyncSemaphore<T: ~Copyable>: Sendable {
    let count: Int
    fileprivate let state: Mutex<SemaphoreState<T>>

    /// Creates a semaphore by consuming a queue of items.
    init (_ values: consuming RigidDeque<T>) {
        self.count = values.count
        state = Mutex(SemaphoreState(
            available: values
        ))
    }

    /// Creates a semaphore from a single owned item.
    convenience init(singleElement: consuming T) {
        var queue = RigidDeque<T>(capacity: 1)
        queue.append(singleElement)
        self.init(queue)
    }

    fileprivate func returnItems(items: consuming RigidArray<T>) {
        var wakeups: [CheckedContinuation<(), Never>] = []
        state.withLock { state in
            while !items.isEmpty {
                state.returnItem(item: items.removeLast(), wakeups: &wakeups)
            }
        }
        // Resume OUTSIDE the lock — see deactivateWaiter for why.
        for continuation in wakeups {
            continuation.resume(returning: ())
        }
    }

    /// Acquires a flexible amount of items from this semaphore.
    func acquire(count: Int) async throws(CancellationError) -> SemaphoreGrant<T> {
        precondition(count > 0 && count <= self.count)
        do {
            try Task.checkCancellation()
        } catch {
            // As per checkCancellation() docs, the method exclusively throws cancellation errors.
            throw CancellationError()
        }

        let node = TypedWaitNode(semaphore: self)
        return try await node.acquire(count)
    }
}

extension AsyncSemaphore where T: Copyable {
    convenience init(from: [T]) {
        var queue = RigidDeque<T>(capacity: from.count)
        for item in from {
            let _ = queue.pushLast(item)
        }
        self.init(queue)
    }
}

/// A grant to a resource in an ``AsyncSemaphore``.
///
/// The grant is automatically returned when this struct goes out of scope.
struct SemaphoreGrant<T: ~Copyable>: ~Copyable {
    private let semaphore: AsyncSemaphore<T>
    var acquiredItems: RigidArray<T>

    fileprivate init(semaphore: AsyncSemaphore<T>, items: consuming RigidArray<T>) {
        self.semaphore = semaphore
        self.acquiredItems = items
    }

    deinit {
        semaphore.returnItems(items: acquiredItems)
    }
}

private struct SemaphoreState<T: ~Copyable>: ~Copyable {
    // Available items that are not currently assigned to a waiter.
    var available: RigidDeque<T>
    // Wait nodes are guaranteed to outlive these references because we call deactiveWaiter before
    // it gets freed.
    unowned var firstWaiter: SemaphoreWaitNode?
    unowned var lastWaiter: SemaphoreWaitNode?

    var size: Int {
        available.capacity
    }

    deinit {
        // This being called implies that the AsyncSemaphore is deallocated, which in turn implies
        // that no pending waiters reference it. So the list of waiters must be empty.
        assert(firstWaiter == nil)
        assert(lastWaiter == nil)
    }

    // IMPORTANT: a waiter's continuation must NOT be resumed while the SemaphoreState lock
    // (and/or the TypedWaitNode lock) is held. Resuming can synchronously run the resumed
    // task inline on the current thread, which then re-enters the semaphore locks — causing
    // an ABBA deadlock between the per-node lock and the state lock under contention (every
    // cooperative-pool DB op then piles up on the state lock forever). So we COLLECT the
    // continuations to resume into `wakeups` and the lock-holding caller resumes them AFTER
    // releasing the lock.
    private mutating func deactivateWaiter(
        waiter: SemaphoreWaitNode, wakeups: inout [CheckedContinuation<(), Never>]
    ) {
        if !waiter.isActive {
            return
        }

        let prev = waiter.prev
        let next = waiter.next
        waiter.prev = nil
        waiter.next = nil

        if let prev {
            prev.next = next
        }
        if let next {
            next.prev = prev
        }

        if waiter === firstWaiter {
            firstWaiter = next
        }
        if waiter === lastWaiter {
            lastWaiter = prev
        }

        waiter.isActive = false
        wakeups.append(waiter.continuation)
    }

    mutating func returnItem(
        item: consuming T, wakeups: inout [CheckedContinuation<(), Never>]
    ) {
        // Give it to the next waiter, if possible.
        if let firstWaiter {
            firstWaiter.pushItem(item: item)
            if firstWaiter.isFull {
                self.deactivateWaiter(waiter: firstWaiter, wakeups: &wakeups)
            }
        } else {
            // No pending waiter, return lease into pool.
            available.append(item)
        }
    }

    mutating func returnItems(
        items: consuming RigidArray<T>, wakeups: inout [CheckedContinuation<(), Never>]
    ) {
        while !items.isEmpty {
            returnItem(item: items.removeLast(), wakeups: &wakeups)
        }
    }

    mutating func abortWaiter(
        waiter: SemaphoreWaitNode, wakeups: inout [CheckedContinuation<(), Never>]
    ) {
        let items: RigidArray<T>? = waiter.consumeItems()
        deactivateWaiter(waiter: waiter, wakeups: &wakeups)
        if let items {
            returnItems(items: items, wakeups: &wakeups)
        }
    }

    mutating func addWaiter(
        requestedItems: Int, continuation: CheckedContinuation<(), Never>,
        wakeups: inout [CheckedContinuation<(), Never>]
    ) -> SemaphoreWaitNode {
        let node = SemaphoreWaitNode(requestedItems: requestedItems, continuation: continuation)
        if let lastWaiter {
            lastWaiter.next = node
            node.prev = lastWaiter
            self.lastWaiter = node
        } else {
            // First waiter
            firstWaiter = node
            lastWaiter = node
        }

        // If there are items in the pool that haven't been assigned, we can pull them into this waiter. Note that this is
        // only the case if we're the first waiter (otherwise, items would have been assigned to an earlier waiter).
        while !available.isEmpty && !node.isFull {
            node.pushItem(item: available.removeFirst())
        }

        if node.isFull {
            self.deactivateWaiter(waiter: node, wakeups: &wakeups)
        }
        return node
    }
}

// This isn't actually sendable, but we don't use it concurrently: While waiting, it's only mutated with a lock on SemaphoreState.
// Afterwards, it's sent to acquire() where it's only used in a single async context.
//
// This class is not generic: Making it generic (with `T: ~Copyable`) causes compiler errors because older runtimes can't compare
// objects with non-copyable type parameters by identity.
private final class SemaphoreWaitNode: @unchecked Sendable {
    let requestedItems: Int
    var acquiredItems: Int
    // pointer to [T; requestedItems]. Note that the region from acquiredItems..requestItems is uninitialized
    var itemsBuffer: UnsafeMutableRawPointer?
    var continuation: CheckedContinuation<(), Never>
    var isActive = true

    // Wait nodes are owned by a waiter. The only way for these to get dropped is by removing them
    // from the linked list, which also unsets prev/next on adjacent nodes.
    // This invariant is checked by also setting isActive = false when a wait node is disposed properly.
    // In deinit, we crash if isActive is still set.
    unowned var prev: SemaphoreWaitNode?
    unowned var next: SemaphoreWaitNode?

    init(requestedItems: Int, continuation: CheckedContinuation<(), Never>) {
        self.requestedItems = requestedItems
        self.continuation = continuation
        self.acquiredItems = 0
    }

    var isFull: Bool {
        acquiredItems == requestedItems
    }

    func pushItem<T: ~Copyable>(item: consuming T) {
        precondition(!isFull && isActive)

        if let items = itemsBuffer {
            items.assumingMemoryBound(to: T.self).advanced(by: acquiredItems).initialize(to: item)
        } else {
            let buffer: UnsafeMutablePointer<T> = .allocate(capacity: requestedItems)
            buffer.initialize(to: item)
            
            itemsBuffer = UnsafeMutableRawPointer(buffer)
        }

        acquiredItems += 1
    }

    func consumeItems<T: ~Copyable>() -> RigidArray<T>? {
        if let itemsBuffer {
            var array = RigidArray<T>(capacity: acquiredItems)
            let ptr = UnsafeBufferPointer(start: itemsBuffer.assumingMemoryBound(to: T.self), count: acquiredItems)
            array.insert(moving: UnsafeMutableBufferPointer(mutating: ptr), at: 0)
            // We don't have to deinitialize, array.insert moves elements out of the buffer.
            itemsBuffer.deallocate()
            self.itemsBuffer = nil
            return array
        } else {
            return nil
        }
    }

    deinit {
        assert(!isActive, "Wait node was dropped while active")
        assert(itemsBuffer == nil, "Wait node leaked items")
        assert(prev == nil && next == nil, "Wait node should be unlinked")
    }
}

private struct TypedWaitNode<T: ~Copyable>: Sendable, ~Copyable {
    private enum TypedWaitNodeState: ~Copyable {
        case hasWaiter(SemaphoreWaitNode)
        case cancelled
    }

    private let inner: Mutex<TypedWaitNodeState?> = Mutex(nil)
    private let semaphore: AsyncSemaphore<T>

    init(semaphore: AsyncSemaphore<T>) {
        self.semaphore = semaphore
    }

    /// Adds a wait node to the semaphore and waits for a grant or that node to be aborted.
    private func acquireInternal(count: Int) async {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                // Collected under the lock(s), resumed AFTER releasing them — see
                // SemaphoreState.deactivateWaiter for the deadlock this avoids.
                var wakeups: [CheckedContinuation<(), Never>] = []
                inner.withLock { state in
                    if state != nil {
                        wakeups.append(continuation)
                        return
                    }

                    let waiter = semaphore.state.withLock { state in
                        state.addWaiter(
                            requestedItems: count, continuation: continuation, wakeups: &wakeups)
                    }
                    state = .hasWaiter(waiter)
                }
                for resumed in wakeups {
                    resumed.resume(returning: ())
                }
            }
        }, onCancel: {
            var wakeups: [CheckedContinuation<(), Never>] = []
            inner.withLock { state in
                if case let .hasWaiter(waiter) = state {
                    semaphore.state.withLock { state in
                        state.abortWaiter(waiter: waiter, wakeups: &wakeups)
                    }
                }
                state = .cancelled
            }
            for resumed in wakeups {
                resumed.resume(returning: ())
            }
        })
    }

    consuming func acquire(_ count: Int) async throws(CancellationError) -> SemaphoreGrant<T> {
        await self.acquireInternal(count: count)

        var didComplete = false
        let items = inner.withLock { state in
            switch state! {
            case .hasWaiter(let node):
                assert(!node.isActive)
                let items: RigidArray<T>? = node.consumeItems()
                didComplete = node.isFull
                return items
            case .cancelled:
                return nil
            }
        }

        if let items {
            if didComplete {
                return SemaphoreGrant(semaphore: semaphore, items: items)
            }

            // We were able to obtain some items before aborting the read. Return those now.
            semaphore.returnItems(items: items)
        }

        throw CancellationError()
    }
}
