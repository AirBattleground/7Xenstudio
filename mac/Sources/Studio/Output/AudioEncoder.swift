import Foundation
import AVFoundation
import CoreMedia

/// PCM CMSampleBuffers -> AAC-LC 48 kHz stereo 192 kbps, emitted as ADTS frames with 90 kHz PTS.
/// Not thread-safe: drive from one serial queue.
final class AudioEncoder {
    static let sampleRate = 48000.0
    static let bitRate = 192_000
    var onFrame: ((Data, UInt64) -> Void)?   // adts, pts90k (relative seconds already offset by caller)
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000.0,
                                                     AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])!
    private var pending: [AVAudioPCMBuffer] = []
    private var outPTS: Double? = nil        // seconds for the next AAC packet
    private var expectedIn: Double? = nil    // where the next input buffer should start
    private(set) var lastOut = -1.0
    var silentNext: Double = 0

    func pcm(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
              let fmt = AVAudioFormat(streamDescription: asbd) else { return nil }
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
    }

    /// `pts` = seconds on the pipeline timeline.
    func feed(_ buf: AVAudioPCMBuffer, pts: Double) {
        if converter == nil || inFormat != buf.format {
            converter = AVAudioConverter(from: buf.format, to: outFormat)
            converter?.bitRate = 192_000
            inFormat = buf.format; pending = []
        }
        let dur = Double(buf.frameLength) / buf.format.sampleRate
        if outPTS == nil || abs(pts - (expectedIn ?? pts)) > 0.1 {
            outPTS = max(pts, lastOut + 1024 / AudioEncoder.sampleRate)
        }
        expectedIn = pts + dur
        pending.append(buf)
        drain()
    }

    /// Feed digital silence from `silentNext` up to `until` (keeps ffmpeg's audio stream alive when no mic is present).
    func feedSilence(until: Double) {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        silentNext = max(silentNext, lastOut + 1024 / AudioEncoder.sampleRate)
        while silentNext < until {
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024)!
            b.frameLength = 1024
            for c in 0..<2 { memset(b.floatChannelData![c], 0, 1024 * 4) }
            feed(b, pts: silentNext)
            silentNext += 1024 / 48000
        }
    }

    private func drain() {
        guard let converter else { return }
        while true {
            let out = AVAudioCompressedBuffer(format: outFormat, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize)
            var err: NSError?
            let st = converter.convert(to: out, error: &err) { [unowned self] _, status in
                if !self.pending.isEmpty { status.pointee = .haveData; return self.pending.removeFirst() }
                status.pointee = .noDataNow; return nil
            }
            guard st == .haveData, out.packetCount > 0, out.byteLength > 0 else { break }
            let pts = outPTS ?? 0
            outPTS = pts + 1024 / AudioEncoder.sampleRate
            lastOut = pts
            let raw = Data(bytes: out.data, count: Int(out.byteLength))
            onFrame?(AudioEncoder.adts(raw), UInt64(max(0, pts) * 90000))
        }
    }

    /// ADTS header: AAC-LC, 48 kHz (index 3), 2 channels.
    static func adts(_ raw: Data) -> Data {
        let len = raw.count + 7
        let h: [UInt8] = [0xFF, 0xF1, 0x4C, 0x80 | UInt8((len >> 11) & 0x03), UInt8((len >> 3) & 0xFF), UInt8(((len & 7) << 5) | 0x1F), 0xFC]
        return Data(h) + raw
    }
}
