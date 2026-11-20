import Darwin
import Foundation

enum FairPlayProviderError: LocalizedError {
    case libraryMissing(String)
    case symbolMissing(String)
    case contextCreationFailed
    case operationFailed(String, Int32)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .libraryMissing(let detail):
            return "FairPlay provider не загрузился: \(detail)"
        case .symbolMissing(let symbol):
            return "FairPlay provider не экспортирует \(symbol)"
        case .contextCreationFailed:
            return "FairPlay provider не смог создать session context"
        case .operationFailed(let operation, let code):
            return "FairPlay \(operation) завершился с кодом \(code)"
        case .invalidOutput(let operation):
            return "FairPlay \(operation) вернул некорректный результат"
        }
    }
}

/// Thin Swift owner for the source-level PlayFair provider bundled inside MirrorLab.app.
///
/// Important architectural property: this is *not* a subprocess and not an external
/// player. The GPL PlayFair source is compiled into one replaceable dylib exposing a
/// tiny C ABI. MirrorLab retains ownership of Bonjour, RTSP, media transport,
/// VideoToolbox, Metal, diagnostics, windows, and (later) CoreAudio.
final class EmbeddedFairPlayProvider {
    private typealias CreateFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias ResetFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias SetupFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int,
        UnsafeMutablePointer<UInt8>?, Int
    ) -> Int32
    private typealias HandshakeFn = SetupFn
    private typealias DecryptKeyFn = SetupFn
    private typealias PrepareVideoFn = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UInt64
    ) -> Int32
    private typealias DecryptVideoFn = SetupFn
    private typealias VideoReadyFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias DecryptAudioFn = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<UInt8>?, Int,
        UnsafePointer<UInt8>?, Int,
        UnsafePointer<UInt8>?, Int,
        UnsafeMutablePointer<UInt8>?, Int
    ) -> Int32
    private typealias VersionFn = @convention(c) () -> UnsafePointer<CChar>?

    private var libraryHandle: UnsafeMutableRawPointer?
    private var context: UnsafeMutableRawPointer?

    private var createFn: CreateFn?
    private var destroyFn: DestroyFn?
    private var resetFn: ResetFn?
    private var setupFn: SetupFn?
    private var handshakeFn: HandshakeFn?
    private var decryptKeyFn: DecryptKeyFn?
    private var prepareVideoFn: PrepareVideoFn?
    private var decryptVideoFn: DecryptVideoFn?
    private var videoReadyFn: VideoReadyFn?
    private var decryptAudioFn: DecryptAudioFn?
    private var versionFn: VersionFn?

    private(set) var loadError: String?
    private(set) var versionDescription = "PlayFair provider не загружен"

    init() {
        loadLibrary()
    }

    deinit {
        if let context {
            destroyFn?(context)
        }
        if let libraryHandle {
            dlclose(libraryHandle)
        }
    }

    var isAvailable: Bool {
        libraryHandle != nil && context != nil
    }

    var isVideoCryptoReady: Bool {
        guard let context, let videoReadyFn else { return false }
        return videoReadyFn(context) != 0
    }

    func reset() {
        guard let context else { return }
        resetFn?(context)
    }

    func setup(_ request: Data) throws -> Data {
        try fixedOutputOperation(
            name: "FPLY setup",
            request: request,
            outputCount: 142,
            function: setupFn
        )
    }

    func handshake(_ request: Data) throws -> Data {
        try fixedOutputOperation(
            name: "FPLY handshake",
            request: request,
            outputCount: 32,
            function: handshakeFn
        )
    }

    func decryptSessionKey(_ encryptedKey: Data) throws -> Data {
        try fixedOutputOperation(
            name: "session-key unwrap",
            request: encryptedKey,
            outputCount: 16,
            function: decryptKeyFn
        )
    }

    func prepareVideoCrypto(sessionKey: Data, streamConnectionID: UInt64) throws {
        guard let context else {
            throw FairPlayProviderError.libraryMissing(loadError ?? "context отсутствует")
        }
        guard let prepareVideoFn else {
            throw FairPlayProviderError.symbolMissing("mlfp_prepare_video_crypto")
        }
        guard sessionKey.count == 16 else {
            throw FairPlayProviderError.invalidOutput("session-key length")
        }

        let result: Int32 = sessionKey.withUnsafeBytes { raw in
            let pointer = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return prepareVideoFn(context, pointer, sessionKey.count, streamConnectionID)
        }
        guard result == 0 else {
            throw FairPlayProviderError.operationFailed("video-key derivation", result)
        }
    }

    func decryptVideo(_ encryptedPayload: Data) throws -> Data {
        guard let context else {
            throw FairPlayProviderError.libraryMissing(loadError ?? "context отсутствует")
        }
        guard let decryptVideoFn else {
            throw FairPlayProviderError.symbolMissing("mlfp_decrypt_video")
        }
        guard !encryptedPayload.isEmpty else { return Data() }

        let outputCapacity = encryptedPayload.count
        var output = Data(count: outputCapacity)
        let result: Int32 = encryptedPayload.withUnsafeBytes { inputRaw in
            output.withUnsafeMutableBytes { outputRaw in
                let input = inputRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                let destination = outputRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return decryptVideoFn(
                    context,
                    input,
                    encryptedPayload.count,
                    destination,
                    outputCapacity
                )
            }
        }

        guard result >= 0 else {
            throw FairPlayProviderError.operationFailed("video AES-CTR decrypt", result)
        }
        guard Int(result) == encryptedPayload.count else {
            throw FairPlayProviderError.invalidOutput("video AES-CTR decrypt")
        }
        return output
    }

    func decryptAudioCBC(_ encryptedPayload: Data, sessionKey: Data, iv: Data) throws -> Data {
        guard let context else {
            throw FairPlayProviderError.libraryMissing(loadError ?? "context отсутствует")
        }
        guard let decryptAudioFn else {
            throw FairPlayProviderError.symbolMissing("mlfp_decrypt_audio_cbc")
        }
        guard sessionKey.count == 16, iv.count == 16 else {
            throw FairPlayProviderError.invalidOutput("audio AES key/IV length")
        }
        guard !encryptedPayload.isEmpty else { return Data() }

        let outputCapacity = encryptedPayload.count
        var output = Data(count: outputCapacity)
        let result: Int32 = sessionKey.withUnsafeBytes { keyRaw in
            iv.withUnsafeBytes { ivRaw in
                encryptedPayload.withUnsafeBytes { inputRaw in
                    output.withUnsafeMutableBytes { outputRaw in
                        decryptAudioFn(
                            context,
                            keyRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            sessionKey.count,
                            ivRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            iv.count,
                            inputRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            encryptedPayload.count,
                            outputRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            outputCapacity
                        )
                    }
                }
            }
        }

        guard result >= 0 else {
            throw FairPlayProviderError.operationFailed("audio AES-CBC decrypt", result)
        }
        guard Int(result) == encryptedPayload.count else {
            throw FairPlayProviderError.invalidOutput("audio AES-CBC decrypt")
        }
        return output
    }

    private func fixedOutputOperation(
        name: String,
        request: Data,
        outputCount: Int,
        function: SetupFn?
    ) throws -> Data {
        guard let context else {
            throw FairPlayProviderError.libraryMissing(loadError ?? "context отсутствует")
        }
        guard let function else {
            throw FairPlayProviderError.symbolMissing(name)
        }

        var output = Data(count: outputCount)
        let result: Int32 = request.withUnsafeBytes { requestRaw in
            output.withUnsafeMutableBytes { outputRaw in
                let input = requestRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                let destination = outputRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return function(
                    context,
                    input,
                    request.count,
                    destination,
                    outputCount
                )
            }
        }

        guard result >= 0 else {
            throw FairPlayProviderError.operationFailed(name, result)
        }
        guard Int(result) == outputCount else {
            throw FairPlayProviderError.invalidOutput(name)
        }
        return output
    }

    private func loadLibrary() {
        let candidateURLs: [URL] = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libMirrorFairPlay.dylib"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Frameworks", isDirectory: true)
                .appendingPathComponent("libMirrorFairPlay.dylib")
        ].compactMap { $0 }

        var lastError = "libMirrorFairPlay.dylib не найден"
        for url in candidateURLs where FileManager.default.fileExists(atPath: url.path) {
            guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
                if let message = dlerror() {
                    lastError = String(cString: message)
                }
                continue
            }

            do {
                libraryHandle = handle
                createFn = try loadSymbol("mlfp_create", as: CreateFn.self)
                destroyFn = try loadSymbol("mlfp_destroy", as: DestroyFn.self)
                resetFn = try loadSymbol("mlfp_reset", as: ResetFn.self)
                setupFn = try loadSymbol("mlfp_setup", as: SetupFn.self)
                handshakeFn = try loadSymbol("mlfp_handshake", as: HandshakeFn.self)
                decryptKeyFn = try loadSymbol("mlfp_decrypt_session_key", as: DecryptKeyFn.self)
                prepareVideoFn = try loadSymbol("mlfp_prepare_video_crypto", as: PrepareVideoFn.self)
                decryptVideoFn = try loadSymbol("mlfp_decrypt_video", as: DecryptVideoFn.self)
                videoReadyFn = try loadSymbol("mlfp_video_crypto_ready", as: VideoReadyFn.self)
                decryptAudioFn = try loadSymbol("mlfp_decrypt_audio_cbc", as: DecryptAudioFn.self)
                versionFn = try loadSymbol("mlfp_version", as: VersionFn.self)

                guard let created = createFn?() else {
                    throw FairPlayProviderError.contextCreationFailed
                }
                context = created
                if let versionCString = versionFn?() {
                    versionDescription = String(cString: versionCString)
                } else {
                    versionDescription = "MirrorLab PlayFair Provider"
                }
                loadError = nil
                return
            } catch {
                lastError = error.localizedDescription
                if let context {
                    destroyFn?(context)
                    self.context = nil
                }
                dlclose(handle)
                libraryHandle = nil
            }
        }

        loadError = lastError
        versionDescription = "PlayFair недоступен: \(lastError)"
    }

    private func loadSymbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard let libraryHandle else {
            throw FairPlayProviderError.libraryMissing("dlopen не выполнен")
        }
        guard let symbol = dlsym(libraryHandle, name) else {
            throw FairPlayProviderError.symbolMissing(name)
        }
        return unsafeBitCast(symbol, to: type)
    }
}
