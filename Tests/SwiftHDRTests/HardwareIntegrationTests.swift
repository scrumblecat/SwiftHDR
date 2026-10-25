import Foundation
import Testing
@testable import SwiftHDR

@Suite("Hardware exports", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SWIFTHDR_RUN_INTEGRATION"] == "1"))
struct HardwareIntegrationTests {
    @Test(arguments: HDRPreset.allCases)
    func realExportPreservesVideoAudioAndHDRMetadata(preset: HDRPreset) async throws {
        let tools = try #require(FFmpegLocator.locate())
        let runner = FFmpegRunner(ffmpegURL: tools.ffmpeg, ffprobeURL: tools.ffprobe)
        #expect(await runner.supportsHardwareEncoding())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swifthdr-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.mp4")
        try run(tools.ffmpeg, [
            "-v", "error", "-nostdin",
            "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=60:d=0.5",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.5",
            "-c:v", "h264_videotoolbox", "-allow_sw", "0",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-c:a", "aac", "-shortest", input.path
        ])
        let metadata = try await runner.probe(input)
        let output = directory.appendingPathComponent("output.mp4")
        let command = FFmpegCommandBuilder(inputURL: input, outputURL: output, metadata: metadata, preset: preset)
        try await runner.convert(command: command) { _ in }
        let result = try await runner.validateHDR(output, expected: metadata)
        #expect(result.hasAudio)
        #expect(result.colorRange == "tv")
    }

    @Test(arguments: [(1080, 1920, 8_000_000), (2160, 3840, 30_000_000)])
    func portraitExportsRespectResolutionAndVideoBitrate(configuration: (Int, Int, Int)) async throws {
        let (width, height, maximumBitrate) = configuration
        let tools = try #require(FFmpegLocator.locate())
        let runner = FFmpegRunner(ffmpegURL: tools.ffmpeg, ffprobeURL: tools.ffprobe)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swifthdr-bitrate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.mp4")
        try run(tools.ffmpeg, [
            "-v", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc2=s=\(width)x\(height):r=30:d=1.5",
            "-c:v", "h264_videotoolbox", "-allow_sw", "0", "-b:v", "40M",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", input.path
        ])
        let metadata = try await runner.probe(input)
        let output = directory.appendingPathComponent("output.mp4")
        try await runner.convert(command: FFmpegCommandBuilder(
            inputURL: input, outputURL: output, metadata: metadata, preset: .dynamic
        )) { _ in }
        _ = try await runner.validateHDR(output, expected: metadata)

        let process = Process()
        let pipe = Pipe()
        process.executableURL = tools.ffprobe
        process.arguments = [
            "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=bit_rate",
            "-of", "default=noprint_wrappers=1:nokey=1", output.path
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let text = try #require(String(data: data, encoding: .utf8))
        let measuredBitrate = try #require(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(measuredBitrate > 0)
        #expect(measuredBitrate <= maximumBitrate)
    }

    @Test(arguments: [(640, 360), (641, 361)])
    func smallSilentVideosExportWithEvenDimensions(dimensions: (Int, Int)) async throws {
        let tools = try #require(FFmpegLocator.locate())
        let runner = FFmpegRunner(ffmpegURL: tools.ffmpeg, ffprobeURL: tools.ffprobe)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swifthdr-small-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (width, height) = dimensions
        let input = directory.appendingPathComponent("source.mov")
        try run(tools.ffmpeg, [
            "-v", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc=s=\(width)x\(height):r=24:d=0.5",
            "-c:v", "png", "-pix_fmt", "rgb24",
            "-color_primaries", "bt709", "-color_trc", "iec61966-2-1", input.path
        ])
        let metadata = try await runner.probe(input)
        let output = directory.appendingPathComponent("output.mp4")
        try await runner.convert(command: FFmpegCommandBuilder(
            inputURL: input, outputURL: output, metadata: metadata, preset: .natural
        )) { _ in }
        let result = try await runner.validateHDR(output, expected: metadata)
        #expect(!result.hasAudio)
        #expect(result.width == width + width % 2)
        #expect(result.height == height + height % 2)
    }

    @Test(arguments: HDRPreset.allCases)
    func whitePeakMatchesNominalNitsAndBlackStaysBlack(preset: HDRPreset) throws {
        let tools = try #require(FFmpegLocator.locate())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swifthdr-luminance-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = VideoMetadata(duration: 1, width: 64, height: 64, frameRate: 1, codec: "rawvideo", pixelFormat: "yuv420p", colorRange: "tv", colorSpace: "bt709", colorTransfer: "bt709", colorPrimaries: "bt709")
        let command = FFmpegCommandBuilder(inputURL: directory.appendingPathComponent("unused"), outputURL: directory.appendingPathComponent("unused.mp4"), metadata: metadata, preset: preset)

        for color in ["white", "black"] {
            let output = directory.appendingPathComponent("\(color).raw")
            try run(tools.ffmpeg, [
                "-v", "error", "-nostdin", "-f", "lavfi", "-i", "color=\(color):s=64x64:r=1:d=1",
                "-vf", command.filterGraph, "-frames:v", "1", "-f", "rawvideo", output.path
            ])
            let pixels = [UInt8](try Data(contentsOf: output))
            let meanY = stride(from: 0, to: 64 * 64 * 2, by: 2).reduce(0.0) {
                $0 + Double(UInt16(pixels[$1]) | (UInt16(pixels[$1 + 1]) << 8))
            } / Double(64 * 64)
            let signal = max(0, (meanY - 64) / 876)
            let linear = signal <= 0.5 ? signal * signal / 3 : (exp((signal - 0.55991073) / 0.17883277) + 0.28466892) / 12
            let nits = 1_000 * pow(linear, 1.2)
            if color == "white" {
                #expect(abs(nits - Double(preset.peakNits)) < 5)
            } else {
                #expect(nits < 0.01)
            }
        }
    }

    private func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        guard process.terminationStatus == 0 else {
            throw SwiftHDRError.conversionFailed("Test fixture process exited \(process.terminationStatus)")
        }
    }
}
