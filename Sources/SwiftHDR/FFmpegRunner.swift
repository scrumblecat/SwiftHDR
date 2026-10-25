import Foundation

final class FFmpegLocator {
    static func locate() -> (ffmpeg: URL, ffprobe: URL)? {
        let manager = FileManager.default
        var candidates: [URL] = []

        if let bundled = Bundle.main.resourceURL {
            candidates.append(bundled.appendingPathComponent("ffmpeg"))
        }

        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/opt/ffmpeg-full/bin/ffmpeg"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/bin/ffmpeg")
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("ffmpeg")
            }
        }

        for ffmpeg in candidates where manager.isExecutableFile(atPath: ffmpeg.path) {
            let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
            if manager.isExecutableFile(atPath: ffprobe.path) {
                return (ffmpeg, ffprobe)
            }
        }
        return nil
    }
}

private struct ProbeDocument: Decodable {
    struct Stream: Decodable {
        let codec_type: String?
        let codec_name: String?
        let profile: String?
        let codec_tag_string: String?
        let width: Int?
        let height: Int?
        let pix_fmt: String?
        let color_range: String?
        let color_space: String?
        let color_transfer: String?
        let color_primaries: String?
        let avg_frame_rate: String?
        let duration: String?
        let sample_rate: String?
        let channels: Int?
    }

    struct Format: Decodable {
        let duration: String?
        let format_name: String?
    }
    let streams: [Stream]
    let format: Format?
}

final class FFmpegRunner: @unchecked Sendable {
    private let ffmpegURL: URL
    private let ffprobeURL: URL
    private let lock = NSLock()
    private var activeProcess: Process?
    private var cancellationRequested = false

    init(ffmpegURL: URL, ffprobeURL: URL) {
        self.ffmpegURL = ffmpegURL
        self.ffprobeURL = ffprobeURL
    }

    func probe(_ url: URL) async throws -> VideoMetadata {
        try await Task.detached(priority: .userInitiated) { [ffprobeURL] in
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = ffprobeURL
            process.arguments = [
                "-v", "error",
                "-show_entries", "stream=codec_type,codec_name,profile,codec_tag_string,width,height,pix_fmt,color_range,color_space,color_transfer,color_primaries,avg_frame_rate,duration,sample_rate,channels:format=duration,format_name",
                "-of", "json", url.path
            ]
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            process.waitUntilExit()

            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ffprobe failed"
                throw SwiftHDRError.conversionFailed(message.trimmedForDisplay)
            }

            let document = try JSONDecoder().decode(ProbeDocument.self, from: data)
            guard let stream = document.streams.first(where: { $0.codec_type == "video" }),
                  let width = stream.width, let height = stream.height else {
                throw SwiftHDRError.invalidProbeOutput
            }
            let audio = document.streams.first(where: { $0.codec_type == "audio" })

            let duration = Double(stream.duration ?? "") ?? Double(document.format?.duration ?? "") ?? 0
            return VideoMetadata(
                duration: duration,
                width: width,
                height: height,
                frameRate: Self.parseFrameRate(stream.avg_frame_rate),
                codec: stream.codec_name ?? "unknown",
                pixelFormat: stream.pix_fmt ?? "unknown",
                colorRange: stream.color_range ?? "unknown",
                colorSpace: stream.color_space ?? "unknown",
                colorTransfer: stream.color_transfer ?? "unknown",
                colorPrimaries: stream.color_primaries ?? "unknown",
                profile: stream.profile ?? "unknown",
                codecTag: stream.codec_tag_string ?? "unknown",
                container: document.format?.format_name ?? "unknown",
                hasAudio: audio != nil,
                audioCodec: audio?.codec_name ?? "unknown",
                audioSampleRate: Int(audio?.sample_rate ?? "") ?? 0,
                audioChannels: audio?.channels ?? 0
            )
        }.value
    }

    func supportsHardwareEncoding() async -> Bool {
        (try? await Task.detached(priority: .utility) { [ffmpegURL] in
            let process = Process()
            process.executableURL = ffmpegURL
            process.arguments = [
                "-hide_banner", "-loglevel", "error", "-nostdin",
                "-f", "lavfi", "-i", "color=black:s=64x64:r=1",
                "-frames:v", "1", "-an",
                "-c:v", "hevc_videotoolbox", "-profile:v", "main10",
                "-pix_fmt", "p010le", "-allow_sw", "0",
                "-f", "null", "-"
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value) ?? false
    }

    func supportsFilter(_ name: String) async -> Bool {
        (try? await Task.detached(priority: .utility) { [ffmpegURL] in
            let process = Process()
            let output = Pipe()
            process.executableURL = ffmpegURL
            process.arguments = ["-hide_banner", "-filters"]
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return process.terminationStatus == 0 && text
                .split(separator: "\n")
                .contains { $0.split(whereSeparator: { $0.isWhitespace }).dropFirst().first == Substring(name) }
        }.value) ?? false
    }

    func convert(
        command: FFmpegCommandBuilder,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let duration = max(command.metadata.duration, 0.001)
        resetCancellation()
        try Task.checkCancellation()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let progressPipe = Pipe()
            let errorPipe = Pipe()
            let parser = FFmpegProgressParser(duration: duration, callback: progress)
            let errors = LockedTextBuffer()

            process.executableURL = ffmpegURL
            process.arguments = command.arguments
            process.standardOutput = progressPipe
            process.standardError = errorPipe

            progressPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                parser.consume(data)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                errors.append(text)
            }

            process.terminationHandler = { [weak self] finished in
                progressPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let wasCancelled = self?.finishProcess() ?? false

                if wasCancelled || finished.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: CancellationError())
                } else if finished.terminationStatus == 0 {
                    progress(1)
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SwiftHDRError.conversionFailed(errors.value.trimmedForDisplay))
                }
            }

            do {
                setActiveProcess(process)
                if isCancellationRequested || Task.isCancelled {
                    setActiveProcess(nil)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                try process.run()
                if isCancellationRequested { process.terminate() }
            } catch {
                setActiveProcess(nil)
                if isCancellationRequested {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = activeProcess
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    func validateHDR(_ url: URL, expected: VideoMetadata) async throws -> VideoMetadata {
        let metadata = try await probe(url)
        var problems: [String] = []
        if metadata.codec != "hevc" { problems.append("codec is \(metadata.codec), expected HEVC") }
        if !metadata.profile.lowercased().contains("main 10") { problems.append("profile is \(metadata.profile), expected Main 10") }
        if !metadata.isTenBit || !(metadata.pixelFormat.contains("420") || metadata.pixelFormat.contains("p010")) {
            problems.append("pixel format is \(metadata.pixelFormat), expected 10-bit 4:2:0")
        }
        if metadata.codecTag != "hvc1" { problems.append("codec tag is \(metadata.codecTag), expected hvc1") }
        if metadata.colorPrimaries != "bt2020" { problems.append("primaries are \(metadata.colorPrimaries), expected BT.2020") }
        if metadata.colorTransfer != "arib-std-b67" { problems.append("transfer is \(metadata.colorTransfer), expected HLG") }
        if metadata.colorSpace != "bt2020nc" { problems.append("matrix is \(metadata.colorSpace), expected BT.2020 non-constant") }
        if !metadata.container.split(separator: ",").contains("mp4") { problems.append("container is \(metadata.container), expected MP4") }
        if metadata.width != expected.width + expected.width % 2 || metadata.height != expected.height + expected.height % 2 {
            problems.append("resolution is \(metadata.dimensions), expected \(expected.width + expected.width % 2)×\(expected.height + expected.height % 2)")
        }
        if expected.frameRate > 0 && abs(metadata.frameRate - expected.frameRate) > 0.01 {
            problems.append("frame rate is \(metadata.fpsLabel), expected \(expected.fpsLabel)")
        }
        if expected.duration > 0 {
            let durationTolerance = max(0.20, expected.frameRate > 0 ? 2 / expected.frameRate : 0)
            if abs(metadata.duration - expected.duration) > durationTolerance {
                problems.append(String(format: "duration is %.3fs, expected %.3fs", metadata.duration, expected.duration))
            }
        }
        if expected.hasAudio {
            if !metadata.hasAudio { problems.append("audio stream is missing") }
            if metadata.audioCodec != "aac" { problems.append("audio codec is \(metadata.audioCodec), expected AAC") }
            if metadata.audioSampleRate != 48_000 { problems.append("audio sample rate is \(metadata.audioSampleRate) Hz, expected 48000 Hz") }
            if expected.audioChannels > 0 && metadata.audioChannels != expected.audioChannels {
                problems.append("audio has \(metadata.audioChannels) channels, expected \(expected.audioChannels)")
            }
        }
        guard problems.isEmpty else { throw SwiftHDRError.validationFailed(problems.joined(separator: "; ")) }
        return metadata
    }

    private func setActiveProcess(_ process: Process?) {
        lock.lock()
        activeProcess = process
        lock.unlock()
    }

    private var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    private func resetCancellation() {
        lock.lock()
        cancellationRequested = false
        lock.unlock()
    }

    private func finishProcess() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        activeProcess = nil
        return cancellationRequested
    }

    private static func parseFrameRate(_ value: String?) -> Double {
        guard let value else { return 0 }
        let parts = value.split(separator: "/")
        if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 {
            return numerator / denominator
        }
        return Double(value) ?? 0
    }
}

private final class FFmpegProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let duration: Double
    private let callback: @Sendable (Double) -> Void

    init(duration: Double, callback: @escaping @Sendable (Double) -> Void) {
        self.duration = duration
        self.callback = callback
    }

    func consume(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        buffer += chunk
        let lines = buffer.components(separatedBy: .newlines)
        buffer = lines.last ?? ""
        lock.unlock()

        for line in lines.dropLast() {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let seconds: Double?
            if pair[0] == "out_time_us" || pair[0] == "out_time_ms" {
                seconds = Double(pair[1]).map { $0 / 1_000_000 }
            } else if pair[0] == "out_time" {
                seconds = Self.timecodeToSeconds(pair[1])
            } else {
                seconds = nil
            }
            if let seconds {
                callback(min(max(seconds / duration, 0), 0.999))
            }
        }
    }

    private static func timecodeToSeconds(_ value: String) -> Double? {
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

private final class LockedTextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        if storage.count > 40_000 { storage.removeFirst(storage.count - 40_000) }
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private extension String {
    var trimmedForDisplay: String {
        let lines = split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(12).joined(separator: "\n")
    }
}
