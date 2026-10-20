import XCTest
import SwiftUI
import PersonalAICore
@testable import PersonalAIApp

/// WCAG relative luminance contrast, so the design system's colour pairs are checked rather than eyeballed.
enum Contrast {
    static func luminance(_ hex: UInt32) -> Double {
        func c(_ v: UInt32) -> Double { let s = Double(v) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * c((hex >> 16) & 0xFF) + 0.7152 * c((hex >> 8) & 0xFF) + 0.0722 * c(hex & 0xFF)
    }
    static func ratio(_ a: UInt32, _ b: UInt32) -> Double { let (x, y) = (luminance(a), luminance(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
}

final class DesignTests: XCTestCase {
    func testBodyTextPairsMeetWCAGAA() {
        let aa = 4.5
        XCTAssertGreaterThanOrEqual(Contrast.ratio(PBHex.ink, PBHex.cream), aa, "body on everyday scene")
        XCTAssertGreaterThanOrEqual(Contrast.ratio(PBHex.cream, PBHex.ink), aa, "body on dark scene")
        XCTAssertGreaterThanOrEqual(Contrast.ratio(PBHex.lime, PBHex.ink), aa, "primary button text (dark mode / lime-on-black)")
        XCTAssertGreaterThanOrEqual(Contrast.ratio(PBHex.ink, PBHex.lime), aa, "lime button / sticker text")
        XCTAssertGreaterThanOrEqual(Contrast.ratio(PBHex.white, PBHex.violet), aa, "white on violet")
        XCTAssertGreaterThanOrEqual(Contrast.ratio(PBHex.ink, PBHex.coral), aa, "error banner text (we use ink on coral, not white)")
        XCTAssertGreaterThanOrEqual(Contrast.ratio(PBHex.ink, PBHex.white), aa, "card text")
    }
    func testPlaybookRuleWhiteOnCoralIsNotUsedForBodyText() {
        XCTAssertLessThan(Contrast.ratio(PBHex.white, PBHex.coral), 4.5, "documenting why coral carries ink text, never white body text")
    }
    func testSecondaryTextAtSixtyFivePercentStillReadable() {
        // sub text = fg at 65% opacity over the scene
        func blend(_ fg: UInt32, _ bg: UInt32, _ a: Double) -> UInt32 {
            func ch(_ s: UInt32) -> Double { Double(s) }
            let r = ch((fg >> 16) & 0xFF) * a + ch((bg >> 16) & 0xFF) * (1 - a), g = ch((fg >> 8) & 0xFF) * a + ch((bg >> 8) & 0xFF) * (1 - a), b = ch(fg & 0xFF) * a + ch(bg & 0xFF) * (1 - a)
            return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        }
        XCTAssertGreaterThanOrEqual(Contrast.ratio(blend(PBHex.ink, PBHex.cream, 0.65), PBHex.cream), 4.5)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(blend(PBHex.cream, PBHex.ink, 0.65), PBHex.ink), 4.5)
    }
}

@MainActor
final class LayoutSmokeTests: XCTestCase {
    private func render<V: View>(_ v: V, width: CGFloat = 390, size: DynamicTypeSize) -> CGSize? {
        let wrapped = ThemedRoot { v.frame(width: width).environment(\.dynamicTypeSize, size) }
        let r = ImageRenderer(content: wrapped)
        r.scale = 1
        return r.uiImage?.size
    }

    func testCoreComponentsRenderAtLargestAccessibilityTextWithoutOverflow() {
        let line = ChatViewModel.Line(id: "1", messageID: 1, role: .assistant, text: String(repeating: "A long answer that must wrap rather than overflow. ", count: 12), citations: [])
        let user = ChatViewModel.Line(id: "2", messageID: 2, role: .user, text: "What did I decide about the kitchen floor?")
        let views: [(String, AnyView)] = [
            ("assistant", AnyView(MessageRow(line: line, showDetails: true, onCite: { _ in }))),
            ("user", AnyView(MessageRow(line: user, showDetails: true, onCite: { _ in }))),
            ("empty", AnyView(EmptyState(title: "Nothing found", message: "No passage in your history matches closely enough.", systemImage: "magnifyingglass"))),
            ("error", AnyView(ErrorBanner(message: "Couldn't load the model: out of memory.", retry: {}, dismiss: {}))),
            ("sticker", AnyView(HStack { LocalityBadge(where_: .onDevice); LocalityBadge(where_: .imported) })),
        ]
        for size in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
            for (name, v) in views {
                guard let s = render(v, size: size) else { XCTFail("\(name) did not render at \(size)"); continue }
                XCTAssertLessThanOrEqual(s.width, 392, "\(name) overflows horizontally at \(size)")
                XCTAssertGreaterThan(s.height, 10)
            }
        }
    }

    func testModelCardsRenderForEveryCatalogueEntry() {
        let app = AppModel()
        for spec in ModelCatalog.all {
            let card = ModelCard(spec: spec).environment(app)
            guard let s = render(card, size: .accessibility3) else { XCTFail("no render for \(spec.id)"); continue }
            XCTAssertLessThanOrEqual(s.width, 392)
        }
    }
}

final class AppLogicTests: XCTestCase {
    func testPrivacyDefaultsAreTheMostConservative() async {
        let suite = UserDefaults.standard
        for k in ["onboarded", "chatModelID", "embedderID", "contextCap", "temperature", "useArchiveInChat", "learnMemories", "indexCharging", "showRetrieval", "allowDownloads", "autoLoad"] { suite.removeObject(forKey: k) }
        let s = await MainActor.run { AppSettings() }
        let (charging, download, onboarded) = await MainActor.run { (s.indexOnlyWhileCharging, s.allowModelDownloads, s.onboarded) }
        XCTAssertTrue(charging, "background indexing defaults to charging only")
        XCTAssertTrue(download)
        XCTAssertFalse(onboarded)
    }

    func testZipExportIsUnpackedAndImportable() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        let src = tmp.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try EvalSuite.chatGPTExport(EvalCorpus.standard).write(to: src.appendingPathComponent("conversations.json"))
        let zip = tmp.appendingPathComponent("export.zip")
        try FileManager.default.zipItem(at: src, to: zip, shouldKeepParent: true)
        let (item, cleanup) = try ArchiveUnpacker.prepare(zip)
        defer { if let c = cleanup { try? FileManager.default.removeItem(at: c) } }
        let svc = try PersonalAIServices(directory: tmp.appendingPathComponent("data"))
        let r = try svc.importer.importItem(at: item)
        XCTAssertGreaterThan(r.messagesInserted, 1500)
    }

    func testEveryCatalogueModelHasPlausibleMetadata() {
        for m in ModelCatalog.all {
            XCTAssertFalse(m.license.isEmpty); XCTAssertGreaterThan(m.contextTokens, 0); XCTAssertGreaterThan(m.approxDownloadGB, 0)
            if m.role == .embedder { XCTAssertNotNil(m.embeddingDim) }
        }
    }
}
