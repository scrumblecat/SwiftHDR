import Foundation

enum HDRPreset: String, CaseIterable, Identifiable, Sendable {
    case natural = "Natural"
    case dynamic = "Dynamic"
    case pro = "Pro"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .natural: "Subtle color lift"
        case .dynamic: "Richer color, with more light and depth"
        case .pro: "Fuller color and contrast for a stronger look"
        }
    }

    var peakNits: Int {
        switch self {
        case .natural: 400
        case .dynamic: 500
        case .pro: 600
        }
    }

    var saturation: Double {
        switch self {
        case .natural: 1.03
        case .dynamic: 1.06
        case .pro: 1.10
        }
    }

    var contrast: Double {
        switch self {
        case .natural: 1.00
        case .dynamic: 1.01
        case .pro: 1.02
        }
    }

    var gamma: Double { 1.00 }

    var masterCurve: String {
        switch self {
        case .natural:
            "0/0 0.10/0.10 0.35/0.35 0.65/0.65 0.85/0.85 1/1"
        case .dynamic:
            "0/0 0.10/0.10 0.35/0.35 0.65/0.66 0.85/0.86 1/1"
        case .pro:
            "0/0 0.10/0.10 0.35/0.34 0.65/0.67 0.85/0.87 1/1"
        }
    }

    var hdrLinearScale: Double { Double(peakNits) / 1_000 }
}

struct VideoMetadata: Codable, Equatable {
    let duration: Double
    let width: Int
    let height: Int
    let frameRate: Double
    let codec: String
    let pixelFormat: String
    let colorRange: String
    let colorSpace: String
    let colorTransfer: String
    let colorPrimaries: String
    let profile: String
    let codecTag: String
    let container: String
    let hasAudio: Bool
    let audioCodec: String
    let audioSampleRate: Int
    let audioChannels: Int

    init(
        duration: Double,
        width: Int,
        height: Int,
        frameRate: Double,
        codec: String,
        pixelFormat: String,
        colorRange: String,
        colorSpace: String,
        colorTransfer: String,
        colorPrimaries: String,
        profile: String = "unknown",
        codecTag: String = "unknown",
        container: String = "unknown",
        hasAudio: Bool = false,
        audioCodec: String = "unknown",
        audioSampleRate: Int = 0,
        audioChannels: Int = 0
    ) {
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.pixelFormat = pixelFormat
        self.colorRange = colorRange
        self.colorSpace = colorSpace
        self.colorTransfer = colorTransfer
        self.colorPrimaries = colorPrimaries
        self.profile = profile
        self.codecTag = codecTag
        self.container = container
        self.hasAudio = hasAudio
        self.audioCodec = audioCodec
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
    }

    var isHDR: Bool {
        colorTransfer == "arib-std-b67" || colorTransfer == "smpte2084"
    }

    var isTenBit: Bool {
        pixelFormat.contains("10") || pixelFormat.contains("p010") || profile.lowercased().contains("main 10")
    }

    var dimensions: String { "\(width)×\(height)" }
    var fpsLabel: String { String(format: "%.2f fps", frameRate) }
    var depthLabel: String { isTenBit ? "10-bit" : "8-bit" }
    var sourceColorLabel: String {
        let explicitTags = [colorPrimaries.lowercased(), colorSpace.lowercased()]
        if explicitTags.contains("bt470bg") { return "BT.601 PAL" }
        if explicitTags.contains("smpte170m") { return "BT.601 NTSC" }
        if explicitTags.contains("bt2020") || explicitTags.contains("bt2020nc") { return "BT.2020" }
        if explicitTags.contains("bt709") { return "BT.709" }

        return switch colorPrimaries.lowercased() {
        case "bt470bg": "BT.601 PAL"
        case "smpte170m": "BT.601 NTSC"
        case "bt2020": "BT.2020"
        case "bt709": "BT.709"
        case "unknown", "unspecified", "": "Untagged → BT.709"
        default: "\(colorPrimaries.uppercased()) → BT.709 fallback"
        }
    }
}

enum JobState: Equatable {
    case inspecting
    case ready
    case converting
    case complete
    case failed
    case cancelled

    var label: String {
        switch self {
        case .inspecting: "Inspecting"
        case .ready: "Ready"
        case .converting: "Converting"
        case .complete: "Complete"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

struct VideoJob: Identifiable {
    let id = UUID()
    let inputURL: URL
    var outputURL: URL?
    var metadata: VideoMetadata?
    var state: JobState = .inspecting
    var progress: Double = 0
    var detail: String = "Reading clip metadata…"
}

enum SwiftHDRError: LocalizedError {
    case ffmpegMissing
    case ffprobeMissing
    case invalidProbeOutput
    case unsupportedInput(String)
    case conversionFailed(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            "FFmpeg was not found. Install it with Homebrew: brew install ffmpeg-full"
        case .ffprobeMissing:
            "ffprobe was not found next to FFmpeg. Reinstall FFmpeg with Homebrew."
        case .invalidProbeOutput:
            "The clip metadata could not be read."
        case .unsupportedInput(let reason):
            reason
        case .conversionFailed(let reason):
            "Conversion failed: \(reason)"
        case .validationFailed(let reason):
            "The file was created but failed HDR verification: \(reason)"
        }
    }
}
