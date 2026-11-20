import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware decoder for a device-native USB screen sample when AVFoundation
/// exposes the muxed iOS screen stream in compressed H.264/HEVC form.
///
/// 0.3.38 keeps asking AVCaptureVideoDataOutput for the device-native
/// format (`videoSettings = [:]`). On macOS that native format may be either an
/// uncompressed CVPixelBuffer or a compressed CMSampleBuffer. This decoder keeps
/// the latter path zero-copy after VideoToolbox and feeds the same frame store as
/// the uncompressed path.
final class USBVideoSampleDecoder {
    private let frameStore: LatestVideoFrameStore
    private let diagnostics: DiagnosticsStore
    private let queue = DispatchQueue(label: "MirrorLab.USB.VideoToolbox", qos: .userInteractive)

    private var session: VTDecompressionSession?
    private var formatSignature = ""
    private var unsupportedSignature = ""

    init(frameStore: LatestVideoFrameStore, diagnostics: DiagnosticsStore) {
        self.frameStore = frameStore
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
            formatSignature = ""
            unsupportedSignature = ""
        }
    }

    func decode(sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }

        let subtype = CMFormatDescriptionGetMediaSubType(formatDescription)
        guard subtype == kCMVideoCodecType_H264 || subtype == kCMVideoCodecType_HEVC else {
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            let signature = "\(dimensions.width)x\(dimensions.height)-\(subtype)"
            if signature != unsupportedSignature {
                unsupportedSignature = signature
                diagnostics.addEvent(
                    "USB device-native sample имеет неподдержанный compressed codec \(Self.fourCCString(subtype)); нужен fallback",
                    level: .warning
                )
            }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            let signature = "\(dimensions.width)x\(dimensions.height)-\(subtype)"

            if self.session == nil || self.formatSignature != signature {
                do {
                    try self.makeSession(formatDescription: formatDescription)
                    self.formatSignature = signature
                    self.frameStore.clear()
                    self.diagnostics.addEvent(
                        "USB VideoToolbox готов: \(dimensions.width)×\(dimensions.height) \(Self.fourCCString(subtype)) → CVPixelBuffer"
                    )
                } catch {
                    self.diagnostics.addEvent(
                        "USB VideoToolbox config: \(error.localizedDescription)",
                        level: .error
                    )
                    return
                }
            }

            guard let session = self.session else { return }
            var infoFlags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: VTDecodeFrameFlags(rawValue: 1 << 0),
                frameRefcon: nil,
                infoFlagsOut: &infoFlags
            )
            if status != noErr {
                self.diagnostics.addEvent("USB VideoToolbox decode: \(status)", level: .warning)
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
                let decoder = Unmanaged<USBVideoSampleDecoder>
                    .fromOpaque(refCon)
                    .takeUnretainedValue()
                decoder.diagnostics.recordVideoReceived(pts: presentationTime)
                decoder.frameStore.push(pixelBuffer: imageBuffer, presentationTime: presentationTime)
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
            throw USBVideoDecoderError.videoToolbox(status)
        }
        session = newSession
        VTSessionSetProperty(
            newSession,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", code)
    }

    private enum USBVideoDecoderError: LocalizedError {
        case videoToolbox(OSStatus)

        var errorDescription: String? {
            switch self {
            case .videoToolbox(let status):
                return "VTDecompressionSessionCreate вернул OSStatus \(status)"
            }
        }
    }
}
