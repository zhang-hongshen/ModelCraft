import Foundation
import MLX

struct InferenceLease: Sendable {
    fileprivate let id: UUID
    fileprivate let coordinator: InferenceRuntimeCoordinator

    func release() async {
        await coordinator.release(id: id)
    }
}

actor InferenceRuntimeCoordinator {
    static let shared = InferenceRuntimeCoordinator()

    private let cacheLimit: Int
    private var activeLease: UUID?
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<InferenceLease, Error>
    }

    private var waiters: [Waiter] = []

    init(cacheLimit: Int? = nil) {
        let defaultLimit = ProcessInfo.processInfo.physicalMemory <= 18_000_000_000
            ? 128 * 1024 * 1024
            : 256 * 1024 * 1024
        self.cacheLimit = max(0, cacheLimit ?? defaultLimit)
    }

    func acquire() async throws -> InferenceLease {
        let id = UUID()
        try Task.checkCancellation()
        if activeLease == nil {
            activeLease = id
            applyMemoryProfile()
            if Task.isCancelled {
                activeLease = nil
                throw CancellationError()
            }
            return InferenceLease(id: id, coordinator: self)
        }

        let lease: InferenceLease = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: id) }
        })

        // Cancellation can race with the continuation being resumed by
        // `release`. Never let a cancelled caller retain the newly granted
        // lease or start another heavy inference operation.
        if Task.isCancelled {
            await lease.release()
            throw CancellationError()
        }
        return lease
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }

        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func release(id: UUID) {
        guard activeLease == id else { return }
        guard !waiters.isEmpty else {
            activeLease = nil
            return
        }

        let waiter = waiters.removeFirst()
        activeLease = waiter.id
        applyMemoryProfile()
        waiter.continuation.resume(returning: InferenceLease(id: waiter.id, coordinator: self))
    }

    private func applyMemoryProfile() {
        if Memory.cacheLimit > cacheLimit {
            Memory.cacheLimit = cacheLimit
        }
    }
}
