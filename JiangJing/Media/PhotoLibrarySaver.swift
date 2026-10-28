import Foundation
import Photos

enum SaveError: Error, Equatable {
    case denied
    case failed
}

enum FileStore {
    static func makeURL(ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let directory = FileManager.default.temporaryDirectory
        let base = directory.appendingPathComponent("匠镜-\(stamp).\(ext)")
        if !FileManager.default.fileExists(atPath: base.path) {
            return base
        }
        let suffix = String(UUID().uuidString.prefix(4))
        return directory.appendingPathComponent("匠镜-\(stamp)-\(suffix).\(ext)")
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

enum PhotoLibrarySaver {
    static func saveImageData(_ data: Data) async throws {
        try await ensureAddOnlyAccess()
        try await perform {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }

    static func saveVideo(at url: URL) async throws {
        try await ensureAddOnlyAccess()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SaveError.failed
        }
        try await perform {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    private static func ensureAddOnlyAccess() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = await requestAddOnly()
            if !granted { throw SaveError.denied }
        default:
            throw SaveError.denied
        }
    }

    private static func requestAddOnly() async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status == .authorized || status == .limited)
            }
        }
    }

    private static func perform(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SaveError.failed)
                }
            }
        }
    }
}
