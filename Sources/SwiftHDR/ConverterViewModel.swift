import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ConverterViewModel: ObservableObject {
    @Published var jobs: [VideoJob] = []
    @Published var preset: HDRPreset = .dynamic
    @Published var outputFolder: URL?
    @Published var isCheckingTools = true
    @Published var isConverting = false
    @Published var ffmpegStatus = "Checking FFmpeg…"
    @Published var ffmpegAvailable = false
    @Published var hardwareEncoderAvailable = false
    @Published var isDropTargeted = false

    private var runner: FFmpegRunner?
    private var conversionTask: Task<Void, Never>?

    init() {
        refreshFFmpeg()
    }

    var readyCount: Int { jobs.filter { $0.state == .ready }.count }
    var canConvert: Bool { readyCount > 0 && ffmpegAvailable && hardwareEncoderAvailable && !isCheckingTools && !isConverting }

    func refreshFFmpeg() {
        guard !isConverting else { return }
        isCheckingTools = true
        hardwareEncoderAvailable = false
        guard let tools = FFmpegLocator.locate() else {
            isCheckingTools = false
            ffmpegAvailable = false
            ffmpegStatus = "FFmpeg not installed"
            runner = nil
            return
        }

        let runner = FFmpegRunner(ffmpegURL: tools.ffmpeg, ffprobeURL: tools.ffprobe)
        self.runner = runner
        ffmpegAvailable = false
        ffmpegStatus = "Checking FFmpeg…"

        for index in jobs.indices where jobs[index].metadata == nil {
            jobs[index].state = .inspecting
            jobs[index].detail = "Reading clip metadata…"
            inspect(jobID: jobs[index].id)
        }

        Task {
            let hasFilter = await runner.supportsFilter("zscale")
            let hasHardware = await runner.supportsHardwareEncoding()
            guard self.runner === runner else { return }
            ffmpegAvailable = hasFilter
            hardwareEncoderAvailable = hasHardware
            isCheckingTools = false
            if !hasFilter {
                ffmpegStatus = "FFmpeg needs the zscale filter"
            } else if !hasHardware {
                ffmpegStatus = "Apple HEVC hardware is unavailable"
            } else {
                ffmpegStatus = "Ready"
            }
        }
    }

    func chooseInputFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add videos"
        panel.allowedContentTypes = [.mpeg4Movie, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose HDR output folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return }
        outputFolder = panel.url
    }

    func addFiles(_ urls: [URL]) {
        let existing = Set(jobs.map { $0.inputURL.standardizedFileURL })
        let newURLs = urls
            .map(\.standardizedFileURL)
            .filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
            .filter { !existing.contains($0) }

        for url in newURLs {
            let job = VideoJob(inputURL: url)
            jobs.append(job)
            inspect(jobID: job.id)
        }
    }

    func remove(_ id: UUID) {
        guard !isConverting else { return }
        jobs.removeAll { $0.id == id }
    }

    func clearFinished() {
        guard !isConverting else { return }
        jobs.removeAll { [.complete, .failed, .cancelled].contains($0.state) }
    }

    func startConversion() {
        guard canConvert, let runner else { return }
        isConverting = true
        let selectedPreset = preset

        conversionTask = Task { [weak self] in
            guard let self else { return }
            let queuedIDs = jobs.filter { $0.state == .ready }.map(\.id)

            for id in queuedIDs {
                guard !Task.isCancelled else { break }
                guard let index = jobs.firstIndex(where: { $0.id == id }),
                      let metadata = jobs[index].metadata else { continue }

                let output = uniqueOutputURL(for: jobs[index].inputURL)
                let temporary: (file: URL, directory: URL)
                do {
                    temporary = try makeTemporaryOutput(nextTo: output)
                } catch {
                    jobs[index].state = .failed
                    jobs[index].detail = "Could not create a temporary output: \(error.localizedDescription)"
                    continue
                }
                jobs[index].outputURL = output
                jobs[index].state = .converting
                jobs[index].progress = 0
                jobs[index].detail = "Encoding Rec. 2100 HLG…"

                let command = FFmpegCommandBuilder(
                    inputURL: jobs[index].inputURL,
                    outputURL: temporary.file,
                    metadata: metadata,
                    preset: selectedPreset
                )

                do {
                    try await runner.convert(command: command) { [weak self] value in
                        Task { @MainActor in
                            guard let self, let current = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                            self.jobs[current].progress = value
                        }
                    }
                    _ = try await runner.validateHDR(temporary.file, expected: metadata)
                    try FileManager.default.moveItem(at: temporary.file, to: output)
                    try FileManager.default.removeItem(at: temporary.directory)
                    if let current = jobs.firstIndex(where: { $0.id == id }) {
                        jobs[current].state = .complete
                        jobs[current].progress = 1
                        jobs[current].detail = "Verified: HEVC Main 10 · Rec. 2020 · HLG"
                    }
                } catch is CancellationError {
                    if let current = jobs.firstIndex(where: { $0.id == id }) {
                        jobs[current].state = .cancelled
                        jobs[current].detail = "Cancelled"
                    }
                    try? FileManager.default.removeItem(at: temporary.directory)
                    break
                } catch {
                    if let current = jobs.firstIndex(where: { $0.id == id }) {
                        jobs[current].state = .failed
                        jobs[current].detail = error.localizedDescription
                    }
                    try? FileManager.default.removeItem(at: temporary.directory)
                }
            }

            isConverting = false
            conversionTask = nil
        }
    }

    func cancelConversion() {
        conversionTask?.cancel()
        runner?.cancel()
    }

    func reveal(_ job: VideoJob) {
        guard let output = job.outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([output])
    }

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install ffmpeg-full", forType: .string)
    }

    private func inspect(jobID: UUID) {
        guard let runner, let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            if let index = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[index].state = .failed
                jobs[index].detail = SwiftHDRError.ffmpegMissing.localizedDescription
            }
            return
        }
        let url = jobs[index].inputURL

        Task {
            do {
                let metadata = try await runner.probe(url)
                guard let current = jobs.firstIndex(where: { $0.id == jobID }) else { return }
                jobs[current].metadata = metadata

                if metadata.isHDR {
                    jobs[current].state = .failed
                    jobs[current].detail = "This clip is already tagged HDR; use a tagged SDR export."
                } else if metadata.width < 2 || metadata.height < 2 {
                    jobs[current].state = .failed
                    jobs[current].detail = "The video must be at least 2 pixels wide and tall."
                } else {
                    jobs[current].state = .ready
                    jobs[current].detail = "\(metadata.codec.uppercased()) · \(metadata.depthLabel) · \(metadata.sourceColorLabel) · \(metadata.dimensions) · \(metadata.fpsLabel)"
                }
            } catch {
                guard let current = jobs.firstIndex(where: { $0.id == jobID }) else { return }
                jobs[current].state = .failed
                jobs[current].detail = error.localizedDescription
            }
        }
    }

    private func uniqueOutputURL(for input: URL) -> URL {
        let folder = outputFolder ?? input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent + "_HDR_HLG"
        var candidate = folder.appendingPathComponent(stem).appendingPathExtension("mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-\(counter)").appendingPathExtension("mp4")
            counter += 1
        }
        return candidate
    }

    private func makeTemporaryOutput(nextTo output: URL) throws -> (file: URL, directory: URL) {
        let manager = FileManager.default
        let folder = output.deletingLastPathComponent()

        for _ in 0..<10 {
            let directory = folder.appendingPathComponent(".swifthdr-\(UUID().uuidString)", isDirectory: true)
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: false)
                return (directory.appendingPathComponent("output.mp4"), directory)
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }

        throw CocoaError(.fileWriteFileExists)
    }
}
