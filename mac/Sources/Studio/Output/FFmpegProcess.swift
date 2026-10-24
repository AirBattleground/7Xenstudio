import Foundation

/// ffmpeg stderr line safe to log: stream keys after the RTMP app name are cut off.
func redactKeys(_ s: String) -> String {
    s.replacingOccurrences(of: #"(rtmps?://[^/\s]+/[^/\s?']+/)[^\s'|\]:]+"#, with: "$1…", options: .regularExpression)
}

/// "Slave muxer #1 failed: Connection refused, continuing with 1/2 slaves." -> (1, "Connection refused")
func parseSlaveFailure(_ line: String) -> (index: Int, error: String)? {
    guard let r = line.range(of: #"Slave muxer #(\d+) failed"#, options: .regularExpression) else { return nil }
    let head = String(line[r])
    let idx = Int(head.filter(\.isNumber)) ?? -1
    var rest = String(line[r.upperBound...])
    if rest.hasPrefix(":") { rest.removeFirst() }
    if let c = rest.range(of: ", continuing with") { rest = String(rest[..<c.lowerBound]) }
    rest = rest.trimmingCharacters(in: .whitespaces)
    return (idx, rest.isEmpty ? "failed" : rest)
}

/// Parses `ffmpeg -progress pipe:1` blocks into kbps / fps.
final class ProgressMeter {
    private var buf = "", block: [String: String] = [:]
    private var last: (bytes: Double, at: Double)?, lastFrame: (frame: Double, at: Double)?
    private let now: () -> Double
    var kbps: Double?, fps: Double?, outSeconds = 0.0
    init(now: @escaping () -> Double = { Date().timeIntervalSince1970 }) { self.now = now }

    @discardableResult func feed(_ text: String) -> Bool {
        buf += text
        var done = false
        while let nl = buf.firstIndex(of: "\n") {
            let line = buf[..<nl].trimmingCharacters(in: .whitespaces)
            buf.removeSubrange(...nl)
            guard let eq = line.firstIndex(of: "=") else { continue }
            block[String(line[..<eq])] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("progress=") { finish(); done = true }
        }
        return done
    }

    private func finish() {
        let b = block; block = [:]
        let at = now()
        if let us = Double(b["out_time_us"] ?? b["out_time_ms"] ?? ""), us > 0 { outSeconds = us / 1e6 }
        if let f = Double(b["frame"] ?? "") {
            if let l = lastFrame, at > l.at, f >= l.frame { fps = ((f - l.frame) / (at - l.at) * 10).rounded() / 10 }
            lastFrame = (f, at)
        }
        if let by = Double(b["total_size"] ?? ""), by >= 0 {
            if let l = last, at > l.at, by >= l.bytes { kbps = ((by - l.bytes) * 8 / 1000 / (at - l.at)).rounded() }
            last = (by, at)
        }
    }
}

enum FFmpegArgs {
    struct Slave { var spec: String; var label: String }

    /// Escape one URL/path for the tee muxer slave list.
    static func escapeTee(_ s: String) -> String {
        var o = ""
        for c in s { if "\\'|[]".contains(c) { o.append("\\") }; o.append(c) }
        return o
    }

    static func rtmpURL(_ d: Destination) -> String {
        let base = d.url.hasSuffix("/") ? String(d.url.dropLast()) : d.url
        return d.key.isEmpty ? base : base + "/" + d.key
    }

    private static let tagLock = NSLock()
    nonisolated(unsafe) private static var tagCache: [String: String] = [:]
    /// The FLV AAC codec tag differs between ffmpeg builds (older: 0xa0 = 10 << 4, newer incl. 9.x: 10); a wrong value makes the
    /// flv muxer refuse the header, which kills the whole ffmpeg (recording included). Probe once per binary.
    static func flvAACTag(ffmpeg: String) -> String {
        tagLock.lock(); if let t = tagCache[ffmpeg] { tagLock.unlock(); return t }; tagLock.unlock()
        var result = "0xa0"
        for cand in ["10", "0xa0"] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-v", "quiet", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-t", "0.05", "-c:a", "aac", "-tag:a", cand, "-f", "flv", "-y", "/dev/null"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { p.waitUntilExit(); if p.terminationStatus == 0 { result = cand; break } }
        }
        tagLock.lock(); tagCache[ffmpeg] = result; tagLock.unlock()
        return result
    }

    /// Strictly a stream-copy muxer: VideoToolbox's bitstream is final. Outputs, in order:
    ///  1. recording: plain fragmented-MP4 output (its own codec tags: avc1/hvc1 + mp4a)
    ///  2. a tee of every RTMP(S) destination with onfail=ignore (one dead key never stops the others)
    ///  3. optional preview
    /// Why the recording is NOT a tee slave: tee copies the TS demuxer's codec tags (27/15) to every slave and MP4 and FLV
    /// accept different tags (avc1 vs 7), so no single `-tag` satisfies both; separate outputs each get the right tag.
    /// With `hevcRecording` the TS carries a second video stream (v:1, HEVC) used only by the recording.
    /// `labels` name the tee slaves (index = "Slave muxer #n").
    static func make(recording: String?, hevcRecording: Bool, destinations: [Destination], preview: String?, flvAACTag: String = "0xa0") -> (args: [String], labels: [String]) {
        var a = ["-hide_banner", "-loglevel", ProcessInfo.processInfo.environment["STUDIO_FFLOG"] ?? "warning", "-nostats", "-y",
                 "-probesize", "2000000", "-analyzeduration", "1000000",
                 "-f", "mpegts", "-i", "pipe:0",
                 "-progress", "pipe:1", "-stats_period", "1"]
        let common = ["-c", "copy", "-bsf:a", "aac_adtstoasc", "-flush_packets", "1", "-flags", "+global_header"]
        var any = false
        if let r = recording {
            a += ["-map", hevcRecording ? "0:v:1" : "0:v:0", "-map", "0:a:0"] + common
            if hevcRecording { a += ["-tag:v", "hvc1"] }
            // NOT empty_moov: that writes the moov before the first packet, i.e. before aac_adtstoasc has produced the
            // AudioSpecificConfig, so the esds had no decoder config (mp4a.40.0): QuickTime / AVFoundation dropped the audio track
            // entirely and other players had to guess. Without it the moov goes out with the first fragment (one GOP later).
            a += ["-f", "mp4", "-movflags", "+frag_keyframe+default_base_moof", r]
            any = true
        }
        var labels: [String] = []
        if !destinations.isEmpty {
            let slaves = destinations.map { "[f=flv:onfail=ignore:flvflags=no_duration_filesize]" + escapeTee(rtmpURL($0)) }
            labels = destinations.map(\.name)
            // FLV wants tag 7 (H.264) / 0xA0 (AAC)
            a += ["-map", "0:v:0", "-map", "0:a:0"] + common + ["-tag:v", "7", "-tag:a", flvAACTag, "-f", "tee", slaves.joined(separator: "|")]
            any = true
        }
        if let p = preview {
            a += ["-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-f", p.hasPrefix("rtmp") ? "flv" : "mpegts", p]
            any = true
        }
        if !any { a += ["-f", "null", "-"] }
        return (a, labels)
    }
}
