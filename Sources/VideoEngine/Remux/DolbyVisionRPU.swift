import Foundation

/// Rewrites Dolby Vision profile 7 into single-layer profile 8.1 at the bitstream level: the enhancement
/// layer NAL units (type 63) go, and each RPU NAL unit (type 62) is rewritten so it no longer describes an
/// enhancement layer. The result plays as Dolby Vision 8.1 on a device that decodes only the base layer
/// (which is all Apple hardware decodes), and as its HDR10 base layer elsewhere.
///
/// The RPU is copied bit for bit, apart from three edits that match what `dovi_tool convert --mode 2`
/// documents: `el_spatial_resampling_filter_flag` becomes 0, `disable_residual_flag` becomes 1, and the
/// non-linear quantisation (NLQ) parameters, which exist only to rebuild the enhancement layer, are left
/// out. The CRC-32 is then computed again.
enum DolbyVisionRPU {
    /// The rewritten RPU for one RPU NAL unit's payload, or nil when the RPU cannot be rewritten (not
    /// type 2, no sequence info, a syntax this code does not know). The payload is what follows the
    /// two-byte NAL header: the 0x19 prefix, then the RPU with emulation prevention bytes. The result has
    /// the same form.
    static func profile81(fromNALPayload payload: some Sequence<UInt8>) -> [UInt8]? {
        var iterator = payload.makeIterator()
        guard iterator.next() == 0x19 else { return nil }
        var body = unescape(IteratorSequence(iterator))
        // Trailing zero bytes are padding; the RPU ends with 0x80.
        while body.last == 0 { body.removeLast() }
        guard var converted = try? convert(body) else { return nil }
        converted.insert(0x19, at: 0)
        return escape(converted, from: 1)
    }

    /// CRC-32/MPEG-2 (polynomial 0x04C11DB7, initial value 0xFFFFFFFF, no reflection, no final XOR), the
    /// checksum an RPU carries over its bytes from `rpu_type` to the last data byte.
    static func crc32(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = (crc << 8) ^ crcTable[Int((crc >> 24) ^ UInt32(byte))] }
        return crc
    }

    private static let crcTable: [UInt32] = (0..<256).map { (index: Int) -> UInt32 in
        var value = UInt32(index) << 24
        for _ in 0..<8 { value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1 }
        return value
    }

    /// Removes emulation prevention: the 0x03 after two zero bytes.
    static func unescape(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        var result: [UInt8] = []
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            result.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return result
    }

    /// Adds emulation prevention to `bytes[start...]`: a 0x03 before any byte up to 3 that follows two
    /// zero bytes.
    static func escape(_ bytes: [UInt8], from start: Int = 0) -> [UInt8] {
        var result = Array(bytes[..<start])
        result.reserveCapacity(bytes.count + bytes.count / 64)
        var zeros = 0
        for byte in bytes[start...] {
            if zeros >= 2, byte <= 3 {
                result.append(3)
                zeros = 0
            }
            result.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return result
    }

    enum Failure: Error {
        case truncated
        case unsupported
    }

    /// Widths of the fixed fields of the display management data: nine 16-bit matrix terms, three 32-bit
    /// offsets, nine 16-bit terms, then the EOTF fields and the source description.
    private static let colourFieldWidths: [Int] = {
        var widths = [Int](repeating: 16, count: 9)
        widths += [32, 32, 32]
        widths += [Int](repeating: 16, count: 9)
        widths += [16, 16, 16, 32, 5, 2, 2, 2, 12, 12, 10]
        return widths
    }()

    /// `rbsp` starts at `rpu_type` and ends with the 0x80 byte.
    private static func convert(_ rbsp: [UInt8]) throws -> [UInt8] {
        var t = Transcoder(reader: BitReader(bytes: rbsp))

        guard try t.copy(6) == 2 else { throw Failure.unsupported }                  // rpu_type
        let format = try t.copy(11)                                                  // rpu_format
        _ = try t.copy(4)                                                            // vdr_rpu_profile
        _ = try t.copy(4)                                                            // vdr_rpu_level
        guard try t.copy(1) == 1, format & 0x700 == 0 else { throw Failure.unsupported } // vdr_seq_info_present
        _ = try t.copy(1)                                                            // chroma_resampling_explicit_filter_flag
        let coefficientType = try t.copy(2)                                          // 0 fixed point, 1 float
        var denominatorBits = 0
        switch coefficientType {
        case 0: denominatorBits = Int(try t.copyGolomb())                            // coef_log2_denom
        case 1: break
        default: throw Failure.unsupported
        }
        _ = try t.copy(2)                                                            // vdr_rpu_normalized_idc
        _ = try t.copy(1)                                                            // bl_video_full_range_flag
        let blBits = Int(try t.copyGolomb()) + 8                                     // bl_bit_depth_minus8
        // el_bit_depth_minus8 carries ext_mapping_idc in its upper bits.
        let elBits = Int(try t.copyGolomb() & 0xFF) + 8
        _ = try t.copyGolomb()                                                       // vdr_bit_depth_minus8
        _ = try t.copy(1)                                                            // spatial_resampling_filter_flag
        let metadataCompression = try t.copy(3)                                      // dm_metadata_compression
        _ = try t.replace(1, with: 0)                                                // el_spatial_resampling_filter_flag
        let hadResidual = try t.replace(1, with: 1) == 0                             // disable_residual_flag

        let hasDisplayManagement = try t.copy(1) == 1                                // vdr_dm_metadata_present_flag
        if try t.copy(1) == 1 {                                                      // use_prev_vdr_rpu_flag
            _ = try t.copyGolomb()                                                   // prev_vdr_rpu_id
        } else {
            _ = try t.copyGolomb()                                                   // vdr_rpu_id
            _ = try t.copyGolomb()                                                   // mapping_color_space
            _ = try t.copyGolomb()                                                   // mapping_chroma_format_idc
            var pieces: [Int] = []
            for _ in 0..<3 {
                let pivots = Int(try t.copyGolomb()) + 2                             // num_pivots_minus_2
                guard pivots <= 9 else { throw Failure.unsupported }
                for _ in 0..<pivots { _ = try t.copy(blBits) }                       // pred_pivot_value
                pieces.append(pivots - 1)
            }
            if hadResidual {
                _ = try t.skip(3)                                                    // nlq_method_idc
                _ = try t.skip(blBits)                                               // nlq_pred_pivot_value
                _ = try t.skip(blBits)
            }
            _ = try t.copyGolomb()                                                   // num_x_partitions_minus1
            _ = try t.copyGolomb()                                                   // num_y_partitions_minus1
            for count in pieces {
                for _ in 0..<count {
                    if try t.copyGolomb() == 0 {                                     // mapping_idc: polynomial
                        let order = Int(try t.copyGolomb()) + 1                      // poly_order_minus1
                        guard order <= 2 else { throw Failure.unsupported }
                        if order == 1, try t.copy(1) == 1 { throw Failure.unsupported } // linear_interp_flag
                        for _ in 0...order { try t.copyCoefficient(coefficientType, denominatorBits) }
                    } else {                                                         // mapping_idc: MMR
                        let order = Int(try t.copy(2)) + 1                           // mmr_order_minus1
                        guard order <= 3 else { throw Failure.unsupported }
                        try t.copyCoefficient(coefficientType, denominatorBits)      // mmr_constant
                        for _ in 0..<(order * 7) { try t.copyCoefficient(coefficientType, denominatorBits) }
                    }
                }
            }
            if hadResidual {
                for _ in 0..<3 {
                    _ = try t.skip(elBits)                                           // nlq_offset
                    for _ in 0..<3 { try t.skipCoefficient(coefficientType, denominatorBits) } // vdr_in_max, slope, threshold
                }
            }
        }

        if hasDisplayManagement {
            for _ in 0..<3 { _ = try t.copyGolomb() }                                // affected, current id, scene_refresh_flag
            if metadataCompression == 0 {
                // ycc_to_rgb matrix and offset, rgb_to_lms matrix, signal EOTF and its parameters,
                // bit depth, colour space, chroma format, range and the source's PQ range and diagonal.
                for width in colourFieldWidths { try t.copy(width) }
            }
            try t.copyExtensionBlocks()
            // A second group, for level 3 and later blocks, only if it can still fit before the CRC.
            if t.reader.bitsLeft >= 3 + 1 + 8 + 32 + 8 { try t.copyExtensionBlocks() }
        }

        t.reader.align()
        t.writer.align()
        var body = t.writer.bytes
        _ = try t.reader.read(32)                                                    // rpu_data_crc32
        guard try t.reader.read(8) == 0x80, t.reader.bitsLeft == 0 else { throw Failure.unsupported }
        let crc = crc32(body)
        body.append(contentsOf: [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF), 0x80])
        return body
    }

    private struct BitReader {
        let bytes: [UInt8]
        private(set) var position = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var bitsLeft: Int { bytes.count * 8 - position }

        mutating func read(_ count: Int) throws -> UInt64 {
            guard count >= 0, count <= 64, count <= bitsLeft else { throw Failure.truncated }
            var value: UInt64 = 0
            var remaining = count
            while remaining > 0 {
                let free = 8 - (position & 7)
                let take = min(free, remaining)
                let bits = (UInt64(bytes[position >> 3]) >> UInt64(free - take)) & ((1 << UInt64(take)) - 1)
                value = (value << UInt64(take)) | bits
                position += take
                remaining -= take
            }
            return value
        }

        mutating func align() { position = (position + 7) & ~7 }
    }

    private struct BitWriter {
        private(set) var bytes: [UInt8] = []
        /// Bits taken in the last byte, 0 when it is full or there is none.
        private var used = 0

        mutating func write(_ count: Int, _ value: UInt64) {
            var remaining = count
            while remaining > 0 {
                if used == 0 { bytes.append(0) }
                let free = 8 - used
                let take = min(free, remaining)
                let bits = UInt8((value >> UInt64(remaining - take)) & ((1 << UInt64(take)) - 1))
                bytes[bytes.count - 1] |= bits << UInt8(free - take)
                used = (used + take) & 7
                remaining -= take
            }
        }

        mutating func align() { used = 0 }
    }

    /// Reads the source RPU and writes the converted one, field by field.
    private struct Transcoder {
        var reader: BitReader
        var writer = BitWriter()

        init(reader: BitReader) { self.reader = reader }

        @discardableResult
        mutating func copy(_ count: Int) throws -> UInt64 {
            let value = try reader.read(count)
            writer.write(count, value)
            return value
        }

        /// Reads `count` bits of the source and writes `value` in their place; returns what was read.
        mutating func replace(_ count: Int, with value: UInt64) throws -> UInt64 {
            let old = try reader.read(count)
            writer.write(count, value)
            return old
        }

        mutating func skip(_ count: Int) throws -> UInt64 { try reader.read(count) }

        /// An Exp-Golomb code, copied as it is.
        mutating func copyGolomb() throws -> UInt64 {
            var zeros = 0
            while try reader.read(1) == 0 {
                zeros += 1
                guard zeros <= 32 else { throw Failure.unsupported }
                writer.write(1, 0)
            }
            writer.write(1, 1)
            var suffix: UInt64 = 0
            if zeros > 0 { suffix = try copy(zeros) }
            return (1 << UInt64(zeros)) - 1 + suffix
        }

        mutating func skipGolomb() throws {
            var zeros = 0
            while try reader.read(1) == 0 {
                zeros += 1
                guard zeros <= 32 else { throw Failure.unsupported }
            }
            if zeros > 0 { _ = try reader.read(zeros) }
        }

        /// A mapping coefficient: an Exp-Golomb integer part and a fixed-point fraction, or a 32-bit float.
        /// The integer part is signed or not, but its bits are copied the same way.
        mutating func copyCoefficient(_ type: UInt64, _ denominatorBits: Int) throws {
            if type == 0 {
                _ = try copyGolomb()
                try copy(denominatorBits)
            } else {
                try copy(32)
            }
        }

        mutating func skipCoefficient(_ type: UInt64, _ denominatorBits: Int) throws {
            if type == 0 {
                try skipGolomb()
                _ = try reader.read(denominatorBits)
            } else {
                _ = try reader.read(32)
            }
        }

        /// A count of extension blocks, padding to a byte boundary, then each block: its length in bytes
        /// (Exp-Golomb), its level (8 bits) and that many bytes. The boundary is the RPU's own, so the
        /// padding is written again rather than copied.
        mutating func copyExtensionBlocks() throws {
            let blocks = try copyGolomb()
            reader.align()
            writer.align()
            for _ in 0..<blocks {
                let length = Int(try copyGolomb())
                try copy(8)
                var remaining = length * 8
                while remaining > 0 {
                    let chunk = min(remaining, 32)
                    try copy(chunk)
                    remaining -= chunk
                }
            }
        }
    }
}

/// Rewrites the HEVC access units of a profile 7 stream for single-layer profile 8.1: drops the
/// enhancement layer and rewrites the RPU (`DolbyVisionRPU`). Packets are length-prefixed NAL units,
/// as in Matroska and MP4 (`nalLengthSize` from the `hvcC` record), or Annex B (`nalLengthSize` 0).
struct DolbyVisionProfile81Converter: Sendable {
    let nalLengthSize: Int
    /// RPUs rewritten.
    private(set) var rewrittenRPUs = 0
    /// RPUs that could not be rewritten and were dropped, so the picture plays without Dolby Vision
    /// metadata for that frame.
    private(set) var droppedRPUs = 0
    /// Enhancement-layer NAL units removed.
    private(set) var removedLayerUnits = 0

    private static let rpuType: UInt8 = 62
    private static let enhancementLayerType: UInt8 = 63

    /// - Parameter nalLengthSize: bytes of each NAL unit's length, 1 to 4; 0 for Annex B start codes.
    init(nalLengthSize: Int) {
        self.nalLengthSize = nalLengthSize
    }

    /// The NAL length size from an HEVC `hvcC` record, or 0 when the extradata is Annex B or absent.
    static func lengthSize(ofHVCC data: UnsafeBufferPointer<UInt8>) -> Int {
        guard data.count >= 23, data[0] == 1 else { return 0 }
        return Int(data[21] & 3) + 1
    }

    /// The packet rewritten, or nil when it has nothing to change (the common case between RPUs of an
    /// already single-layer stream) or cannot be followed, and goes through as it is. An empty result
    /// means every NAL unit was removed.
    mutating func convert(_ packet: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
        let units = nalLengthSize > 0 ? lengthPrefixedUnits(packet) : annexBUnits(packet)
        guard let units, units.contains(where: Self.isChanged) else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(packet.count)
        for unit in units {
            let nal = UnsafeBufferPointer(rebasing: packet[unit.start..<unit.end])
            switch unit.type {
            case Self.enhancementLayerType:
                removedLayerUnits += 1
                continue
            case _ where unit.layer != 0:
                removedLayerUnits += 1
                continue
            case Self.rpuType:
                guard let rewritten = DolbyVisionRPU.profile81(fromNALPayload: nal.dropFirst(2)) else {
                    droppedRPUs += 1
                    continue
                }
                rewrittenRPUs += 1
                append(unit, [nal[0], nal[1]] + rewritten, to: &output, packet: packet)
            default:
                append(unit, nal, to: &output, packet: packet)
            }
        }
        return output
    }

    private struct Unit {
        /// Where the framing before the unit starts (Annex B) or the unit's length field (length-prefixed).
        var framing: Int
        var start: Int
        var end: Int
        var type: UInt8
        var layer: UInt8
    }

    private static func isChanged(_ unit: Unit) -> Bool {
        unit.type == rpuType || unit.type == enhancementLayerType || unit.layer != 0
    }

    private func append(_ unit: Unit, _ nal: some Collection<UInt8>, to output: inout [UInt8], packet: UnsafeBufferPointer<UInt8>) {
        if nalLengthSize > 0 {
            for shift in stride(from: (nalLengthSize - 1) * 8, through: 0, by: -8) {
                output.append(UInt8(truncatingIfNeeded: nal.count >> shift))
            }
        } else {
            output.append(contentsOf: packet[unit.framing..<unit.start])
        }
        output.append(contentsOf: nal)
    }

    private func lengthPrefixedUnits(_ packet: UnsafeBufferPointer<UInt8>) -> [Unit]? {
        var units: [Unit] = []
        var cursor = 0
        while cursor < packet.count {
            guard cursor + nalLengthSize <= packet.count else { return nil }
            var size = 0
            for i in 0..<nalLengthSize { size = size << 8 | Int(packet[cursor + i]) }
            let start = cursor + nalLengthSize
            guard size >= 2, start + size <= packet.count else { return nil }
            units.append(Unit(
                framing: cursor, start: start, end: start + size,
                type: (packet[start] >> 1) & 0x3F, layer: ((packet[start] & 1) << 5) | (packet[start + 1] >> 3)
            ))
            cursor = start + size
        }
        return units
    }

    private func annexBUnits(_ packet: UnsafeBufferPointer<UInt8>) -> [Unit]? {
        var starts: [Int] = []
        var i = 0
        while i + 3 <= packet.count {
            if packet[i + 2] > 1 {
                i += 3
            } else if packet[i] == 0, packet[i + 1] == 0, packet[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        guard !starts.isEmpty else { return nil }
        var units: [Unit] = []
        var previousEnd = 0
        for (n, start) in starts.enumerated() {
            var end = n + 1 < starts.count ? starts[n + 1] - 3 : packet.count
            // Zero bytes before the next start code belong to it; a NAL unit never ends in one.
            while end > start, packet[end - 1] == 0 { end -= 1 }
            guard end - start >= 2 else { return nil }
            units.append(Unit(
                framing: previousEnd, start: start, end: end,
                type: (packet[start] >> 1) & 0x3F, layer: ((packet[start] & 1) << 5) | (packet[start + 1] >> 3)
            ))
            previousEnd = end
        }
        return units
    }
}
