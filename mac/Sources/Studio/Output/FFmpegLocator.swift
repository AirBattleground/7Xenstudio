import Foundation

/// Finds an ffmpeg binary: FFMPEG_PATH env, one bundled in the app (Contents/MacOS, Resources, Helpers), then Homebrew / system paths.
enum FFmpegLocator {
    static func candidates(bundle: Bundle = .main, env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var list: [String] = []
        if let p = env["FFMPEG_PATH"], !p.isEmpty { list.append(p) }
        if let r = bundle.resourceURL { list.append(r.appendingPathComponent("ffmpeg").path) }
        if let e = bundle.executableURL?.deletingLastPathComponent() { list.append(e.appendingPathComponent("ffmpeg").path) }
        list.append(bundle.bundlePath + "/Contents/Helpers/ffmpeg")
        list += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return list
    }

    /// First executable candidate, or nil when ffmpeg is not installed.
    static func locate(bundle: Bundle = .main, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        candidates(bundle: bundle, env: env).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Sibling ffprobe of an ffmpeg path, if present.
    static func ffprobe(besides ffmpeg: String) -> String? {
        let p = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
}
