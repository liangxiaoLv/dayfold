import Foundation
import Testing
@testable import DeskCalendar

struct UpdateTests {
    private let checksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private func release(draft: Bool = false, prerelease: Bool = false, assets: [DayfoldRelease.Asset]? = nil) -> DayfoldRelease {
        let name = "Dayfold-0.10.0-macOS-universal.dmg"
        return DayfoldRelease(tagName: "v0.10.0", draft: draft, prerelease: prerelease,
                              assets: assets ?? [.init(name: name, size: 3, digest: "sha256:" + checksum, state: "uploaded")])
    }
    @Test func stableVersionsAndAssets() throws {
        let update = try #require(try release().update(after: "0.9.12"))
        #expect(update.url.absoluteString == "https://github.com/liangxiaoLv/dayfold/releases/download/v0.10.0/Dayfold-0.10.0-macOS-universal.dmg")
        #expect(try release().update(after: "0.10.0") == nil)
        #expect(try release().update(after: "1.0.0") == nil)
        #expect(throws: UpdateError.self) { try release(prerelease: true).update(after: "0.9.0") }
        #expect(throws: UpdateError.self) { try release(draft: true).update(after: "0.9.0") }
        #expect(throws: UpdateError.self) { try release(assets: []).update(after: "0.9.0") }
    }
    @Test func detectsCorruptAndTruncatedDownloads() throws {
        let update = try #require(try release().update(after: "0.9.0"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        try update.verify(file)
        for content in ["ab", "abd"] {
            try Data(content.utf8).write(to: file)
            #expect(throws: UpdateError.self) { try update.verify(file) }
        }
    }
}
