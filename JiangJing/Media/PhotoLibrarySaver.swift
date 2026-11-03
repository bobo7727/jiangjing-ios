import Foundation
import Photos
import UIKit

enum SaveError: Error, Equatable {
    case denied
    case failed
    case deferredAuthorization
}

enum PhotoLibrarySaver {
    static func saveFile(at url: URL, kind: MediaRecord.Kind) async throws {
        try await ensureAddOnlyAccess()
        guard FileManager.default.fileExists(atPath: url.path) else { throw SaveError.failed }
        try await perform {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: kind == .photo ? .photo : .video, fileURL: url, options: nil)
        }
    }

    @MainActor private static func ensureAddOnlyAccess() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .authorized, .limited:
            return
        case .notDetermined:
            guard UIApplication.shared.applicationState == .active else {
                throw SaveError.deferredAuthorization
            }
            let granted = await requestAddOnly()
            if !granted { throw SaveError.denied }
        default:
            throw SaveError.denied
        }
    }

    @MainActor private static func requestAddOnly() async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status == .authorized || status == .limited)
            }
        }
    }

    private static func perform(_ changes: @escaping @Sendable () -> Void) async throws {
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
