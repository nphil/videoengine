import Foundation
import Testing
@testable import VideoEngine

/// The Dolby Vision profile 7 to 8.1 rewrite, checked against RPUs from real content.
///
/// The four vectors are the RPU NAL payloads (the 0x19 prefix and the RPU, emulation prevention included)
/// of `mel_orig.bin`, `mel_to_81.bin`, `fel_orig.bin` and `fel_to_81.bin` in the `assets/tests` folder of
/// quietvoid/dovi_tool (MIT licence): a profile 7 minimal enhancement layer RPU, a full enhancement layer
/// RPU, and what `dovi_tool convert --mode 2` makes of each. The rewrite must match it byte for byte.
struct DolbyVisionRPUTests {
    static let melOriginal = hex(
        "1908090840613650af003ff801ffc00ffc001fffa000001000000d0000030080000068000004000003000040" +
        "000020000020000003000400000302000003020000030000400000200000200000344acc00006bd44acdf3f9" +
        "d6384acc8994000003020000030010000003001000000300386c4486030c14bc611c0a28000003034c7cb5ff" +
        "fe0000030000030000030000c0401f01c2a2003008004f930f010115f0ae448301f40000800000030000f91f" +
        "77ee80"
    )

    static let melProfile81 = hex(
        "19080908406136506f003ff801ffc00fffd0000008000006800000400000340000030200000301a256600003" +
        "5ea2566f9fceb1c256644ca00000100000030080000003008000000301c36224301860a5e308e0514000001a" +
        "63e5affff000000300000300000300060200f80e15103008004f930f010115f0ae448301f400008000000300" +
        "008cf420d580"
    )

    static let felOriginal = hex(
        "1908090840613650ae20002008020080200802007f801ffc00ffc001fffa0000030100000300d00000080000" +
        "06800000400000340000030200000301a000001000000d000003008000006800000400000303400000200000" +
        "0a86d9e67b2f863efc189e6029e98c06b8c566a7cd5f8dffcb6d8c39e38a9981b86ca6790f405f434cb7d80e" +
        "9e04c349fd3bb77ec2cd5de3a147d44c0a2e8062164a029b5d59500ed38f58c46c4ec13a14582cff3023536d" +
        "57bbb6e411483b92966413698fce6bc31bd620fadd405bbef4643160b1f01bf2eefbf2a5e2f3ccb4abf3cc39" +
        "83779e7568311b004800004004004000004012000010010010000010048000040040040000072566000035ea" +
        "2566f9fceb1c256644ca0000030100000300080000030008000003001c36224301860a5e308e051400000301" +
        "a63e5affff000003000003000003000060200f80e1518030080059ca1200c028218df8258008006140000202" +
        "2a512088050000030002281150120c07d000020d60015eb8f29d8280"
    )

    static let felProfile81 = hex(
        "19080908406136506e20002008020080200802007f801ffc00fffd0000030080000068000004000003034000" +
        "002000001a0000030100000300d0000008000006800000400000340000030200000301a0000010000005436c" +
        "f33d97c31f7e0c4f3014f4c6035c62b353e6afc6ffe5b6c61cf1c54cc0dc36533c87a02fa1a65bec074f0261" +
        "a4fe9ddbbf6166aef1d0a3ea26051740310b25014daeaca80769c7ac623627609d0a2c167f9811a9b6abdddb" +
        "7208a41dc94b3209b4c7e735e18deb107d6ea02ddf7a3218b058f80df9777df952f179e65a55f9e61cc1bbcf" +
        "3ab4188de4acc00006bd44acdf3f9d6384acc89940000020000003010000030001000003000386c4486030c1" +
        "4bc611c0a280000034c7cb5fffe0000003000003000003000c0401f01c2a3030080059ca1200c028218df825" +
        "80080061400002022a512088050000030002281150120c07d000020d60015e6210c68d80"
    )

    static func hex(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    @Test func crcMatchesTheCheckValueOfCRC32MPEG2() {
        #expect(DolbyVisionRPU.crc32(Array("123456789".utf8)) == 0x0376_E6E7)
    }

    @Test func emulationPreventionRoundTrips() {
        let raw: [UInt8] = [0x12, 0, 0, 0, 0x34, 0, 0, 1, 0, 0, 2, 0, 0, 3, 0, 0, 4, 0, 0]
        let escaped = DolbyVisionRPU.escape(raw)
        #expect(escaped == [0x12, 0, 0, 3, 0, 0x34, 0, 0, 3, 1, 0, 0, 3, 2, 0, 0, 3, 3, 0, 0, 4, 0, 0])
        #expect(DolbyVisionRPU.unescape(escaped) == raw)
        // The prefix is left alone.
        #expect(DolbyVisionRPU.escape([0x19, 0, 0, 1], from: 1) == [0x19, 0, 0, 3, 1])
    }

    @Test func aMinimalEnhancementLayerRPUBecomesProfile81() {
        #expect(DolbyVisionRPU.profile81(fromNALPayload: Self.melOriginal) == Self.melProfile81)
    }

    @Test func aFullEnhancementLayerRPUBecomesProfile81() {
        let converted = DolbyVisionRPU.profile81(fromNALPayload: Self.felOriginal)
        #expect(converted == Self.felProfile81)
        // The residual layer's parameters are gone, so it is shorter.
        #expect(Self.felProfile81.count < Self.felOriginal.count)
    }

    @Test func theCRCOfARewrittenRPUHolds() throws {
        for original in [Self.melOriginal, Self.felOriginal] {
            let converted = try #require(DolbyVisionRPU.profile81(fromNALPayload: original))
            let body = DolbyVisionRPU.unescape(converted.dropFirst())
            #expect(body.last == 0x80)
            let crc = body[(body.count - 5)..<(body.count - 1)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            #expect(DolbyVisionRPU.crc32(body[..<(body.count - 5)]) == crc)
        }
    }

    @Test func aSingleLayerRPUIsLeftAsItIs() {
        #expect(DolbyVisionRPU.profile81(fromNALPayload: Self.melProfile81) == Self.melProfile81)
        #expect(DolbyVisionRPU.profile81(fromNALPayload: Self.felProfile81) == Self.felProfile81)
    }

    @Test func anRPUThatCannotBeFollowedIsRefused() {
        // Wrong prefix, truncated, cut inside the mapping, and a changed rpu_type.
        #expect(DolbyVisionRPU.profile81(fromNALPayload: [UInt8]()) == nil)
        #expect(DolbyVisionRPU.profile81(fromNALPayload: [0x18] + Self.melOriginal.dropFirst()) == nil)
        #expect(DolbyVisionRPU.profile81(fromNALPayload: Self.felOriginal.prefix(60)) == nil)
        #expect(DolbyVisionRPU.profile81(fromNALPayload: Self.felOriginal.dropLast()) == nil)
        var otherType = Self.melOriginal
        otherType[1] = 0x0C
        #expect(DolbyVisionRPU.profile81(fromNALPayload: otherType) == nil)
    }

    // MARK: Access units

    private static let slice: [UInt8] = [0x26, 0x01, 0xAF, 0x08, 0x00, 0x00, 0x03, 0x01, 0x55]
    private static let secondSlice: [UInt8] = [0x02, 0x01, 0xD0, 0x40, 0x7F]
    /// Type 63, the enhancement layer's wrapper.
    private static let enhancementLayer: [UInt8] = [0x7E, 0x01, 0x26, 0x01, 0xE0, 0x10, 0x00, 0x00, 0x03, 0x00, 0x99]
    private static let rpuHeader: [UInt8] = [0x7C, 0x01]

    private static func prefixed(_ units: [[UInt8]], lengthSize: Int) -> [UInt8] {
        units.flatMap { unit in
            (0..<lengthSize).reversed().map { UInt8(truncatingIfNeeded: unit.count >> ($0 * 8)) } + unit
        }
    }

    private static func annexB(_ units: [[UInt8]], codes: [[UInt8]]) -> [UInt8] {
        zip(units, codes).flatMap { $1 + $0 }
    }

    private static func convert(_ converter: inout DolbyVisionProfile81Converter, _ packet: [UInt8]) -> [UInt8]? {
        packet.withUnsafeBufferPointer { converter.convert($0) }
    }

    @Test func lengthPrefixedAccessUnitLosesItsEnhancementLayerAndGetsAProfile81RPU() {
        for lengthSize in [4, 2] {
            var converter = DolbyVisionProfile81Converter(nalLengthSize: lengthSize)
            let source = Self.prefixed(
                [Self.slice, Self.enhancementLayer, Self.rpuHeader + Self.felOriginal, Self.secondSlice], lengthSize: lengthSize
            )
            let expected = Self.prefixed(
                [Self.slice, Self.rpuHeader + Self.felProfile81, Self.secondSlice], lengthSize: lengthSize
            )
            #expect(Self.convert(&converter, source) == expected)
            #expect(converter.rewrittenRPUs == 1)
            #expect(converter.removedLayerUnits == 1)
            #expect(converter.droppedRPUs == 0)
        }
    }

    @Test func annexBAccessUnitKeepsItsStartCodes() {
        var converter = DolbyVisionProfile81Converter(nalLengthSize: 0)
        let long: [UInt8] = [0, 0, 0, 1]
        let short: [UInt8] = [0, 0, 1]
        let source = Self.annexB(
            [Self.slice, Self.rpuHeader + Self.melOriginal, Self.enhancementLayer, Self.secondSlice],
            codes: [long, short, short, long]
        )
        let expected = Self.annexB(
            [Self.slice, Self.rpuHeader + Self.melProfile81, Self.secondSlice], codes: [long, short, long]
        )
        #expect(Self.convert(&converter, source) == expected)
        #expect(converter.rewrittenRPUs == 1)
        #expect(converter.removedLayerUnits == 1)
    }

    @Test func aPacketWithNothingToChangeIsNotCopied() {
        var converter = DolbyVisionProfile81Converter(nalLengthSize: 4)
        #expect(Self.convert(&converter, Self.prefixed([Self.slice, Self.secondSlice], lengthSize: 4)) == nil)
        // A length that runs past the packet cannot be followed; it goes through as it is.
        #expect(Self.convert(&converter, [0, 0, 0, 40, 0x26, 0x01, 0x00]) == nil)
        #expect(converter.rewrittenRPUs == 0)
    }

    @Test func anRPUThatCannotBeRewrittenIsDroppedAndCounted() {
        var converter = DolbyVisionProfile81Converter(nalLengthSize: 4)
        let broken = Self.rpuHeader + Self.felOriginal.prefix(40)
        let result = Self.convert(&converter, Self.prefixed([Self.slice, broken], lengthSize: 4))
        #expect(result == Self.prefixed([Self.slice], lengthSize: 4))
        #expect(converter.droppedRPUs == 1)
        #expect(converter.rewrittenRPUs == 0)
    }

    @Test func nalLengthSizeComesFromTheHVCCRecord() {
        var record = [UInt8](repeating: 0, count: 23)
        record[0] = 1
        record[21] = 0x03
        #expect(record.withUnsafeBufferPointer { DolbyVisionProfile81Converter.lengthSize(ofHVCC: $0) } == 4)
        record[21] = 0x01
        #expect(record.withUnsafeBufferPointer { DolbyVisionProfile81Converter.lengthSize(ofHVCC: $0) } == 2)
        // Annex B extradata starts with a start code.
        let annexB: [UInt8] = [0, 0, 0, 1, 0x40, 0x01] + [UInt8](repeating: 0, count: 20)
        #expect(annexB.withUnsafeBufferPointer { DolbyVisionProfile81Converter.lengthSize(ofHVCC: $0) } == 0)
    }
}
