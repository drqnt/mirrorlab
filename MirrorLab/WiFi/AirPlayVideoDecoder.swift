import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Native hardware H.264 / HEVC decode endpoint for AirPlay mirroring.
///
/// The AirPlay protocol/decryption layer supplies avcC or hvcC codec configuration and
/// length-prefixed H.264/HEVC access units. VideoToolbox returns CVPixelBuffer objects
/// directly into the same LatestVideoFrameStore already used by the proven USB
/// Decoded frames are IOSurface/Metal-compatible and stay on the native render path.
final class AirPlayVideoDecoder {
    private let presentationStore: AirPlayPresentationStore
    private let diagnostics: DiagnosticsStore
    private let queue = DispatchQueue(label: "MirrorLab.AirPlay.VideoToolbox", qos: .userInteractive)

    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var activeGeneration: UInt64 = 0
    private(set) var nalLengthBytes = 4
    var onDecodedFrame: ((UInt64) -> Void)?

    init(presentationStore: AirPlayPresentationStore, diagnostics: DiagnosticsStore) {
        self.presentationStore = presentationStore
        self.diagnostics = diagnostics
    }

    deinit {
        reset()
    }

    func reset() {
        queue.sync {
            if let session {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                VTDecompressionSessionInvalidate(session)
            }
            session = nil
            formatDescription = nil
            nalLengthBytes = 4
            activeGeneration = 0
        }
    }

    func configure(codecConfig: Data, generation: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeGeneration = generation
            do {
                let configuration = try Self.parseCodecConfiguration(codecConfig)
                self.nalLengthBytes = configuration.nalLengthBytes
                let format: CMVideoFormatDescription
                switch configuration {
                case .h264(let sps, let pps, let nalLengthBytes):
                    format = try Self.makeH264FormatDescription(
                        sps: sps,
                        pps: pps,
                        nalLengthBytes: nalLengthBytes
                    )
                case .hevc(let vps, let sps, let pps, let nalLengthBytes):
                    format = try Self.makeHEVCFormatDescription(
                        vps: vps,
                        sps: sps,
                        pps: pps,
                        nalLengthBytes: nalLengthBytes
                    )
                }
                try self.makeSession(formatDescription: format)
                // Old asynchronous decode callbacks are fully drained by makeSession.
                // Clear only now so a late pre-rotation frame cannot re-enter the
                // new presentation timeline after the controller already flushed it.
                self.presentationStore.clear()
                self.formatDescription = format
                self.diagnostics.addEvent(
                    "AirPlay VideoToolbox готов: \(configuration.codecName) hardware decode, NAL=\(configuration.nalLengthBytes) B"
                )
            } catch {
                self.diagnostics.addEvent(
                    "AirPlay VideoToolbox config: \(error.localizedDescription)",
                    level: .error
                )
            }
        }
    }

    /// Decode one already-decrypted AVCC access unit.
    func decode(accessUnit: Data, presentationTime: CMTime, generation: UInt64) {
        queue.async { [weak self] in
            guard let self,
                  generation == self.activeGeneration,
                  let session = self.session,
                  let formatDescription = self.formatDescription,
                  !accessUnit.isEmpty else { return }

            var blockBuffer: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: accessUnit.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: accessUnit.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard status == kCMBlockBufferNoErr, let blockBuffer else {
                self.diagnostics.addEvent("AirPlay video: CMBlockBuffer create \(status)", level: .warning)
                return
            }

            status = accessUnit.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return OSStatus(-1) }
                return CMBlockBufferReplaceDataBytes(
                    with: base,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: accessUnit.count
                )
            }
            guard status == kCMBlockBufferNoErr else {
                self.diagnostics.addEvent("AirPlay video: CMBlockBuffer copy \(status)", level: .warning)
                return
            }

            var timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: presentationTime,
                decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            var sampleSize = accessUnit.count
            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            )
            guard status == noErr, let sampleBuffer else {
                self.diagnostics.addEvent("AirPlay video: CMSampleBuffer create \(status)", level: .warning)
                return
            }

            var infoFlags = VTDecodeInfoFlags()
            status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: VTDecodeFrameFlags(rawValue: 1 << 0),
                frameRefcon: nil,
                infoFlagsOut: &infoFlags
            )
            if status != noErr {
                self.diagnostics.addEvent("AirPlay VideoToolbox decode: \(status)", level: .warning)
            }
        }
    }

    private func makeSession(formatDescription: CMVideoFormatDescription) throws {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }

        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
        ]
        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, presentationTime, _ in
                guard status == noErr,
                      let refCon,
                      let imageBuffer else { return }
                let decoder = Unmanaged<AirPlayVideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
                let generation = decoder.activeGeneration
                decoder.diagnostics.recordVideoReceived(pts: presentationTime)
                decoder.presentationStore.enqueue(pixelBuffer: imageBuffer, presentationTime: presentationTime)
                decoder.onDecodedFrame?(generation)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: pixelAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            throw DecoderError.videoToolbox(status)
        }
        session = newSession
        VTSessionSetProperty(
            newSession,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
    }

    private enum CodecConfiguration {
        case h264(sps: Data, pps: Data, nalLengthBytes: Int)
        case hevc(vps: Data?, sps: Data, pps: Data, nalLengthBytes: Int)

        var nalLengthBytes: Int {
            switch self {
            case .h264(_, _, let value), .hevc(_, _, _, let value): return value
            }
        }

        var codecName: String {
            switch self {
            case .h264: return "H.264"
            case .hevc: return "HEVC"
            }
        }
    }

    private struct ParsedAVCConfiguration {
        let sps: Data
        let pps: Data
        let nalLengthBytes: Int
    }

    private static func parseCodecConfiguration(_ data: Data) throws -> CodecConfiguration {
        let normalized = extractHVCCFromSampleEntry(data) ?? data
        if let hevc = try? parseHEVCConfiguration(normalized) {
            return .hevc(
                vps: hevc.vps,
                sps: hevc.sps,
                pps: hevc.pps,
                nalLengthBytes: hevc.nalLengthBytes
            )
        }
        let avc = try parseAVCConfiguration(normalized)
        return .h264(sps: avc.sps, pps: avc.pps, nalLengthBytes: avc.nalLengthBytes)
    }

    private static func extractHVCCFromSampleEntry(_ data: Data) -> Data? {
        guard data.count >= 16 else { return nil }

        func be32(_ offset: Int) -> Int? {
            guard data.count >= offset + 4 else { return nil }
            return (Int(data[offset]) << 24)
                | (Int(data[offset + 1]) << 16)
                | (Int(data[offset + 2]) << 8)
                | Int(data[offset + 3])
        }

        let topSize = be32(0) ?? 0
        let type = String(bytes: data[4..<8], encoding: .ascii)
        guard (type == "hvc1" || type == "hev1"),
              topSize >= 8,
              topSize <= data.count else { return nil }

        let marker = Array("hvcC".utf8)
        for typeOffset in 8...(data.count - 4) {
            guard data[typeOffset] == marker[0],
                  data[typeOffset + 1] == marker[1],
                  data[typeOffset + 2] == marker[2],
                  data[typeOffset + 3] == marker[3],
                  typeOffset >= 4 else { continue }

            let boxStart = typeOffset - 4
            guard let boxSize = be32(boxStart),
                  boxSize >= 8,
                  boxStart + boxSize <= min(topSize, data.count) else { continue }
            return data.subdata(in: (typeOffset + 4)..<(boxStart + boxSize))
        }
        return nil
    }

    private struct ParsedHEVCConfiguration {
        let vps: Data?
        let sps: Data
        let pps: Data
        let nalLengthBytes: Int
    }

    private static func parseHEVCConfiguration(_ data: Data) throws -> ParsedHEVCConfiguration {
        guard data.count >= 23, data[0] == 1 else { throw DecoderError.invalidHVCC }
        let nalLengthBytes = Int(data[21] & 0x03) + 1
        let numArrays = Int(data[22])
        guard numArrays > 0 else { throw DecoderError.invalidHVCC }
        var offset = 23
        var vps: Data?
        var sps: Data?
        var pps: Data?

        for _ in 0..<numArrays {
            guard data.count >= offset + 3 else { throw DecoderError.invalidHVCC }
            let nalType = Int(data[offset] & 0x3F)
            let count = (Int(data[offset + 1]) << 8) | Int(data[offset + 2])
            offset += 3
            for _ in 0..<count {
                guard data.count >= offset + 2 else { throw DecoderError.invalidHVCC }
                let length = (Int(data[offset]) << 8) | Int(data[offset + 1])
                offset += 2
                guard length > 0, data.count >= offset + length else { throw DecoderError.invalidHVCC }
                let nal = data.subdata(in: offset..<(offset + length))
                offset += length
                if nalType == 32 && vps == nil { vps = nal }
                if nalType == 33 && sps == nil { sps = nal }
                if nalType == 34 && pps == nil { pps = nal }
            }
        }
        guard let sps, let pps else { throw DecoderError.missingHEVCParameterSets }
        return ParsedHEVCConfiguration(vps: vps, sps: sps, pps: pps, nalLengthBytes: nalLengthBytes)
    }

    private static func parseAVCConfiguration(_ data: Data) throws -> ParsedAVCConfiguration {
        guard data.count >= 7, data[0] == 1 else { throw DecoderError.invalidAVCC }
        let nalLengthBytes = Int(data[4] & 0x03) + 1
        var offset = 5
        let spsCount = Int(data[offset] & 0x1F)
        offset += 1
        guard spsCount > 0 else { throw DecoderError.missingParameterSets }

        func readNAL() throws -> Data {
            guard data.count >= offset + 2 else { throw DecoderError.invalidAVCC }
            let length = (Int(data[offset]) << 8) | Int(data[offset + 1])
            offset += 2
            guard length > 0, data.count >= offset + length else { throw DecoderError.invalidAVCC }
            let nal = data.subdata(in: offset..<(offset + length))
            offset += length
            return nal
        }

        let sps = try readNAL()
        for _ in 1..<spsCount { _ = try readNAL() }

        guard data.count > offset else { throw DecoderError.invalidAVCC }
        let ppsCount = Int(data[offset])
        offset += 1
        guard ppsCount > 0 else { throw DecoderError.missingParameterSets }
        let pps = try readNAL()

        return ParsedAVCConfiguration(sps: sps, pps: pps, nalLengthBytes: nalLengthBytes)
    }

    private static func makeH264FormatDescription(
        sps: Data,
        pps: Data,
        nalLengthBytes: Int
    ) throws -> CMVideoFormatDescription {
        var format: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return OSStatus(-1)
                }
                var pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                var sizes = [sps.count, pps.count]
                return pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                    sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: Int32(nalLengthBytes),
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }
        guard status == noErr, let format else {
            throw DecoderError.formatDescription(status)
        }
        return format
    }

    private static func makeHEVCFormatDescription(
        vps: Data?,
        sps: Data,
        pps: Data,
        nalLengthBytes: Int
    ) throws -> CMVideoFormatDescription {
        let sets = [vps, Optional(sps), Optional(pps)].compactMap { $0 }
        guard sets.count >= 2 else { throw DecoderError.missingHEVCParameterSets }

        var format: CMFormatDescription?
        var pointers = [UnsafePointer<UInt8>]()
        var sizes = [Int]()
        var storage = sets

        let status: OSStatus = storage.withUnsafeMutableBufferPointer { buffer in
            func recurse(_ index: Int, _ body: () -> OSStatus) -> OSStatus {
                if index == buffer.count { return body() }
                return buffer[index].withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return OSStatus(-1) }
                    pointers.append(base)
                    sizes.append(buffer[index].count)
                    defer {
                        pointers.removeLast()
                        sizes.removeLast()
                    }
                    return recurse(index + 1, body)
                }
            }
            return recurse(0) {
                pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                    sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: sets.count,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: Int32(nalLengthBytes),
                            extensions: nil,
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }
        guard status == noErr, let format else {
            throw DecoderError.formatDescription(status)
        }
        return format
    }

    private enum DecoderError: LocalizedError {
        case invalidAVCC
        case invalidHVCC
        case missingParameterSets
        case missingHEVCParameterSets
        case formatDescription(OSStatus)
        case videoToolbox(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidAVCC: return "invalid avcC codec configuration"
            case .invalidHVCC: return "invalid hvcC codec configuration"
            case .missingParameterSets: return "avcC does not contain SPS/PPS"
            case .missingHEVCParameterSets: return "hvcC does not contain HEVC SPS/PPS"
            case .formatDescription(let status): return "CMVideoFormatDescription error \(status)"
            case .videoToolbox(let status): return "VTDecompressionSession error \(status)"
            }
        }
    }
}
