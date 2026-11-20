import CoreImage
import CoreMedia
import MetalKit
import SwiftUI

struct MetalVideoView: NSViewRepresentable {
    let frameStore: LatestVideoFrameStore
    let diagnostics: DiagnosticsStore
    var recordsDiagnostics = true

    func makeCoordinator() -> Coordinator {
        Coordinator(
            frameStore: frameStore,
            diagnostics: diagnostics,
            recordsDiagnostics: recordsDiagnostics
        )
    }

    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal недоступен на этом Mac")
        }

        let view = MTKView(frame: .zero, device: device)
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 60

        // Drive rendering from incoming frames instead of MTKView's private
        // continuous loop. AppKit may throttle a secondary SwiftUI window;
        // explicit invalidation makes every active preview receive every newest
        // frame independently.
        view.isPaused = true
        view.enableSetNeedsDisplay = true

        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.015, 0.018, 0.025, 1.0)
        view.autoResizeDrawable = true

        context.coordinator.configure(device: device)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.detach()
        nsView.delegate = nil
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private let frameStore: LatestVideoFrameStore
        private let diagnostics: DiagnosticsStore
        private let recordsDiagnostics: Bool
        private var commandQueue: MTLCommandQueue?
        private var ciContext: CIContext?
        private let colorSpace =
            CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        private var lastGeneration: UInt64 = 0
        private var observerID: UUID?

        init(
            frameStore: LatestVideoFrameStore,
            diagnostics: DiagnosticsStore,
            recordsDiagnostics: Bool
        ) {
            self.frameStore = frameStore
            self.diagnostics = diagnostics
            self.recordsDiagnostics = recordsDiagnostics
        }

        func configure(device: MTLDevice) {
            commandQueue = device.makeCommandQueue()
            ciContext = CIContext(
                mtlDevice: device,
                options: [
                    .cacheIntermediates: false
                ]
            )
        }

        func attach(to view: MTKView) {
            detach()
            observerID = frameStore.addObserver { [weak view] in
                guard let view else { return }
                DispatchQueue.main.async {
                    view.setNeedsDisplay(view.bounds)
                }
            }
        }

        func detach() {
            frameStore.removeObserver(observerID)
            observerID = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let frame = frameStore.latest(after: lastGeneration),
                  let drawable = view.currentDrawable,
                  let passDescriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let ciContext else { return }

            if let clearEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
                clearEncoder.endEncoding()
            }

            let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
            guard source.extent.width > 0, source.extent.height > 0 else { return }

            let destination = CGRect(origin: .zero, size: view.drawableSize)
            let scale = min(
                destination.width / source.extent.width,
                destination.height / source.extent.height
            )
            let normalized = source.transformed(
                by: CGAffineTransform(
                    translationX: -source.extent.origin.x,
                    y: -source.extent.origin.y
                )
            )
            let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let offsetX = (destination.width - scaled.extent.width) * 0.5
            let offsetY = (destination.height - scaled.extent.height) * 0.5
            let positioned = scaled.transformed(
                by: CGAffineTransform(translationX: offsetX, y: offsetY)
            )

            ciContext.render(
                positioned,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: destination,
                colorSpace: colorSpace
            )
            commandBuffer.present(drawable)
            commandBuffer.commit()

            let skipped = lastGeneration > 0 && frame.generation > lastGeneration + 1
                ? frame.generation - lastGeneration - 1
                : 0
            lastGeneration = frame.generation
            if recordsDiagnostics {
                diagnostics.recordVideoRendered(skipped: skipped)
            }
        }
    }
}
