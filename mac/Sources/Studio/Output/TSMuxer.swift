import Foundation

/// Minimal MPEG-TS muxer (1 program: H.264 on PID 0x100 carrying the PCR, ADTS AAC on PID 0x101).
///
/// Why our own TS instead of raw Annex-B + ADTS over two pipes/FIFOs: Foundation's Process only wires
/// stdin/stdout/stderr, so a second input would need a FIFO on disk whose open() order must match ffmpeg's
/// (a classic deadlock source, and a stale FIFO if we crash). One pipe carrying a self-timestamped TS is
/// a single fd, keeps A/V sync exact (raw ES loses our PTS and ffmpeg would invent them), and ffmpeg
/// demuxes it with `-c copy` at essentially zero cost. Not thread-safe: use from one queue.
final class TSMuxer {
    static let pmtPID = 0x1000, videoPID = 0x100, audioPID = 0x101, hevcPID = 0x102
    private var cc: [Int: UInt8] = [:]

    func reset() { cc = [:] }

    private func nextCC(_ pid: Int) -> UInt8 {
        let v = cc[pid] ?? 0
        cc[pid] = (v + 1) & 0x0F
        return v
    }

    // MARK: PSI

    static func crc32mpeg(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b) << 24
            for _ in 0..<8 { crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc
    }

    private func section(pid: Int, table: [UInt8]) -> Data {
        var s = table
        let crc = TSMuxer.crc32mpeg(s)
        s += [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        var pkt = [UInt8](repeating: 0xFF, count: 188)
        pkt[0] = 0x47; pkt[1] = 0x40 | UInt8(pid >> 8); pkt[2] = UInt8(pid & 0xFF)
        pkt[3] = 0x10 | nextCC(pid)
        pkt[4] = 0 // pointer_field
        for (i, b) in s.enumerated() { pkt[5 + i] = b }
        return Data(pkt)
    }

    /// PAT + PMT (two packets).
    func psi(hevc: Bool = false) -> Data {
        let pat: [UInt8] = [0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01,
                            0xE0 | UInt8(TSMuxer.pmtPID >> 8), UInt8(TSMuxer.pmtPID & 0xFF)]
        let vp = TSMuxer.videoPID, ap = TSMuxer.audioPID
        let pmt: [UInt8] = [0x02, 0xB0, 0x1D, 0x00, 0x01, 0xC1, 0x00, 0x00,
                            0xE0 | UInt8(vp >> 8), UInt8(vp & 0xFF), 0xF0, 0x00,
                            0x1B, 0xE0 | UInt8(vp >> 8), UInt8(vp & 0xFF), 0xF0, 0x00,
                            0x0F, 0xE0 | UInt8(ap >> 8), UInt8(ap & 0xFF), 0xF0, 0x00]
        var p = pmt
        if hevc { p += [0x24, 0xE0 | UInt8(TSMuxer.hevcPID >> 8), UInt8(TSMuxer.hevcPID & 0xFF), 0xF0, 0x00] }
        let len = p.count - 3 + 4
        p[1] = 0xB0 | UInt8(len >> 8); p[2] = UInt8(len & 0xFF)
        return section(pid: 0, table: pat) + section(pid: TSMuxer.pmtPID, table: p)
    }

    // MARK: PES

    private static func ts33(_ prefix: UInt8, _ v: UInt64) -> [UInt8] {
        let t = v & 0x1_FFFF_FFFF
        return [prefix << 4 | UInt8((t >> 29) & 0x0E) | 1,
                UInt8((t >> 22) & 0xFF),
                UInt8(((t >> 14) & 0xFE) | 1),
                UInt8((t >> 7) & 0xFF),
                UInt8(((t << 1) & 0xFE) | 1)]
    }

    /// One elementary-stream access unit as a PES packet split into TS packets. `pts` in 90 kHz ticks.
    func pes(pid: Int, streamID: UInt8, pts: UInt64, payload: Data, pcr: Bool, randomAccess: Bool, boundedLength: Bool) -> Data {
        var header: [UInt8] = [0, 0, 1, streamID]
        let plen = boundedLength ? min(payload.count + 8, 0xFFFF) : 0
        header += [UInt8(plen >> 8), UInt8(plen & 0xFF), 0x80, 0x80, 5]
        header += TSMuxer.ts33(2, pts)
        var body = Data(header); body.append(payload)
        var out = Data(); out.reserveCapacity(body.count + body.count / 180 * 4 + 188)
        var offset = 0, first = true
        while offset < body.count {
            var af: [UInt8]? = nil // adaptation field content without length byte
            if first && (pcr || randomAccess) {
                var flags: UInt8 = randomAccess ? 0x40 : 0
                var a: [UInt8] = []
                if pcr {
                    flags |= 0x10
                    let base = pts >= 9000 ? pts - 9000 : 0 // PCR 100 ms ahead of PTS
                    a = [UInt8((base >> 25) & 0xFF), UInt8((base >> 17) & 0xFF), UInt8((base >> 9) & 0xFF),
                         UInt8((base >> 1) & 0xFF), UInt8(((base & 1) << 7) | 0x7E), 0]
                }
                af = [flags] + a
            }
            let room = 184 - (af.map { $0.count + 1 } ?? 0)
            let remaining = body.count - offset
            let take = min(room, remaining)
            if take < room { // last packet: stuff the adaptation field so the payload ends exactly at 188
                let total = 184 - take // length byte + content
                var content = af ?? (total >= 2 ? [0] : [])
                if total >= 2 { content += [UInt8](repeating: 0xFF, count: total - 1 - content.count) }
                af = content
                if total == 1 { af = [] }
            }
            var pkt = [UInt8](); pkt.reserveCapacity(188)
            pkt += [0x47, (first ? 0x40 : 0) | UInt8(pid >> 8), UInt8(pid & 0xFF)]
            pkt.append((af != nil ? 0x30 : 0x10) | nextCC(pid))
            if let af { pkt.append(UInt8(af.count)); pkt += af }
            out.append(contentsOf: pkt)
            out.append(body.subdata(in: (body.startIndex + offset)..<(body.startIndex + offset + take)))
            offset += take
            first = false
        }
        return out
    }

    func video(annexB: Data, pts: UInt64, keyframe: Bool, pid: Int = TSMuxer.videoPID) -> Data {
        pes(pid: pid, streamID: 0xE0, pts: pts, payload: annexB, pcr: pid == TSMuxer.videoPID, randomAccess: keyframe, boundedLength: false)
    }
    func audio(adts: Data, pts: UInt64) -> Data {
        pes(pid: TSMuxer.audioPID, streamID: 0xC0, pts: pts, payload: adts, pcr: false, randomAccess: false, boundedLength: true)
    }
}
