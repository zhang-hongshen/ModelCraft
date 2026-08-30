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

    static func recommended(physicalMemory: UInt64) -> Self {
        let sixteenGiB = 16 * 1024 * 1024 * 1024
        if physicalMemory <= sixteenGiB {
            return Self(
                loadConfiguration: LoadConfiguration(
                    float16: true,
                    textEncoderQuantization: WeightQuantization(groupSize: 64, bits: 4),
                    unetQuantization: WeightQuantization(groupSize: 32, bits: 8)),
                releasesComponentsBetweenStages: true)
        }

        return Self(
            loadConfiguration: LoadConfiguration(
                float16: true, textEncoderQuantization: nil, unetQuantization: nil),
            releasesComponentsBetweenStages: false)
    }
}
