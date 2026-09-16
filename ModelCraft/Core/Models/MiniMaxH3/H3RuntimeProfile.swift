//
//  H3RuntimeProfile.swift
//  ModelCraft
//
//  Created by Hongshen on 12/9/26.
//


import Foundation

/// How much of one MiniMax H3 Base render a machine is asked to keep resident.
///
/// H3 differs from the other model families in this app in one decisive way: its
/// four components total roughly 144 GB and its largest single component is the
/// 66.7 GB text encoder, so no tier this app targets can hold two stages at
/// once. The profile therefore does not tune speed or precision. It decides
/// whether a component is read whole or a piece at a time, and where residency is
/// given up: ``H3Configuration`` carries it, ``H3Loader``'s component loaders read
/// it as they build a component, and ``H3Base`` reads it at each stage boundary.
///
/// Quantization and block-wise streaming are deliberately absent. Both need
/// machinery that does not exist yet — a converted checkpoint, and a byte-range
/// weight reader to replace the shard-at-a-time accessor — and a field that
/// nothing reads would misreport what the model actually does.
struct H3RuntimeProfile: Equatable, Sendable {
    enum Tier: Equatable, Sendable {
        /// Under 16 GiB. Every stage has to hand its weights back, and even then
        /// the 66.7 GB text encoder only fits because it runs one layer at a time.
        case survival
        /// Under 24 GiB.
        case constrained
        /// Under 48 GiB.
        case balanced
        /// 48 GiB and up. Still far below the 144 GB working set, which is why
        /// releasing stays on here.
        case full
    }

    let tier: Tier

    /// Give a finished stage's weights back before the next stage loads.
    ///
    /// True at every tier. The threshold where holding the whole pipeline would
    /// win sits above 192 GiB of unified memory, past every tier this app has a
    /// preset for; below it, a render that keeps two stages alive is holding
    /// memory it never reads again.
    let releasesComponentsBetweenStages: Bool

    /// Read a component whole as its stage starts, instead of a piece at a time
    /// as the stage reaches it.
    ///
    /// Read by the two components that have pieces to read, both in ``H3Loader``:
    ///
    /// - ``H3Loader/loadEncoder(hub:configuration:)`` — true builds both halves of
    ///   the H3 Encoder before returning; false returns the container with neither
    ///   half read, and each is built the first time a render asks for it.
    /// - ``H3Loader/loadOmniTransformer(hub:configuration:computeDType:report:)`` —
    ///   true passes `releasesLayersAfterUse: false` to ``H3OmniTransformer``, so
    ///   the first step's walk leaves all 50 layers resident; false gives each
    ///   layer back as the walk leaves it.
    ///
    /// It deliberately does not reach the other three stacks: the text encoder's
    /// pass reads each language layer once and never comes back to it, so holding
    /// one would only keep 975 MB alive; the VAE decoder is walked many times
    /// inside a single lazy graph and so holds its blocks whatever this says; and
    /// the vision tower is 824 MB in one shard, small enough to read whole and not
    /// a layered stack at all. The two VAEs are read whole inside the loader at
    /// every tier: neither has a stack to stream.
    ///
    /// False at every tier this app has a preset for. The transformer stack alone
    /// is 64.56 GB, larger than the total memory of anything under 96 GiB, and
    /// reading it whole is only worth it when its layers then stay cached across
    /// all 20 denoise steps — which is exactly what a smaller machine cannot
    /// promise. It is a field rather than a constant because the choice is a
    /// device property.
    ///
    /// Reading a component whole means building its parts and attaching the
    /// tensors to them, not paging the bytes in: a returned array costs a
    /// descriptor entry until something evaluates it.
    let loadsComponentsEagerly: Bool

    static func recommended(physicalMemory: UInt64) -> Self {
        let gibibyte = UInt64(1024 * 1024 * 1024)

        if physicalMemory < 16 * gibibyte {
            return Self(
                tier: .survival,
                releasesComponentsBetweenStages: true,
                loadsComponentsEagerly: false)
        }
        if physicalMemory < 24 * gibibyte {
            return Self(
                tier: .constrained,
                releasesComponentsBetweenStages: true,
                loadsComponentsEagerly: false)
        }
        if physicalMemory < 48 * gibibyte {
            return Self(
                tier: .balanced,
                releasesComponentsBetweenStages: true,
                loadsComponentsEagerly: false)
        }
        return Self(
            tier: .full,
            releasesComponentsBetweenStages: true,
            // 128 GiB is the first size where the larger of the two stacks, a
            // 38k-token working set and the OS fit at once.
            loadsComponentsEagerly: physicalMemory >= 128 * gibibyte)
    }

    static var deviceDefault: Self {
        recommended(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }
}
