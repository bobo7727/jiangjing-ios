import UIKit
import XCTest
@testable import JiangJing

@MainActor
final class LabelExporterTests: XCTestCase {
    private let bundle = "com.jiangjing.magnifier"

    private struct Fixture {
        let exporter: LabelExporter
        let media: MediaLibraryModel
        let source: URL
        let directory: URL
        let saved: SavedBox
    }

    final class SavedBox: @unchecked Sendable { var count = 0 }

    private func makeFixture(status: EntitlementQuery) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("label-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = MediaJournal(directory: directory.appendingPathComponent("media"))
        let saved = SavedBox()
        let media = MediaLibraryModel(journal: journal, isActive: { true }) { _, _ in saved.count += 1 }
        let source = directory.appendingPathComponent("source.jpg")
        let size = CGSize(width: 400, height: 300)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        try image.jpegData(compressionQuality: 0.9)!.write(to: source)
        let backend = MockStoreBackend()
        backend.set(entitlements: status)
        let store = StoreManager(backend: backend, bundleID: bundle)
        return Fixture(exporter: LabelExporter(store: store, media: media), media: media,
                       source: source, directory: directory, saved: saved)
    }

    private let style = LabelStyle(name: "Ana Studio", showDate: false, position: .bottomRight)

    private func pro() -> Entitlement {
        Entitlement(productID: StoreCatalog.proID, bundleID: bundle, isVerified: true, isRevoked: false)
    }

    func testLockedWritesNothing() async throws {
        let f = try makeFixture(status: .completed([]))
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let before = try Data(contentsOf: f.source)
        let result = await f.exporter.export(sourceURL: f.source, style: style)
        XCTAssertEqual(result, .needsPro)
        XCTAssertTrue(f.media.records.isEmpty)
        XCTAssertEqual(f.saved.count, 0)
        XCTAssertEqual(try Data(contentsOf: f.source), before)
    }

    func testUnknownStatusWritesNothingAndOffersNoPurchase() async throws {
        let f = try makeFixture(status: .failed)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let result = await f.exporter.export(sourceURL: f.source, style: style)
        XCTAssertEqual(result, .checking)
        XCTAssertTrue(f.media.records.isEmpty)
    }

    func testUnlockedWritesANewCopySavesItAndKeepsTheOriginal() async throws {
        let f = try makeFixture(status: .completed([pro()]))
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let before = try Data(contentsOf: f.source)
        let result = await f.exporter.export(sourceURL: f.source, style: style)
        guard case .exported(let id) = result else { return XCTFail("\(result)") }
        let record = try XCTUnwrap(f.media.record(id))
        XCTAssertEqual(record.kind, .photo)
        XCTAssertTrue(record.isComplete)
        XCTAssertEqual(record.saveState, .saved)
        XCTAssertEqual(f.saved.count, 1, "the labeled copy is auto-saved to Photos")
        let copy = try Data(contentsOf: f.media.url(for: record))
        XCTAssertNotEqual(copy, before)
        XCTAssertNotNil(UIImage(data: copy))
        XCTAssertEqual(try Data(contentsOf: f.source), before, "the original photo is never modified")
    }

    func testEmptyLabelIsRejected() async throws {
        let f = try makeFixture(status: .completed([pro()]))
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let result = await f.exporter.export(sourceURL: f.source, style: LabelStyle())
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(f.media.records.isEmpty)
    }

    func testRendererOutputKeepsPixelSizeAndChangesPixels() throws {
        let size = CGSize(width: 200, height: 100)
        for scale in [CGFloat(1), 2, 3] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let base = UIGraphicsImageRenderer(size: size, format: format).image { UIColor.white.setFill(); $0.fill(CGRect(origin: .zero, size: size)) }
            let stamped = LabelRenderer.render(image: base, text: "Ana", position: .bottomLeft)
            XCTAssertEqual(stamped.size.width * stamped.scale, base.size.width * base.scale, "scale \(scale)")
            XCTAssertEqual(stamped.size.height * stamped.scale, base.size.height * base.scale, "scale \(scale)")
            XCTAssertNotEqual(stamped.pngData(), LabelRenderer.render(image: base, text: "", position: .bottomLeft).pngData())
        }
    }
}
