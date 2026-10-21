// Operator headphone feed: plays the mixer's monitor bus through a chosen output device (separate from the broadcast path).
import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import os

final class MonitorOutput {
    private var engine: AVAudioEngine?
    private let lock = OSAllocatedUnfairLock()
    private let cap = 48_000
    private var l = [Float](repeating: 0, count: 48_000), r = [Float](repeating: 0, count: 48_000)
    private var rd = 0, count = 0, primed = false
    private let prebuffer = 3_840          // 80 ms
    private let maxFill = 9_600            // 200 ms: beyond this trim back (clock drift)
    private var observer: NSObjectProtocol?
    private(set) var deviceUID: String?
    private(set) var running = false
    var onConfigChange: (() -> Void)?

    deinit { stop() }

    /// Called by the mixer for each rendered block (any thread).
    func write(_ pl: UnsafePointer<Float>, _ pr: UnsafePointer<Float>, _ n: Int) {
        guard running else { return }
        lock.withLock {
            if count + n > maxFill {                       // too far behind the output clock: drop the oldest audio
                let drop = count + n - prebuffer * 2
                if drop > 0 { let d = min(drop, count); rd = (rd + d) % cap; count -= d }
            }
            var w = (rd + count) % cap
            for i in 0..<n { l[w] = pl[i]; r[w] = pr[i]; w += 1; if w == cap { w = 0 } }
            count += n
        }
    }

    private func pull(_ frames: Int, _ abl: UnsafeMutableAudioBufferListPointer) {
        guard abl.count >= 2, let ol = abl[0].mData?.assumingMemoryBound(to: Float.self), let or = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        lock.withLock {
            if !primed { if count >= prebuffer { primed = true } }
            for i in 0..<frames {
                if primed && count > 0 { ol[i] = l[rd]; or[i] = r[rd]; rd += 1; if rd == cap { rd = 0 }; count -= 1 }
                else { ol[i] = 0; or[i] = 0; if primed { primed = false } }
            }
        }
    }

    /// Starts on the device with this UID (nil = system default output).
    func start(deviceUID uid: String?) throws {
        stop()
        let e = AVAudioEngine()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let node = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frames, abl -> OSStatus in
            self.pull(Int(frames), UnsafeMutableAudioBufferListPointer(abl)); return noErr
        }
        e.attach(node); e.connect(node, to: e.mainMixerNode, format: fmt)
        if let uid {
            guard let dev = AudioDevices.device(uid: uid), dev.hasOutput else { throw NSError(domain: "Monitor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Output device is not connected"]) }
            var id = dev.id
            if let au = e.outputNode.audioUnit {
                let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
                if st != noErr { throw NSError(domain: "Monitor", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "Could not select \(dev.name) (\(st))"]) }
            }
        }
        lock.withLock { rd = 0; count = 0; primed = false }
        e.prepare()
        try e.start()
        engine = e; deviceUID = uid; running = true
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in self?.onConfigChange?() }
    }

    func stop() {
        running = false
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        engine?.stop(); engine = nil
    }
}
