import Foundation

public struct WeightQuantization: Equatable, Sendable {
    public let groupSize: Int
    public let bits: Int

    public init(groupSize: Int, bits: Int) {
        self.groupSize = groupSize
        self.bits = bits
    }
}

struct StableDiffusionRuntimeProfile: Sendable {
    let loadConfiguration: LoadConfiguration
    let releasesComponentsBetweenStages: Bool
    let generationSteps: Int

    static func recommended(physicalMemory: UInt64) -> Self {
        let eightGiB = 8 * 1024 * 1024 * 1024
        let sixteenGiB = 16 * 1024 * 1024 * 1024
        let twentyFourGiB = 24 * 1024 * 1024 * 1024
        if physicalMemory <= sixteenGiB {
            return Self(
                loadConfiguration: LoadConfiguration(
                    float16: true,
                    textEncoderQuantization: WeightQuantization(groupSize: 64, bits: 4),
                    unetQuantization: WeightQuantization(groupSize: 32, bits: 8)),
                releasesComponentsBetweenStages: true,
                generationSteps: physicalMemory <= eightGiB ? 1 : 2)
        }

        return Self(
            loadConfiguration: LoadConfiguration(
                float16: true, textEncoderQuantization: nil, unetQuantization: nil),
            releasesComponentsBetweenStages: false,
            generationSteps: physicalMemory < twentyFourGiB ? 2 : 4)
    }
}
