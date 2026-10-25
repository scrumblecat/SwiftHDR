import Foundation
import Testing
@testable import SwiftHDR

@Suite("FFmpeg command construction")
struct CommandBuilderTests {
    private let metadata = VideoMetadata(
        duration: 20,
        width: 1080,
        height: 1920,
        frameRate: 60,
        codec: "h264",
        pixelFormat: "yuv420p",
        colorRange: "tv",
        colorSpace: "bt709",
        colorTransfer: "bt709",
        colorPrimaries: "bt709"
    )

    @Test func hlgTagsAndTenBitHardwareEncoding() {
        let command = makeCommand()
        #expect(command.arguments.contains("hevc_videotoolbox"))
        #expect(command.arguments.contains("main10"))
        #expect(command.arguments.contains("p010le"))
        #expect(command.arguments.contains("bt2020"))
        #expect(command.arguments.contains("arib-std-b67"))
        #expect(command.arguments.contains("bt2020nc"))
        #expect(command.arguments.contains("hvc1"))
    }

    @Test func filterGraphPerformsConversionInsteadOfOnlyRetagging() {
        let graph = makeCommand().filterGraph
        #expect(graph.contains("transferin=bt709"))
        #expect(graph.contains("matrix=gbr"))
        #expect(graph.contains("transfer=linear"))
        #expect(graph.contains("primaries=bt2020"))
        #expect(graph.contains("transfer=arib-std-b67"))
        #expect(graph.contains("format=yuv420p10le"))
    }

    @Test func hardwareEncodingCannotFallBackToSoftware() throws {
        let arguments = makeCommand().arguments
        let index = try #require(arguments.firstIndex(of: "-allow_sw"))
        #expect(arguments[index + 1] == "0")
        #expect(!arguments.contains("libx265"))
    }

    @Test func looksProgressFromMildToVividWithRestrainedPeaks() {
        #expect(HDRPreset.allCases.map(\.rawValue) == ["Natural", "Dynamic", "Pro"])
        #expect(HDRPreset.natural.saturation < HDRPreset.dynamic.saturation)
        #expect(HDRPreset.dynamic.saturation < HDRPreset.pro.saturation)
        #expect(HDRPreset.natural.contrast < HDRPreset.dynamic.contrast)
        #expect(HDRPreset.dynamic.contrast < HDRPreset.pro.contrast)
        #expect(HDRPreset.allCases.map(\.peakNits) == [400, 500, 600])
        for preset in HDRPreset.allCases {
            let points = preset.masterCurve.split(separator: " ").map { $0.split(separator: "/").compactMap { Double($0) } }
            #expect(points.first == [0, 0])
            #expect(points.last == [1, 1])
            for (previous, next) in zip(points, points.dropFirst()) {
                #expect(next[0] > previous[0])
                #expect(next[1] > previous[1])
            }
        }
    }

    @Test(arguments: HDRPreset.allCases)
    func everyLookAppliesItsOwnToneAndLuminance(preset: HDRPreset) {
        let graph = makeCommand(preset: preset).filterGraph
        #expect(graph.contains("curves=master='\(preset.masterCurve)'"))
        #expect(graph.contains(String(format: "saturation=%.3f", preset.saturation)))
        #expect(graph.contains(String(format: "colorchannelmixer=rr=%.3f:gg=%.3f:bb=%.3f", preset.hdrLinearScale, preset.hdrLinearScale, preset.hdrLinearScale)))
    }

    @Test func palBT601InputTagsAreHonored() {
        let pal = VideoMetadata(
            duration: 20,
            width: 1920,
            height: 1080,
            frameRate: 60,
            codec: "hevc",
            pixelFormat: "yuv420p",
            colorRange: "tv",
            colorSpace: "bt470bg",
            colorTransfer: "bt709",
            colorPrimaries: "bt470bg"
        )
        let command = FFmpegCommandBuilder(
            inputURL: URL(fileURLWithPath: "/tmp/input.mp4"),
            outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
            metadata: pal,
            preset: .dynamic
        )

        #expect(command.filterGraph.contains("matrixin=bt470bg"))
        #expect(command.filterGraph.contains("primariesin=bt470bg"))
        #expect(command.filterGraph.contains("dither=error_diffusion"))
    }

    @Test func palMatrixInfersMissingPALPrimaries() {
        let palMatrixOnly = VideoMetadata(
            duration: 20,
            width: 1920,
            height: 1080,
            frameRate: 60,
            codec: "hevc",
            pixelFormat: "yuv420p",
            colorRange: "tv",
            colorSpace: "bt470bg",
            colorTransfer: "unknown",
            colorPrimaries: "unknown"
        )
        let command = FFmpegCommandBuilder(
            inputURL: URL(fileURLWithPath: "/tmp/input.mp4"),
            outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
            metadata: palMatrixOnly,
            preset: .dynamic
        )

        #expect(command.filterGraph.contains("matrixin=bt470bg"))
        #expect(command.filterGraph.contains("primariesin=bt470bg"))
        #expect(palMatrixOnly.sourceColorLabel == "BT.601 PAL")
    }

    @Test func unknownSourceTagsExposeBT709Fallback() {
        let unrecognized = VideoMetadata(
            duration: 20,
            width: 1920,
            height: 1080,
            frameRate: 60,
            codec: "hevc",
            pixelFormat: "yuv420p",
            colorRange: "tv",
            colorSpace: "reserved",
            colorTransfer: "reserved",
            colorPrimaries: "reserved"
        )

        #expect(unrecognized.sourceColorLabel.contains("BT.709 fallback"))
    }

    @Test func main10ProfileIsShownAsTenBitWhenPixelFormatIsUnknown() {
        let profileOnly = VideoMetadata(
            duration: 20,
            width: 1920,
            height: 1080,
            frameRate: 60,
            codec: "hevc",
            pixelFormat: "unknown",
            colorRange: "tv",
            colorSpace: "bt709",
            colorTransfer: "bt709",
            colorPrimaries: "bt709",
            profile: "Main 10"
        )

        #expect(profileOnly.depthLabel == "10-bit")
    }

    @Test(arguments: [
        (1080, 1920, 60.0, 15), (1920, 1080, 30.0, 8),
        (2160, 3840, 30.0, 30), (3840, 2160, 60.0, 60),
        (1440, 2560, 60.0, 27), (1280, 720, 30.0, 4),
        (640, 360, 24.0, 2), (7680, 4320, 120.0, 120),
        (1920, 1080, 0.0, 8), (1920, 1080, 29.97, 8)
    ])
    func hardwareEncoderScalesBitrateByResolutionAndFrameRate(configuration: (Int, Int, Double, Int)) throws {
        let (width, height, frameRate, megabits) = configuration
        let source = VideoMetadata(
            duration: 20, width: width, height: height, frameRate: frameRate,
            codec: "prores", pixelFormat: "yuv422p10le", colorRange: "tv",
            colorSpace: "bt709", colorTransfer: "bt709", colorPrimaries: "bt709"
        )
        for preset in HDRPreset.allCases {
            let command = FFmpegCommandBuilder(
                inputURL: URL(fileURLWithPath: "/tmp/input.mov"),
                outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
                metadata: source, preset: preset
            )
            let arguments = command.arguments
            let bitrateIndex = try #require(arguments.firstIndex(of: "-b:v"))
            let maximumIndex = try #require(arguments.firstIndex(of: "-maxrate"))
            let bufferIndex = try #require(arguments.firstIndex(of: "-bufsize"))
            #expect(arguments[bitrateIndex + 1] == "\(megabits)M")
            #expect(arguments[maximumIndex + 1] == "\(megabits)M")
            #expect(arguments[bufferIndex + 1] == "\(megabits * 2)M")
            #expect(arguments.contains("hevc_videotoolbox"))
            #expect(arguments.last == "/tmp/output.mp4")
            #expect(!arguments.contains("-crf"))
        }
    }

    private func makeCommand(preset: HDRPreset = .dynamic) -> FFmpegCommandBuilder {
        FFmpegCommandBuilder(
            inputURL: URL(fileURLWithPath: "/tmp/input.mp4"),
            outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
            metadata: metadata,
            preset: preset
        )
    }
}
