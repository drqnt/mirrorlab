import CoreMedia
import CoreVideo
import Foundation

struct StoredVideoFrame {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let generation: UInt64
}

final class LatestVideoFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latestFrame: StoredVideoFrame?
    private var generation: UInt64 = 0
    private var observers: [UUID: () -> Void] = [:]

    func push(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let callbacks: [() -> Void]

        lock.lock()
        generation &+= 1
        latestFrame = StoredVideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            generation: generation
        )
        callbacks = Array(observers.values)
        lock.unlock()

        // Fan the same newest-frame notification out to every render surface.
        // This keeps the embedded preview and the clean OBS/Discord preview live
        // at the same time instead of letting one window "consume" presentation.
        for callback in callbacks {
            callback()
        }
    }


    func currentDimensions() -> (width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let latestFrame else { return nil }
        return (
            width: CVPixelBufferGetWidth(latestFrame.pixelBuffer),
            height: CVPixelBufferGetHeight(latestFrame.pixelBuffer)
        )
    }

    func latest(after generation: UInt64) -> StoredVideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard let latestFrame, latestFrame.generation > generation else { return nil }
        return latestFrame
    }

    @discardableResult
    func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        let hasFrame = latestFrame != nil
        lock.unlock()

        if hasFrame {
            observer()
        }
        return id
    }

    func removeObserver(_ id: UUID?) {
        guard let id else { return }
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        latestFrame = nil
        lock.unlock()
    }
}
