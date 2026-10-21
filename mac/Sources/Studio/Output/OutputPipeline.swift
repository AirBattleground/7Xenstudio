import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Darwin

/// Frames in -> VideoToolbox (H.264, plus optional HEVC for the local file) + AAC -> own MPEG-TS mux -> ONE ffmpeg child
/// (`-c copy`, tee: fragmented MP4 recording + every RTMP destination with onfail=ignore + optional preview).
/// Render thread never blocks: submit(video:) only swaps a "latest frame" slot.
final class OutputPipeline: OutputPipelineProtocol, @unchecked Sendable {
    var onLog: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var _stats = OutputStats()
    var stats: OutputStats {
        lock.lock(); defer { lock.unlock() }
        var s = _stats
        s.droppedFrames = dropped
        s.encodeLatencyMs = h264?.meanLatencyMs ?? 0
        return s
    }

    var maxEncodeLatencyMs: Double { h264?.maxLatencyMs ?? 0 }
    private var config: OutputConfig?
    private var running = false
    private var h264: VideoEncoder?, hevc: VideoEncoder?
    private let audioEnc = AudioEncoder()
    private let ts = TSMuxer()
    private var proc: FFmpegChild?
    private var generation = 0, restartCount = 0, dropped = 0

    private let videoQ = DispatchQueue(label: "out.video", qos: .userInteractive)
    private let audioQ = DispatchQueue(label: "out.audio", qos: .userInitiated)
    private let muxQ = DispatchQueue(label: "out.mux", qos: .userInitiated)
    private let ctlQ = DispatchQueue(label: "out.ctl")

    // latest-wins slot
    private var slot: (CVPixelBuffer, CMTime)?
    private var drainScheduled = false
    private var basePTS: CMTime?          // engine timeline origin (first video or audio)
    private var lastFrameIndex: Int64 = -1
    private var needKey = true
    private var audioBacklog = 0
    private var lastRealAudio = 0.0       // wall clock
    private var startedWall = 0.0
    private var lastPSI = 0.0
    private var segment = 1
    private static let softBacklog = 4_000_000, hardBacklog = 16_000_000

    func start(_ config: OutputConfig) throws {
        guard FileManager.default.isExecutableFile(atPath: config.ffmpegPath) else { throw OutputError.ffmpegMissing(config.ffmpegPath) }
        self.config = config
        h264 = try VideoEncoder(codec: kCMVideoCodecType_H264, width: studioWidth, height: studioHeight, fps: config.fps, kbps: config.videoKbps)
        hevc = nil
        if config.recordHEVC && config.recordingURL != nil {
            hevc = try? VideoEncoder(codec: kCMVideoCodecType_HEVC, width: studioWidth, height: studioHeight, fps: config.fps, kbps: Int(Double(config.videoKbps) * 0.7))
        }
        h264?.onFrame = { [weak self] f in self?.muxQ.async { self?.emitVideo(f, pid: TSMuxer.videoPID) } }
        hevc?.onFrame = { [weak self] f in self?.muxQ.async { self?.emitVideo(f, pid: TSMuxer.hevcPID) } }
        audioEnc.onFrame = { [weak self] adts, pts in self?.muxQ.async { self?.emitAudio(adts, pts) } }
        lock.lock(); _stats = OutputStats(); dropped = 0; lock.unlock()
        basePTS = nil; lastFrameIndex = -1; needKey = true; slot = nil; segment = 1; restartCount = 0
        startedWall = Date().timeIntervalSince1970; lastRealAudio = 0
        running = true
        try launch()
    }

    // MARK: ffmpeg lifecycle

    private func launch() throws {
        guard let config else { return }
        var rec: String?
        if let r = config.recordingURL {
            if segment == 1 { rec = r.path } else {
                rec = r.deletingPathExtension().path + "-part\(segment)." + (r.pathExtension.isEmpty ? "mp4" : r.pathExtension)
            }
            try? FileManager.default.createDirectory(at: r.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let (args, labels) = FFmpegArgs.make(recording: rec, hevcRecording: hevc != nil, destinations: config.destinations, preview: config.previewURL,
                                           flvAACTag: config.destinations.isEmpty ? "0xa0" : FFmpegArgs.flvAACTag(ffmpeg: config.ffmpegPath))
        log("ffmpeg " + redactKeys(args.joined(separator: " ")))
        generation += 1
        let gen = generation
        let child = FFmpegChild(path: config.ffmpegPath, args: args, labels: labels)
        child.onSlaveFailure = { [weak self] label, err in
            guard let self else { return }
            self.lock.lock(); self._stats.destinationErrors[label] = err; self.lock.unlock()
            self.log("\(label) failed: \(err)")
        }
        child.onLine = { [weak self] l in self?.log("ffmpeg: " + l) }
        child.onExit = { [weak self] reason in self?.ffmpegExited(gen: gen, reason: reason) }
        try child.launch()
        muxQ.sync { ts.reset(); proc = child; lastPSI = 0 }
        needKey = true
        lock.lock(); _stats.error = nil; lock.unlock()
    }

    private func ffmpegExited(gen: Int, reason: String) {
        ctlQ.async {
            guard self.running, gen == self.generation else { return }
            self.muxQ.sync { self.proc = nil }
            self.restartCount += 1; self.segment += 1
            let healthy = Date().timeIntervalSince1970 - self.startedWall > 30
            if healthy { self.restartCount = 1 }
            self.startedWall = healthy ? Date().timeIntervalSince1970 : self.startedWall
            let delay = min(15.0, pow(2.0, Double(self.restartCount - 1)))
            self.lock.lock(); self._stats.error = reason; self._stats.restarts += 1; self.lock.unlock()
            self.log("ffmpeg exited (\(reason)); restarting in \(delay)s")
            self.ctlQ.asyncAfter(deadline: .now() + delay) {
                guard self.running, gen == self.generation else { return }
                do { try self.launch() } catch { self.ffmpegExited(gen: self.generation, reason: "\(error)") }
            }
        }
    }

    func stop() async {
        running = false
        videoQ.sync { slot = nil }
        h264?.flush(); hevc?.flush()
        audioQ.sync {}
        muxQ.sync {}
        let p = muxQ.sync { () -> FFmpegChild? in let p = proc; proc = nil; return p }
        if let p { await p.finish(grace: 5) }
        h264?.invalidate(); hevc?.invalidate(); h264 = nil; hevc = nil
    }

    // MARK: VideoSink

    func submit(video: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        if slot != nil { dropped += 1 }
        slot = (video, pts)
        let go = !drainScheduled; drainScheduled = true
        lock.unlock()
        if go { videoQ.async { [weak self] in self?.drain() } }
    }

    func submit(audio: CMSampleBuffer) {
        guard running else { return }
        lock.lock(); if audioBacklog > 300 { lock.unlock(); return }; audioBacklog += 1; lock.unlock()
        audioQ.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.audioBacklog -= 1; self.lock.unlock() }
            guard let pcm = self.audioEnc.pcm(from: audio) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(audio)
            let rel = self.relative(pts)
            self.lastRealAudio = Date().timeIntervalSince1970
            self.audioEnc.feed(pcm, pts: rel)
        }
    }

    private func relative(_ t: CMTime) -> Double {
        lock.lock(); defer { lock.unlock() }
        if basePTS == nil { basePTS = t }
        return CMTimeGetSeconds(CMTimeSubtract(t, basePTS!))
    }

    private func drain() {
        while true {
            lock.lock()
            guard let (pb, pts) = slot else { drainScheduled = false; lock.unlock(); return }
            slot = nil; lock.unlock()
            guard running, let enc = h264, let cfg = config else { continue }
            let rel = relative(pts)
            let idx = Int64((rel * Double(cfg.fps)).rounded())
            if idx <= lastFrameIndex { lock.lock(); dropped += 1; lock.unlock(); continue }   // strict CFR: one frame per slot
            let backlog = proc?.backlog ?? 0
            if backlog > OutputPipeline.softBacklog || enc.inFlight >= 4 || proc == nil {
                lock.lock(); dropped += 1; lock.unlock(); needKey = true; continue
            }
            lastFrameIndex = idx
            enc.encode(pb, frameIndex: idx, forceKey: needKey)
            hevc?.encode(pb, frameIndex: idx, forceKey: needKey)
            needKey = false
            // no mic? keep the AAC stream alive with silence so ffmpeg's probe and A/V sync never stall
            let now = Date().timeIntervalSince1970
            if now - lastRealAudio > 0.5 && now - startedWall > 0.5 {
                let until = rel
                audioQ.async { [weak self] in self?.audioEnc.feedSilence(until: until) }
            }
        }
    }

    // MARK: mux (muxQ)

    private func write(_ d: Data) {
        guard let p = proc else { return }
        if p.backlog > OutputPipeline.hardBacklog { needKey = true; return }
        if let dump = Self.dump { dump.write(d) }
        p.write(d)
    }
    /// debugging aid: STUDIO_DUMP_TS=/path/x.ts keeps a copy of the transport stream sent to ffmpeg
    private static let dump: FileHandle? = {
        guard let p = ProcessInfo.processInfo.environment["STUDIO_DUMP_TS"] else { return nil }
        FileManager.default.createFile(atPath: p, contents: nil); return FileHandle(forWritingAtPath: p)
    }()

    private func psiIfDue() {
        let now = Date().timeIntervalSince1970
        if now - lastPSI > 0.4 { lastPSI = now; write(ts.psi(hevc: hevc != nil)) }
    }

    // Rates are measured on what we hand to ffmpeg (stream copy => equals what goes out; ffmpeg's own total_size is lumpy
    // because fragmented MP4 only grows once per GOP). ffmpeg -progress is still parsed (FFmpegChild.meter) for liveness.
    private var rateBytes = 0, rateFrames = 0, rateSince = Date().timeIntervalSince1970

    private func sampleRates(bytes: Int, frame: Bool) {
        rateBytes += bytes; if frame { rateFrames += 1 }
        let now = Date().timeIntervalSince1970
        guard now - rateSince >= 1 else { return }
        let dt = now - rateSince
        lock.lock(); _stats.kbps = Double(rateBytes) * 8 / 1000 / dt; _stats.encodeFPS = Double(rateFrames) / dt; lock.unlock()
        rateBytes = 0; rateFrames = 0; rateSince = now
    }

    private func emitVideo(_ f: EncodedVideo, pid: Int) {
        if pid == TSMuxer.videoPID { sampleRates(bytes: f.annexB.count, frame: true) }
        psiIfDue()
        write(ts.video(annexB: f.annexB, pts: f.pts90k + 90000, keyframe: f.keyframe, pid: pid))
    }

    private func emitAudio(_ adts: Data, _ pts: UInt64) {
        sampleRates(bytes: adts.count, frame: false)
        psiIfDue()
        write(ts.audio(adts: adts, pts: pts + 90000))
    }

    private func log(_ s: String) { onLog?(redactKeys(s)) }
}

/// One ffmpeg process with a dedicated blocking stdin writer thread, progress parsing and stderr scanning.
final class FFmpegChild: @unchecked Sendable {
    let path: String, args: [String], labels: [String]
    var onProgress: ((ProgressMeter) -> Void)?
    var onSlaveFailure: ((String, String) -> Void)?
    var onLine: ((String) -> Void)?
    var onExit: ((String) -> Void)?
    private let process = Process()
    private let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    private let meter = ProgressMeter()
    private let cond = NSCondition()
    private var queue: [Data] = []
    private var queued = 0
    private var closing = false, dead = false
    private var lastErr = "", stopping = false
    private let exited = DispatchSemaphore(value: 0)

    init(path: String, args: [String], labels: [String]) { self.path = path; self.args = args; self.labels = labels }

    var backlog: Int { cond.lock(); defer { cond.unlock() }; return queued }

    func launch() throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardInput = inPipe; process.standardOutput = outPipe; process.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let txt = String(decoding: d, as: UTF8.self); if self.meter.feed(txt) { self.onProgress?(self.meter) }
        }
        var errBuf = ""
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            errBuf += String(decoding: d, as: UTF8.self)
            while let nl = errBuf.firstIndex(of: "\n") {
                let line = redactKeys(errBuf[..<nl].trimmingCharacters(in: .whitespaces)); errBuf.removeSubrange(...nl)
                if line.isEmpty { continue }
                self.lastErr = line
                if let f = parseSlaveFailure(line) { self.onSlaveFailure?(f.index < self.labels.count ? self.labels[f.index] : "output \(f.index)", f.error) }
                else if !self.stopping || ProcessInfo.processInfo.environment["STUDIO_FFLOG"] != nil { self.onLine?(line) }
            }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.cond.lock(); self.dead = true; self.queue = []; self.queued = 0; self.cond.broadcast(); self.cond.unlock()
            self.exited.signal()
            if !self.stopping {
                self.onExit?("ffmpeg stopped (\(p.terminationReason == .uncaughtSignal ? "signal" : "code") \(p.terminationStatus))" + (self.lastErr.isEmpty ? "" : ": " + self.lastErr))
            }
        }
        do { try process.run() } catch { throw OutputError.launch("\(error)") }
        let fd = inPipe.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let t = Thread { [weak self] in self?.writerLoop(fd) }
        t.name = "ffmpeg-stdin"; t.qualityOfService = .userInitiated; t.start()
    }

    func write(_ d: Data) {
        cond.lock()
        if !dead && !closing { queue.append(d); queued += d.count; cond.signal() }
        cond.unlock()
    }

    private func writerLoop(_ fd: Int32) {
        while true {
            cond.lock()
            while queue.isEmpty && !closing && !dead { cond.wait() }
            if dead || (queue.isEmpty && closing) { cond.unlock(); break }
            let d = queue.removeFirst(); queued -= d.count
            cond.unlock()
            let ok = d.withUnsafeBytes { raw -> Bool in
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                    if n < 0 { if errno == EINTR { continue }; if errno == EAGAIN { var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0); poll(&p, 1, 1000); continue }; self.onLine?("stdin write failed errno \(errno)"); return false }
                    off += n
                }
                return true
            }
            if !ok { cond.lock(); dead = true; queue = []; queued = 0; cond.unlock(); break }
        }
        try? inPipe.fileHandleForWriting.close()
    }

    /// Drain, close stdin so ffmpeg finalises the outputs, then kill after `grace` seconds.
    func finish(grace: Double) async {
        stopping = true
        cond.lock(); closing = true; cond.broadcast(); cond.unlock()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                if self.exited.wait(timeout: .now() + grace) == .timedOut {
                    self.process.interrupt()
                    if self.exited.wait(timeout: .now() + 2) == .timedOut { kill(self.process.processIdentifier, SIGKILL); _ = self.exited.wait(timeout: .now() + 2) }
                }
                c.resume()
            }
        }
    }
}
