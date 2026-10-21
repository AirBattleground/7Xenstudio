// Phone game audio. HLS assets expose no audio track to AVFoundation (so MTAudioProcessingTap never attaches); instead an
// ffmpeg child reads the phone's stream from MediaMTX (loopback reads are allowed) and writes raw 48 kHz stereo float PCM,
// which goes straight into the mixer. The RTMP read is near-live, i.e. earlier than the decoded picture the Program shows (~100 ms later);
// the mixer delays phone inputs by the picture latency (AudioSettings.phoneLatencyMs) to line them up again.
import Foundation

final class PhoneAudioReader: @unchecked Sendable {
    private let args: [String]
    private let ffmpeg: String
    private let push: ([Float], [Float]) -> Void
    private let lock = NSLock()
    private var proc: Process?
    private var stopped = false
    private var thread: Thread?
    private(set) var bytesRead = 0
    private(set) var restarts = 0
    var onLog: ((String) -> Void)?

    /// `input` is any ffmpeg input (rtmp:// URL in production, a file in tests); `inputArgs` go before `-i` (e.g. ["-re"]).
    init(input: String, inputArgs: [String] = [], ffmpegPath: String, push: @escaping ([Float], [Float]) -> Void) {
        ffmpeg = ffmpegPath; self.push = push
        args = ["-nostdin", "-v", "error", "-fflags", "nobuffer", "-flags", "low_delay"] + inputArgs
            + ["-i", input, "-vn", "-af", "pan=stereo|FL=FL+FC|FR=FR+FC", "-ar", "48000",   // unity mono->stereo (plain -ac 2 would cost 3 dB)
                "-flush_packets", "1", "-f", "f32le", "pipe:1"]
    }
    static func rtmpURL(deviceId: String, port: Int) -> String { "rtmp://127.0.0.1:\(port)/live/dev_\(deviceId)" }

    func start() {
        let t = Thread { [weak self] in self?.loop() }
        t.name = "phone.audio.reader"; t.qualityOfService = .userInteractive
        lock.lock(); thread = t; lock.unlock()
        t.start()
    }
    func stop() {
        lock.lock(); stopped = true; let p = proc; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
    deinit { stop() }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func loop() {
        var backoff = 0.5
        while !isStopped {
            let began = Date()
            run()
            if isStopped { break }
            // stream absent (phone not publishing) exits at once: back off 0.5 s -> 5 s; a stream that ran a while retries fast
            backoff = Date().timeIntervalSince(began) > 10 ? 0.5 : min(5, backoff * 2)
            lock.lock(); restarts += 1; lock.unlock()
            var slept = 0.0
            while slept < backoff, !isStopped { Thread.sleep(forTimeInterval: 0.1); slept += 0.1 }
        }
    }

    private func run() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: ffmpeg); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        lock.lock(); if stopped { lock.unlock(); return }; proc = p; lock.unlock()
        do { try p.run() } catch { onLog?("ffmpeg launch failed: \(error)"); return }
        let fh = out.fileHandleForReading
        var carry = Data()
        while true {
            let d = fh.availableData
            if d.isEmpty { break }          // EOF: ffmpeg exited
            carry.append(d)
            let frames = carry.count / 8
            guard frames > 0 else { continue }
            var l = [Float](repeating: 0, count: frames), r = l
            carry.withUnsafeBytes { raw in
                let f = raw.bindMemory(to: Float.self)
                for i in 0..<frames { l[i] = f[2 * i]; r[i] = f[2 * i + 1] }
            }
            carry.removeSubrange(0..<(frames * 8))
            lock.lock(); bytesRead += frames * 8; lock.unlock()
            push(l, r)
        }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
    }
}
