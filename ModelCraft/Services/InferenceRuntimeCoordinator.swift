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
    private var waiters: [(UUID, InferenceWorkload, CheckedContinuation<InferenceLease, Never>)] = []

    init(profile: InferenceMemoryProfile = .deviceDefault) {
        self.profile = profile
    }

    func acquire(_ workload: InferenceWorkload) async -> InferenceLease {
        let id = UUID()
        if activeLease == nil {
            activeLease = id
            applyMemoryProfile()
            return InferenceLease(id: id, coordinator: self)
        }

        return await withCheckedContinuation { continuation in
            waiters.append((id, workload, continuation))
        }
    }

    func release(id: UUID) {
        guard activeLease == id else { return }
        guard !waiters.isEmpty else {
            activeLease = nil
            return
        }

        let (nextID, _, continuation) = waiters.removeFirst()
        activeLease = nextID
        applyMemoryProfile()
        continuation.resume(returning: InferenceLease(id: nextID, coordinator: self))
    }

    func withExclusiveAccess<T: Sendable>(
        _ workload: InferenceWorkload,
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        let lease = await acquire(workload)
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
