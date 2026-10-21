import Testing
import Foundation
import CoreVideo
@testable import Studio

@Suite(.serialized) struct H264Tests {
    @Test func annexBParserHandlesStartCodesAndSplits() {
        let stream: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 3,  0, 0, 1, 0x68, 4, 5,  0, 0, 0, 1, 0x65, 0x88, 9, 0, 9,  0, 0, 1, 0x41, 0x9a, 7, 0, 0, 0]
        for split in [stream.count, 1, 2, 3, 5] {
            var p = AnnexBParser(), got: [[UInt8]] = []
            var i = 0
            while i < stream.count {
                let end = min(stream.count, i + split)
                stream[i..<end].withUnsafeBufferPointer { got += p.feed($0, at: 0).map(\.bytes) }
                i = end
            }
            if let last = p.flush() { got.append(last.bytes) }
            #expect(got == [[0x67, 1, 2, 3], [0x68, 4, 5], [0x65, 0x88, 9, 0, 9], [0x41, 0x9a, 7]], "split \(split): \(got)")
        }
    }

    @Test func accessUnitBuilderGroupsSlicesAndDetectsIDR() {
        var b = AccessUnitBuilder()
        func nal(_ bytes: [UInt8]) -> AnnexBParser.NAL { .init(bytes: bytes, at: 1) }
        var aus: [AccessUnit] = []
        for n in [[9, 0xf0], [7, 1], [8, 2], [0x65, 0x88, 1], [0x65, 0x10, 2] /* 2nd slice of same frame */, [9, 0xf0], [0x41, 0x9a, 3], [9, 0xf0], [0x41, 0x9a, 4]] as [[UInt8]] {
            if let au = b.add(nal(n)) { aus.append(au) }
        }
        if let au = b.flush() { aus.append(au) }
        #expect(aus.count == 3)
        #expect(aus[0].isIDR && aus[0].sps == [7, 1] && aus[0].pps == [8, 2])
        #expect(!aus[1].isIDR)
        #expect(aus[0].avcc == [0, 0, 0, 3, 0x65, 0x88, 1, 0, 0, 0, 3, 0x65, 0x10, 2])
    }

    /// 480p -> 1080p mid-stream (new SPS/PPS at an IDR) must rebuild the decompression session and keep decoding.
    @Test func resolutionSwitchRebuildsSession() async throws {
        guard let ff = FFmpegLocator.locate() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("h264-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var all = Data()
        for (w, h) in [(854, 480), (1920, 1080)] {
            let f = dir.appendingPathComponent("\(w).h264")
            let (st, out) = sh(ff, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=\(w)x\(h):rate=60:duration=1", "-c:v", "libx264", "-preset", "ultrafast", "-bf", "0", "-g", "30",
                                    "-pix_fmt", "yuv420p", "-bsf:v", "h264_mp4toannexb", "-f", "h264", "-y", f.path])
            #expect(st == 0, "\(out)")
            all.append(try Data(contentsOf: f))
        }
        final class Box: @unchecked Sendable { let l = NSLock(); var widths: [Int] = [] }
        let box = Box()
        let dec = H264Decoder { pb, _, _ in box.l.withLock { box.widths.append(CVPixelBufferGetWidth(pb)) } }
        var parser = AnnexBParser(), builder = AccessUnitBuilder()
        var nals: [AnnexBParser.NAL] = []
        all.withUnsafeBytes { raw in nals = parser.feed(raw.bindMemory(to: UInt8.self), at: 0) }
        if let l = parser.flush() { nals.append(l) }
        for n in nals { if let au = builder.add(n) { dec.decode(au) } }
        if let au = builder.flush() { dec.decode(au) }
        dec.invalidate()
        let w = box.l.withLock { box.widths }
        #expect(dec.sessionsCreated == 2)
        #expect(w.count >= 118, "decoded \(w.count)")
        #expect(w.contains(854) && w.contains(1920) && w.firstIndex(of: 1920)! > w.lastIndex(of: 854)!)
    }
}
