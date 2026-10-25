import Foundation

struct FFmpegCommandBuilder {
    let inputURL: URL
    let outputURL: URL
    let metadata: VideoMetadata
    let preset: HDRPreset

    private var videoBitrateMegabits: Int {
        let pixels = Double(metadata.width) * Double(metadata.height)
        let frameRate = metadata.frameRate.isFinite && metadata.frameRate > 0 ? metadata.frameRate : 30
        let megabits = pixels * frameRate * 0.12 / 1_000_000
        return Int(min(120, max(2, megabits.rounded(.up))))
    }

    var filterGraph: String {
        let inputRange = metadata.colorRange == "pc" ? "full" : "limited"
        let inputMatrix = Self.zscaleMatrix(for: metadata.colorSpace, primaries: metadata.colorPrimaries)
        let inputPrimaries = Self.zscalePrimaries(for: metadata.colorPrimaries, matrix: metadata.colorSpace)
        let inputTransfer = Self.zscaleTransfer(for: metadata.colorTransfer)

        let filters = [
            "pad=ceil(iw/2)*2:ceil(ih/2)*2",
            String(format: "eq=contrast=%.3f:saturation=%.3f:gamma=%.3f", preset.contrast, preset.saturation, preset.gamma),
            "curves=master='\(preset.masterCurve)'",
            "zscale=matrixin=\(inputMatrix):transferin=\(inputTransfer):primariesin=\(inputPrimaries):rangein=\(inputRange):matrix=gbr:transfer=linear:primaries=\(inputPrimaries):range=full:npl=100",
            "format=gbrpf32le",
            String(
                format: "colorchannelmixer=rr=%.3f:gg=%.3f:bb=%.3f",
                preset.hdrLinearScale,
                preset.hdrLinearScale,
                preset.hdrLinearScale
            ),
            "zscale=matrix=gbr:transfer=linear:primaries=bt2020:range=full:npl=100",
            "zscale=matrix=bt2020nc:transfer=arib-std-b67:primaries=bt2020:range=limited:npl=1000:dither=error_diffusion",
            "format=yuv420p10le"
        ]
        return filters.joined(separator: ",")
    }

    private static func zscaleMatrix(for value: String, primaries: String) -> String {
        switch value.lowercased() {
        case "bt470bg", "bt601", "bt601-pal": "bt470bg"
        case "smpte170m", "bt601-ntsc": "smpte170m"
        case "bt2020nc": "bt2020nc"
        case "bt709": "bt709"
        default:
            switch primaries.lowercased() {
            case "bt470bg", "bt601", "bt601-pal": "bt470bg"
            case "smpte170m", "bt601-ntsc": "smpte170m"
            case "bt2020": "bt2020nc"
            default: "bt709"
            }
        }
    }

    private static func zscalePrimaries(for value: String, matrix: String) -> String {
        switch value.lowercased() {
        case "bt470bg", "bt601", "bt601-pal": "bt470bg"
        case "smpte170m", "bt601-ntsc": "smpte170m"
        case "bt2020": "bt2020"
        case "bt709": "bt709"
        default:
            switch matrix.lowercased() {
            case "bt470bg", "bt601", "bt601-pal": "bt470bg"
            case "smpte170m", "bt601-ntsc": "smpte170m"
            case "bt2020", "bt2020nc": "bt2020"
            default: "bt709"
            }
        }
    }

    private static func zscaleTransfer(for value: String) -> String {
        switch value.lowercased() {
        case "iec61966-2-1": "iec61966-2-1"
        case "gamma28", "bt470bg": "bt470bg"
        case "smpte170m": "smpte170m"
        default: "bt709"
        }
    }

    var arguments: [String] {
        var args = [
            "-hide_banner", "-nostdin", "-n",
            "-i", inputURL.path,
            "-map", "0:v:0", "-map", "0:a?",
            "-vf", filterGraph,
            "-fps_mode", "passthrough"
        ]

        args += [
            "-c:v", "hevc_videotoolbox",
            "-profile:v", "main10",
            "-pix_fmt", "p010le",
            "-allow_sw", "0",
            "-b:v", "\(videoBitrateMegabits)M",
            "-maxrate", "\(videoBitrateMegabits)M",
            "-bufsize", "\(videoBitrateMegabits * 2)M"
        ]

        args += [
            "-tag:v", "hvc1",
            "-color_primaries", "bt2020",
            "-color_trc", "arib-std-b67",
            "-colorspace", "bt2020nc",
            "-color_range", "tv",
            "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
            "-movflags", "+faststart",
            "-avoid_negative_ts", "make_zero",
            "-progress", "pipe:1", "-nostats",
            outputURL.path
        ]
        return args
    }

}
