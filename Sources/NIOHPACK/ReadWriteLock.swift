//
//  ReadWriteLock.swift
//  NIOHPACK
//
//  Created by Jim Dovey on 5/4/18.
//

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

import NIOConcurrencyHelpers    // to get the UnsafeMutablePointer.deallocate() extension

/// A reader-writer lock based on `libpthread` instead of `libdispatch`.
///
/// This object provides a lock on top of a `pthread_rwlock_t`, safe to use
/// with the `libpthread`-based threading model used by NIO.
///
/// - todo: This should be in `NIOConcurrencyHelpers` really.
public final class ReadWriteLock
{
    private let mutex: UnsafeMutablePointer<pthread_rwlock_t> = UnsafeMutablePointer.allocate(capacity: 1)
    
    /// Create a new lock.
    public init() {
        let err = pthread_rwlock_init(self.mutex, nil)
        precondition(err == 0)
    }
    
    deinit {
        let err = pthread_rwlock_destroy(self.mutex)
        precondition(err == 0)
        mutex.deallocate()
    }
    
    /// Acquire a read-lock.
    ///
    /// Whenever possible, use `withReadLock` instead of this method and `unlock`,
    /// to simplify lock handling.
    public func readLock() {
        let err = pthread_rwlock_rdlock(self.mutex)
        precondition(err == 0)
    }
    
    /// Acquire an exclusive write-lock.
    ///
    /// Whenever possible, use `withWriteLock` instead of this method and `unlock`,
    /// to simplify lock handling.
    public func writeLock() {
        let err = pthread_rwlock_wrlock(self.mutex)
        precondition(err == 0)
    }
    
    /// Unlock an acquired read- or write-lock.
    ///
    /// Whenever possible, use `withReadLock` or `withWriteLock` rather than
    /// this method and `readLock` or `writeLock`.
    public func unlock() {
        let err = pthread_rwlock_unlock(self.mutex)
        precondition(err == 0)
    }
}

extension ReadWriteLock
{
    /// Acquire a read-lock for the duration of the given block.
    ///
    /// This convenience method should be preferred to `readLock` and `unlock` in
    /// most situations, as it ensures that the lock will be released regardless
    /// of how `body` exits.
    ///
    /// - Parameter body: The block to execute while holding the lock.
    /// - Returns: The value returned by the block.
    @inlinable
    public func withReadLock<T>(_ body: () throws -> T) rethrows -> T {
        self.readLock()
        defer {
            self.unlock()
        }
        return try body()
    }
    
    /// Acquire a write-lock for the duration of the given block.
    ///
    /// This convenience method should be preferred to `writeLock` and `unlock` in
    /// most situations, as it ensures that the lock will be released regardless
    /// of how `body` exits.
    ///
    /// - Parameter body: The block to execute while holding the lock.
    /// - Returns: The value returned by the block.
    @inlinable
    public func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        self.writeLock()
        defer {
            self.unlock()
        }
        return try body()
    }
    
    // Specialize Void returns for performance.
    @inlinable
    public func withReadLockVoid(body: () throws -> Void) rethrows {
        self.readLock()
        defer {
            self.unlock()
        }
        try body()
    }
    
    @inlinable
    public func withWriteLockVoid(body: () throws -> Void) rethrows {
        self.writeLock()
        defer {
            self.unlock()
        }
        try body()
    }
}
