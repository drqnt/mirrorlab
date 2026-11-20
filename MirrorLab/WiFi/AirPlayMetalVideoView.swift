import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import SwiftUI

/// Wi-Fi playout policy for AirPlay mirror video.
///
/// AirPlay screen mirroring arrives over TCP, so a short Wi-Fi stall does not lose
/// frames: it delays them and then delivers them as a burst. The receiver can only hide
/// that with a playout buffer, and the right size depends on the network. MirrorLab now
/// measures it continuously and keeps it inside the bounds of the selected mode.
enum AirPlayBufferMode: String, CaseIterable, Identifiable {
    case lowLatency = "low-latency"
    case balanced = "balanced"
    case smooth = "smooth"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lowLatency: return "Мин. задержка"
        case .balanced: return "Баланс"
        case .smooth: return "Плавность"
        }
    }

    var detail: String {
        switch self {
        case .lowLatency:
            return "Видео 25–60 мс, звук от ~30 мс. Для игр при хорошем Wi-Fi; при помехах возможны рывки и щелчки."
        case .balanced:
            return "Видео 40–120 мс, звук от ~45 мс; оба подстраиваются под джиттер Wi-Fi. Рекомендуемый режим."
        case .smooth:
            return "Видео 70–250 мс, звук от ~80 мс. Самая ровная картинка и звук на загруженном Wi-Fi, но задержка заметнее."
        }
    }

    /// Lower bound of the adaptive playout delay.
    var minimumDelay: TimeInterval {
        switch self {
        case .lowLatency: return 0.025
        case .balanced: return 0.040
        case .smooth: return 0.070
        }
    }

    /// Upper bound of the adaptive playout delay. Longer Wi-Fi stalls are not hidden:
    /// overdue frames are skipped, so latency never grows past this bound.
    var maximumDelay: TimeInterval {
        switch self {
        case .lowLatency: return 0.060
        case .balanced: return 0.120
        case .smooth: return 0.250
        }
    }

    /// Share of recent frames that must arrive before their presentation slot.
    var coveredFraction: Double {
        switch self {
        case .lowLatency: return 0.90
        case .balanced: return 0.98
        case .smooth: return 0.995
        }
    }

    /// How long a measured jitter peak keeps the buffer large.
    var peakHold: TimeInterval {
        switch self {
        case .lowLatency: return 6
        case .balanced: return 10
        case .smooth: return 15
        }
    }
}

/// Adaptive receiver-side playout clock for AirPlay mirror video.
///
/// MirrorLab does not run the AirPlay NTP exchange, so the sender clock offset is
/// unknown. Up to 0.3.48 the whole timeline was anchored to the arrival of ONE frame
/// (+40 ms) and reset whenever a frame missed that anchor by 180 ms. On Wi-Fi that single
/// sample is arbitrary: usually it is the large first IDR, whose extra transfer time was
/// silently added to the whole session, and every burst longer than ~40 ms turned into
/// late-frame drops, holds or a queue-clearing reset.
///
/// This clock measures `offset = arrival - sourcePTS` for every decoded frame:
/// * the minimum over the last 3 s is the fastest path (unknown clock offset + base
///   network/decode delay); it follows clock drift and route changes on its own;
/// * `offset - minimum` is that frame's jitter; a high percentile of it, held for a few
///   seconds after a peak and bounded by the selected mode, becomes the playout delay;
/// * the delay grows at once when Wi-Fi becomes burstier and shrinks by 0.5 ms per
///   frame, so latency recovers without visible jumps. Small changes are ignored
///   (deadband) so the frame-to-vsync phase stays stable.
struct AirPlayPlayoutClock {
    private struct Sample {
        let arrival: TimeInterval
        let offset: Double
    }

    private struct Peak {
        let arrival: TimeInterval
        let value: TimeInterval
    }

    static let window: TimeInterval = 3.0
    static let minimumSamplesForEstimate = 30
    static let maximumSamples = 720
    static let safetyMargin: TimeInterval = 0.004
    static let growDeadband: TimeInterval = 0.004
    static let shrinkDeadband: TimeInterval = 0.008
    static let shrinkPerFrame: TimeInterval = 0.0005
    static let snapThreshold: TimeInterval = 0.150
    static let discontinuityThreshold: TimeInterval = 10.0

    var mode: AirPlayBufferMode {
        didSet {
            guard mode != oldValue else { return }
            peaks.removeAll(keepingCapacity: true)
            peakHead = 0
            targetDelay = Self.clamp(targetDelay, to: mode)
        }
    }

    private(set) var playoutOffset: Double?
    private(set) var baseOffset: Double = 0
    private(set) var targetDelay: TimeInterval
    private(set) var measuredJitter: TimeInterval = 0
    private(set) var discontinuities: UInt64 = 0

    private var samples: [Sample] = []
    private var peaks: [Peak] = []
    private var peakHead = 0
    private var scratch: [Double] = []

    init(mode: AirPlayBufferMode) {
        self.mode = mode
        self.targetDelay = Self.initialDelay(for: mode)
    }

    /// Delay currently applied on top of the fastest observed path.
    var effectiveDelay: TimeInterval {
        guard let playoutOffset else { return targetDelay }
        return max(0, playoutOffset - baseOffset)
    }

    func scheduledHostTime(sourceSeconds: Double) -> TimeInterval? {
        guard let playoutOffset else { return nil }
        return sourceSeconds + playoutOffset
    }

    mutating func reset(keepingDelayEstimate: Bool) {
        playoutOffset = nil
        baseOffset = 0
        measuredJitter = 0
        samples.removeAll(keepingCapacity: true)
        peaks.removeAll(keepingCapacity: true)
        peakHead = 0
        if !keepingDelayEstimate {
            targetDelay = Self.initialDelay(for: mode)
            discontinuities = 0
        }
    }

    /// Feeds one decoded frame. Returns true when a running timeline had to be
    /// re-anchored because the source clock jumped by more than 10 s.
    @discardableResult
    mutating func observe(sourceSeconds: Double, arrival: TimeInterval) -> Bool {
        let offset = arrival - sourceSeconds
        guard let currentPlayout = playoutOffset,
              abs(offset - baseOffset) <= Self.discontinuityThreshold else {
            let wasRunning = playoutOffset != nil
            samples.removeAll(keepingCapacity: true)
            peaks.removeAll(keepingCapacity: true)
            peakHead = 0
            samples.append(Sample(arrival: arrival, offset: offset))
            baseOffset = offset
            playoutOffset = offset + targetDelay
            if wasRunning { discontinuities &+= 1 }
            return wasRunning
        }

        samples.append(Sample(arrival: arrival, offset: offset))
        let cutoff = arrival - Self.window
        var expired = 0
        while expired < samples.count - 1 && samples[expired].arrival < cutoff {
            expired += 1
        }
        if samples.count - expired > Self.maximumSamples {
            expired = samples.count - Self.maximumSamples
        }
        if expired > 0 {
            samples.removeFirst(expired)
        }

        var minimum = offset
        for sample in samples where sample.offset < minimum {
            minimum = sample.offset
        }
        baseOffset = minimum

        if samples.count >= Self.minimumSamplesForEstimate {
            scratch.removeAll(keepingCapacity: true)
            for sample in samples {
                scratch.append(sample.offset - minimum)
            }
            scratch.sort()
            let rank = (Double(scratch.count - 1) * mode.coveredFraction).rounded(.up)
            let percentile = scratch[min(scratch.count - 1, Int(rank))]
            measuredJitter = percentile
            targetDelay = Self.clamp(holdPeak(percentile, at: arrival) + Self.safetyMargin, to: mode)
        }

        let desired = baseOffset + targetDelay
        if desired - currentPlayout > Self.growDeadband {
            playoutOffset = desired
        } else if currentPlayout - desired > Self.shrinkDeadband {
            let excess = currentPlayout - desired
            playoutOffset = excess > Self.snapThreshold
                ? desired
                : currentPlayout - min(excess - Self.shrinkDeadband, Self.shrinkPerFrame)
        }
        return false
    }

    /// Sliding-window maximum (monotonic deque) of the per-frame jitter percentile.
    private mutating func holdPeak(_ value: TimeInterval, at arrival: TimeInterval) -> TimeInterval {
        while peaks.count > peakHead, let last = peaks.last, last.value <= value {
            peaks.removeLast()
        }
        peaks.append(Peak(arrival: arrival, value: value))
        let cutoff = arrival - mode.peakHold
        while peakHead < peaks.count - 1 && peaks[peakHead].arrival < cutoff {
            peakHead += 1
        }
        if peakHead > 256 {
            peaks.removeFirst(peakHead)
            peakHead = 0
        }
        return peaks[peakHead].value
    }

    private static func initialDelay(for mode: AirPlayBufferMode) -> TimeInterval {
        (mode.minimumDelay + mode.maximumDelay) / 2
    }

    private static func clamp(_ value: TimeInterval, to mode: AirPlayBufferMode) -> TimeInterval {
        min(max(value, mode.minimumDelay), mode.maximumDelay)
    }
}

/// Shared timestamp-driven presentation queue for every AirPlay preview surface.
///
/// The sender's NTP cadence is preserved, but the playout delay comes from
/// `AirPlayPlayoutClock` (adaptive, bounded by `AirPlayBufferMode`) instead of a fixed
/// 40 ms margin anchored to a single frame. Overdue frames are skipped rather than
/// replayed faster than real time, so a stall longer than the buffer becomes one jump
/// back to live instead of slow-motion catch-up.
final class AirPlayPresentationStore: @unchecked Sendable {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
        let sourceSeconds: Double
        let arrivalHostTime: TimeInterval
        let sequence: UInt64
    }

    struct State {
        let queueDepth: Int
        let targetLatencyMS: Double
        let droppedFrames: UInt64
        let lastLatenessMS: Double?
        let jitterMS: Double
        let lateFrames: UInt64
        let timelineResets: UInt64
        let bufferMode: AirPlayBufferMode
    }

    private let lock = NSLock()
    private var queue: [Frame] = []
    private var currentFrame: Frame?
    // Monotonic for the whole app lifetime. Renderers remember the last sequence they
    // drew; restarting it at 0 (old resetForNewSession) froze an already open Preview
    // after a quality/FPS change or a sender takeover until it passed the old value.
    private var nextSequence: UInt64 = 0
    private var clock = AirPlayPlayoutClock(mode: .balanced)
    private var droppedFrames: UInt64 = 0
    private var lateFrames: UInt64 = 0
    private var lastLatenessMS: Double?

    /// An overdue frame is skipped only when it is later than this AND a newer frame
    /// is already due. Smaller lateness is absorbed (frame-to-vsync phase noise).
    private let catchUpThreshold: TimeInterval = 0.020
    private let dueTolerance: TimeInterval = 0.0015

    private var maxQueuedFrames: Int {
        Int((clock.mode.maximumDelay * 60).rounded(.up)) + 12
    }

    var bufferMode: AirPlayBufferMode {
        lock.lock()
        defer { lock.unlock() }
        return clock.mode
    }

    func setBufferMode(_ mode: AirPlayBufferMode) {
        lock.lock()
        clock.mode = mode
        lock.unlock()
    }

    func enqueue(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard presentationTime.isNumeric else { return }
        let sourceSeconds = CMTimeGetSeconds(presentationTime)
        guard sourceSeconds.isFinite else { return }
        let arrival = CACurrentMediaTime()

        lock.lock()
        defer { lock.unlock() }

        if clock.observe(sourceSeconds: sourceSeconds, arrival: arrival) {
            // The sender clock jumped: frames queued on the old timeline can never be
            // ordered against the new one. The current picture stays on screen.
            droppedFrames &+= UInt64(queue.count)
            queue.removeAll(keepingCapacity: true)
        }

        nextSequence &+= 1
        let frame = Frame(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            sourceSeconds: sourceSeconds,
            arrivalHostTime: arrival,
            sequence: nextSequence
        )

        if let last = queue.last, last.sourceSeconds <= sourceSeconds {
            queue.append(frame)
        } else {
            let index = queue.firstIndex { $0.sourceSeconds > sourceSeconds } ?? queue.endIndex
            queue.insert(frame, at: index)
        }

        let limit = maxQueuedFrames
        if queue.count > limit {
            let overflow = queue.count - limit
            queue.removeFirst(overflow)
            droppedFrames &+= UInt64(overflow)
        }
    }

    /// Returns the frame that should be visible at `hostTime` (the display link's target
    /// presentation time) while preserving the sender's cadence. If the receiver falls
    /// behind, overdue frames are discarded rather than replayed faster than real time.
    func frameForPresentation(hostTime: TimeInterval, after sequence: UInt64) -> Frame? {
        lock.lock()
        defer { lock.unlock() }

        guard clock.playoutOffset != nil else {
            return currentFrame.flatMap { $0.sequence > sequence ? $0 : nil }
        }

        // Drop only frames that are definitely too late and have a newer frame ready.
        while queue.count > 1,
              let firstDue = clock.scheduledHostTime(sourceSeconds: queue[0].sourceSeconds),
              let secondDue = clock.scheduledHostTime(sourceSeconds: queue[1].sourceSeconds),
              firstDue < hostTime - catchUpThreshold,
              secondDue <= hostTime + dueTolerance {
            queue.removeFirst()
            droppedFrames &+= 1
        }

        if let first = queue.first,
           let scheduled = clock.scheduledHostTime(sourceSeconds: first.sourceSeconds),
           scheduled <= hostTime + dueTolerance {
            currentFrame = queue.removeFirst()
            let lateness = max(0, hostTime - scheduled)
            lastLatenessMS = lateness * 1_000
            if lateness > catchUpThreshold {
                lateFrames &+= 1
            }
        }

        guard let currentFrame, currentFrame.sequence > sequence else { return nil }
        return currentFrame
    }

    /// Non-destructive fan-out for secondary preview windows. Only the primary
    /// renderer advances the timestamp queue; external previews only display the
    /// frame already selected by the primary renderer.
    func frameForObserver(after sequence: UInt64) -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        guard let currentFrame, currentFrame.sequence > sequence else { return nil }
        return currentFrame
    }


    func currentDimensions() -> (width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let currentFrame else { return nil }
        return (
            width: CVPixelBufferGetWidth(currentFrame.pixelBuffer),
            height: CVPixelBufferGetHeight(currentFrame.pixelBuffer)
        )
    }

    /// Format change / rotation / wake inside one session: restart the timeline but keep
    /// the learned Wi-Fi jitter level, so the buffer does not have to re-learn it.
    func clear() {
        lock.lock()
        queue.removeAll(keepingCapacity: true)
        currentFrame = nil
        lastLatenessMS = nil
        clock.reset(keepingDelayEstimate: true)
        lock.unlock()
    }

    /// New sender/receiver session boundary. Format changes inside one live session
    /// still use clear(), so their intentional catch-up history remains visible; a
    /// genuinely new mirroring session starts with clean presentation accounting.
    func resetForNewSession() {
        lock.lock()
        queue.removeAll(keepingCapacity: true)
        currentFrame = nil
        lastLatenessMS = nil
        clock.reset(keepingDelayEstimate: false)
        droppedFrames = 0
        lateFrames = 0
        lock.unlock()
    }

    func state() -> State {
        lock.lock()
        defer { lock.unlock() }
        return State(
            queueDepth: queue.count,
            targetLatencyMS: clock.effectiveDelay * 1_000,
            droppedFrames: droppedFrames,
            lastLatenessMS: lastLatenessMS,
            jitterMS: clock.measuredJitter * 1_000,
            lateFrames: lateFrames,
            timelineResets: clock.discontinuities,
            bufferMode: clock.mode
        )
    }
}

/// CAMetalLayer-backed AppKit view. CAMetalDisplayLink is layer-owned and supplies
/// the drawable for each scheduled layer update. 0.3.40 intentionally restores this
/// path from the 0.3.10 golden-smooth build after 0.3.39 again showed ~60 decoded
/// source FPS but roughly half as many unique primary commits on the CVDisplayLink path.
final class AirPlayMetalHostView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    var metalLayer: CAMetalLayer? {
        layer as? CAMetalLayer
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    func updateDrawableSize() {
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let size = CGSize(
            width: max(bounds.width * scale, 1),
            height: max(bounds.height * scale, 1)
        )
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }
}

/// AirPlay-only zero-copy NV12 renderer.
/// USB intentionally remains on the proven CoreImage-based MetalVideoView.
struct AirPlayMetalVideoView: NSViewRepresentable {
    let presentationStore: AirPlayPresentationStore
    let diagnostics: DiagnosticsStore
    var recordsDiagnostics = true

    func makeCoordinator() -> Coordinator {
        Coordinator(
            presentationStore: presentationStore,
            diagnostics: diagnostics,
            recordsDiagnostics: recordsDiagnostics
        )
    }

    func makeNSView(context: Context) -> AirPlayMetalHostView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal недоступен на этом Mac")
        }

        let view = AirPlayMetalHostView(frame: .zero)
        view.updateDrawableSize()
        context.coordinator.configure(device: device, view: view)
        return view
    }

    func updateNSView(_ nsView: AirPlayMetalHostView, context: Context) {
        nsView.updateDrawableSize()
    }

    static func dismantleNSView(_ nsView: AirPlayMetalHostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, CAMetalDisplayLinkDelegate {
        private let presentationStore: AirPlayPresentationStore
        private let diagnostics: DiagnosticsStore
        private let recordsDiagnostics: Bool

        private var commandQueue: MTLCommandQueue?
        private var textureCache: CVMetalTextureCache?
        private var videoRangePipeline: MTLRenderPipelineState?
        private var fullRangePipeline: MTLRenderPipelineState?
        private var sampler: MTLSamplerState?
        private var displayLink: CAMetalDisplayLink?
        private var lastGeneration: UInt64 = 0
        private var lastSourceDescription = ""
        private var externalRenderTimes: [TimeInterval] = []
        private var lastExternalPublish: TimeInterval = 0

        init(
            presentationStore: AirPlayPresentationStore,
            diagnostics: DiagnosticsStore,
            recordsDiagnostics: Bool
        ) {
            self.presentationStore = presentationStore
            self.diagnostics = diagnostics
            self.recordsDiagnostics = recordsDiagnostics
        }

        func configure(device: MTLDevice, view: AirPlayMetalHostView) {
            guard let layer = view.metalLayer else { return }
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = true
            layer.isOpaque = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.presentsWithTransaction = false
            layer.maximumDrawableCount = 2
            layer.allowsNextDrawableTimeout = true
            view.updateDrawableSize()

            commandQueue = device.makeCommandQueue()

            var cache: CVMetalTextureCache?
            let cacheStatus = CVMetalTextureCacheCreate(
                kCFAllocatorDefault,
                nil,
                device,
                nil,
                &cache
            )
            if cacheStatus == kCVReturnSuccess {
                textureCache = cache
            } else {
                diagnostics.addEvent(
                    "AirPlay Metal: CVMetalTextureCache error \(cacheStatus)",
                    level: .error
                )
            }

            do {
                let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
                guard let vertex = library.makeFunction(name: "mirror_vertex"),
                      let videoFragment = library.makeFunction(name: "nv12_video_fragment"),
                      let fullFragment = library.makeFunction(name: "nv12_full_fragment") else {
                    diagnostics.addEvent("AirPlay Metal: shader functions не найдены", level: .error)
                    return
                }

                videoRangePipeline = try Self.makePipeline(
                    device: device,
                    vertex: vertex,
                    fragment: videoFragment,
                    pixelFormat: layer.pixelFormat
                )
                fullRangePipeline = try Self.makePipeline(
                    device: device,
                    vertex: vertex,
                    fragment: fullFragment,
                    pixelFormat: layer.pixelFormat
                )

                let samplerDescriptor = MTLSamplerDescriptor()
                samplerDescriptor.minFilter = .linear
                samplerDescriptor.magFilter = .linear
                samplerDescriptor.mipFilter = .notMipmapped
                samplerDescriptor.sAddressMode = .clampToEdge
                samplerDescriptor.tAddressMode = .clampToEdge
                samplerDescriptor.normalizedCoordinates = true
                sampler = device.makeSamplerState(descriptor: samplerDescriptor)
            } catch {
                diagnostics.addEvent(
                    "AirPlay Metal shader: \(error.localizedDescription)",
                    level: .error
                )
            }

            // 0.3.40 deliberately returns to the layer-owned CAMetalDisplayLink path
            // used by the 0.3.10 golden-smooth build. Unlike the generic CVDisplayLink
            // path, CAMetalDisplayLink hands us the drawable for the exact layer update,
            // so there is no separate nextDrawable() acquisition that can drift from
            // ProMotion/WindowServer pacing or silently lose a selected source frame.
            let link = CAMetalDisplayLink(metalLayer: layer)
            link.delegate = self
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60,
                maximum: 120,
                preferred: 120
            )
            link.preferredFrameLatency = 1.0
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func detach() {
            displayLink?.invalidate()
            displayLink = nil
            if !recordsDiagnostics {
                diagnostics.setExternalRenderedFPS(nil)
            }
            if let textureCache {
                CVMetalTextureCacheFlush(textureCache, 0)
            }
            textureCache = nil
        }

        func metalDisplayLink(
            _ link: CAMetalDisplayLink,
            needsUpdate update: CAMetalDisplayLink.Update
        ) {
            autoreleasepool {
                let frame: AirPlayPresentationStore.Frame?
                if recordsDiagnostics {
                    // Select for the moment this drawable actually reaches the
                    // screen, not for the callback time (~1 refresh earlier).
                    frame = presentationStore.frameForPresentation(
                        hostTime: update.targetPresentationTimestamp,
                        after: lastGeneration
                    )
                } else {
                    frame = presentationStore.frameForObserver(after: lastGeneration)
                }
                guard let frame else { return }
                render(frame: frame, drawable: update.drawable)
            }
        }

        private func render(frame: AirPlayPresentationStore.Frame, drawable: CAMetalDrawable) {
            let pixelBuffer = frame.pixelBuffer
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let isVideoRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let isFullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            guard isVideoRange || isFullRange else {
                logSourceIfNeeded(pixelBuffer: pixelBuffer, suffix: "unsupported pixel format \(pixelFormat)")
                return
            }

            guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
                  let textureCache,
                  let commandQueue,
                  let pipeline = isVideoRange ? videoRangePipeline : fullRangePipeline,
                  let sampler else { return }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard width > 0, height > 0 else { return }

            var yTextureRef: CVMetalTexture?
            var uvTextureRef: CVMetalTexture?
            let yStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .r8Unorm,
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                0,
                &yTextureRef
            )
            let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .rg8Unorm,
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                1,
                &uvTextureRef
            )
            guard yStatus == kCVReturnSuccess,
                  uvStatus == kCVReturnSuccess,
                  let yTextureRef,
                  let uvTextureRef,
                  let yTexture = CVMetalTextureGetTexture(yTextureRef),
                  let uvTexture = CVMetalTextureGetTexture(uvTextureRef),
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return }

            let passDescriptor = MTLRenderPassDescriptor()
            passDescriptor.colorAttachments[0].texture = drawable.texture
            passDescriptor.colorAttachments[0].loadAction = .clear
            passDescriptor.colorAttachments[0].storeAction = .store
            passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.015, 0.018, 0.025, 1.0)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(yTexture, index: 0)
            encoder.setFragmentTexture(uvTexture, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)

            let destinationWidth = max(Double(drawable.texture.width), 1)
            let destinationHeight = max(Double(drawable.texture.height), 1)
            let sourceAspect = Float(Double(width) / Double(height))
            let destinationAspect = Float(destinationWidth / destinationHeight)
            var contentScale: SIMD2<Float>
            if destinationAspect > sourceAspect {
                contentScale = SIMD2<Float>(sourceAspect / destinationAspect, 1)
            } else {
                contentScale = SIMD2<Float>(1, destinationAspect / sourceAspect)
            }
            encoder.setVertexBytes(
                &contentScale,
                length: MemoryLayout<SIMD2<Float>>.stride,
                index: 0
            )
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            commandBuffer.addCompletedHandler { _ in
                _ = yTextureRef
                _ = uvTextureRef
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()

            lastGeneration = frame.sequence
            logSourceIfNeeded(
                pixelBuffer: pixelBuffer,
                suffix: isVideoRange ? "NV12 video-range → CAMetalDisplayLink" : "NV12 full-range → CAMetalDisplayLink"
            )

            if recordsDiagnostics {
                diagnostics.recordVideoRendered()
                let pacing = presentationStore.state()
                diagnostics.setPresentationState(
                    queueDepth: pacing.queueDepth,
                    targetLatencyMS: pacing.targetLatencyMS,
                    droppedFrames: pacing.droppedFrames,
                    latenessMS: pacing.lastLatenessMS
                )
            } else {
                recordExternalRender()
            }
        }

        private func logSourceIfNeeded(pixelBuffer: CVPixelBuffer, suffix: String) {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let description = "\(width)×\(height) \(suffix)"
            guard description != lastSourceDescription else { return }
            lastSourceDescription = description
            diagnostics.addEvent("AirPlay renderer: \(description)")
        }

        private func recordExternalRender() {
            let now = CACurrentMediaTime()
            externalRenderTimes.append(now)
            externalRenderTimes.removeAll { $0 < now - 1.0 }
            if now - lastExternalPublish >= 0.25 {
                lastExternalPublish = now
                diagnostics.setExternalRenderedFPS(Double(externalRenderTimes.count))
            }
        }

        private static func makePipeline(
            device: MTLDevice,
            vertex: MTLFunction,
            fragment: MTLFunction,
            pixelFormat: MTLPixelFormat
        ) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        private static let shaderSource = #"""
        #include <metal_stdlib>
        using namespace metal;

        struct RasterizerData {
            float4 position [[position]];
            float2 uv;
        };

        vertex RasterizerData mirror_vertex(
            uint vertexID [[vertex_id]],
            constant float2 &contentScale [[buffer(0)]])
        {
            constexpr float2 positions[4] = {
                float2(-1.0,  1.0),
                float2(-1.0, -1.0),
                float2( 1.0,  1.0),
                float2( 1.0, -1.0)
            };
            constexpr float2 texcoords[4] = {
                float2(0.0, 0.0),
                float2(0.0, 1.0),
                float2(1.0, 0.0),
                float2(1.0, 1.0)
            };

            RasterizerData out;
            out.position = float4(positions[vertexID] * contentScale, 0.0, 1.0);
            out.uv = texcoords[vertexID];
            return out;
        }

        inline float3 bt709_video_rgb(float ySample, float2 cbcrSample) {
            // ITU-R BT.709 limited/video-range Y'CbCr. AirPlay's H.264
            // VideoToolbox output is requested as kCVPixelFormatType_420v.
            float y  = ySample - (16.0 / 255.0);
            float cb = cbcrSample.x - (128.0 / 255.0);
            float cr = cbcrSample.y - (128.0 / 255.0);
            return clamp(float3(
                1.164383 * y + 1.792741 * cr,
                1.164383 * y - 0.213249 * cb - 0.532909 * cr,
                1.164383 * y + 2.112402 * cb
            ), 0.0, 1.0);
        }

        inline float3 bt709_full_rgb(float y, float2 cbcrSample) {
            float cb = cbcrSample.x - 0.5;
            float cr = cbcrSample.y - 0.5;
            return clamp(float3(
                y + 1.5748 * cr,
                y - 0.187324 * cb - 0.468124 * cr,
                y + 1.8556 * cb
            ), 0.0, 1.0);
        }

        fragment float4 nv12_video_fragment(
            RasterizerData in [[stage_in]],
            texture2d<float, access::sample> yTexture [[texture(0)]],
            texture2d<float, access::sample> uvTexture [[texture(1)]],
            sampler linearSampler [[sampler(0)]])
        {
            float y = yTexture.sample(linearSampler, in.uv).r;
            float2 cbcr = uvTexture.sample(linearSampler, in.uv).rg;
            return float4(bt709_video_rgb(y, cbcr), 1.0);
        }

        fragment float4 nv12_full_fragment(
            RasterizerData in [[stage_in]],
            texture2d<float, access::sample> yTexture [[texture(0)]],
            texture2d<float, access::sample> uvTexture [[texture(1)]],
            sampler linearSampler [[sampler(0)]])
        {
            float y = yTexture.sample(linearSampler, in.uv).r;
            float2 cbcr = uvTexture.sample(linearSampler, in.uv).rg;
            return float4(bt709_full_rgb(y, cbcr), 1.0);
        }
        """#
    }
}
