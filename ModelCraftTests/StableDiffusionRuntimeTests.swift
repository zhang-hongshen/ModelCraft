import Testing
@testable import ModelCraft

@Test
func sixteenGiBProfileUsesMixedQuantizationWithoutChangingSamplingDefaults() {
    let profile = StableDiffusionRuntimeProfile.recommended(
        physicalMemory: 16 * 1024 * 1024 * 1024)
    #expect(profile.loadConfiguration.float16)
    #expect(profile.loadConfiguration.textEncoderQuantization == .init(groupSize: 64, bits: 4))
    #expect(profile.loadConfiguration.unetQuantization == .init(groupSize: 32, bits: 8))
    let parameters = StableDiffusionConfiguration.presetSDXLTurbo.defaultParameters()
    #expect(parameters.steps == 2)
    #expect(parameters.latentSize == [64, 64])
    #expect(parameters.imageCount == 1)
    #expect(profile.releasesComponentsBetweenStages)
}

@Test
func largerMemoryProfileKeepsFP16WeightsUnquantized() {
    let profile = StableDiffusionRuntimeProfile.recommended(
        physicalMemory: 32 * 1024 * 1024 * 1024)
    #expect(profile.loadConfiguration.float16)
    #expect(profile.loadConfiguration.textEncoderQuantization == nil)
    #expect(profile.loadConfiguration.unetQuantization == nil)
    #expect(!profile.releasesComponentsBetweenStages)
}
