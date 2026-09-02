import Foundation
import MLX

struct InferenceMemoryProfile: Sendable, Equatable {
    let cacheLimit: Int

    init(cacheLimit: Int) {
        self.cacheLimit = max(0, cacheLimit)
    }

    static var deviceDefault: InferenceMemoryProfile {
        let sixteenGB = 18_000_000_000
        let limit = ProcessInfo.processInfo.physicalMemory <= sixteenGB
            ? 128 * 1024 * 1024
            : 256 * 1024 * 1024
        return .init(cacheLimit: limit)
    }
}

enum InferenceWorkload: String, Sendable {
    case languageModel
    case stableDiffusion
    case musicGen
    case miniMaxH3
    case ltxVideo
}

struct InferenceLease: Sendable {
    fileprivate let id: UUID
    fileprivate let coordinator: InferenceRuntimeCoordinator

    func release() async {
        await coordinator.release(id: id)
    }
}

actor InferenceRuntimeCoordinator {
    static let shared = InferenceRuntimeCoordinator()

    let profile: InferenceMemoryProfile
    private var activeLease: UUID?
    private struct Waiter {
        let id: UUID
        let workload: InferenceWorkload
        let continuation: CheckedContinuation<InferenceLease, Error>
    }

    private var waiters: [Waiter] = []

    init(profile: InferenceMemoryProfile = .deviceDefault) {
        self.profile = profile
    }

    func acquire(_ workload: InferenceWorkload) async throws -> InferenceLease {
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
                    waiters.append(Waiter(
                        id: id,
                        workload: workload,
                        continuation: continuation))
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

    func pendingWaiterCount() -> Int {
        waiters.count
    }

    func withExclusiveAccess<T: Sendable>(
        _ workload: InferenceWorkload,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let lease = try await acquire(workload)
        do {
            let value = try await operation()
            await lease.release()
            return value
        } catch {
            await lease.release()
            throw error
        }
    }

    private func applyMemoryProfile() {
        if Memory.cacheLimit > profile.cacheLimit {
            Memory.cacheLimit = profile.cacheLimit
        }
    }
}
