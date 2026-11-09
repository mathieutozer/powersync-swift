#if canImport(Darwin)
import Darwin

/// A backport of `Mutex` from the `Synchronization` module.
struct Mutex<T: ~Copyable>: @unchecked Sendable, ~Copyable {
    // We have to use pointer indirection to ensure the os_unfair_lock_t has a stable address.
    private let osLock = os_unfair_lock_t.allocate(capacity: 1)
    // This is behind a pointer to silence a compiler error about mutating its contents in a non-mutating func.
    private let value: UnsafeMutablePointer<T> = .allocate(capacity: 1)
    
    init(_ value: consuming T) {
        self.osLock.initialize(to: os_unfair_lock())
        self.value.initialize(to: value)
    }
    
    deinit {
        self.osLock.deinitialize(count: 1)
        self.osLock.deallocate()
        self.value.deinitialize(count: 1)
        self.value.deallocate()
    }
    
    func withLock<R: ~Copyable>(_ action: (_ value: inout T) throws -> R) rethrows -> R {
        os_unfair_lock_lock(self.osLock)
        defer { os_unfair_lock_unlock(self.osLock) }
        
        return try action(&value.pointee)
    }
}
#elseif os(Windows)
import WinSDK

/// A backport of `Mutex` from the `Synchronization` module, over a slim reader/writer lock.
struct Mutex<T: ~Copyable>: @unchecked Sendable, ~Copyable {
    // Behind a pointer so the SRWLOCK has a stable address.
    private let srwLock = UnsafeMutablePointer<SRWLOCK>.allocate(capacity: 1)
    private let value: UnsafeMutablePointer<T> = .allocate(capacity: 1)

    init(_ value: consuming T) {
        self.srwLock.initialize(to: SRWLOCK())
        InitializeSRWLock(self.srwLock)
        self.value.initialize(to: value)
    }

    deinit {
        self.srwLock.deinitialize(count: 1)
        self.srwLock.deallocate()
        self.value.deinitialize(count: 1)
        self.value.deallocate()
    }

    func withLock<R: ~Copyable>(_ action: (_ value: inout T) throws -> R) rethrows -> R {
        AcquireSRWLockExclusive(self.srwLock)
        defer { ReleaseSRWLockExclusive(self.srwLock) }

        return try action(&value.pointee)
    }
}
#elseif os(Linux)
import Glibc

/// A backport of `Mutex` from the `Synchronization` module, over a pthread mutex.
struct Mutex<T: ~Copyable>: @unchecked Sendable, ~Copyable {
    // Behind a pointer so the pthread_mutex_t has a stable address.
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private let value: UnsafeMutablePointer<T> = .allocate(capacity: 1)

    init(_ value: consuming T) {
        self.mutex.initialize(to: pthread_mutex_t())
        pthread_mutex_init(self.mutex, nil)
        self.value.initialize(to: value)
    }

    deinit {
        pthread_mutex_destroy(self.mutex)
        self.mutex.deinitialize(count: 1)
        self.mutex.deallocate()
        self.value.deinitialize(count: 1)
        self.value.deallocate()
    }

    func withLock<R: ~Copyable>(_ action: (_ value: inout T) throws -> R) rethrows -> R {
        pthread_mutex_lock(self.mutex)
        defer { pthread_mutex_unlock(self.mutex) }

        return try action(&value.pointee)
    }
}
#endif
