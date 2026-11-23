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

extension UpdateTests {
    @MainActor @Test func replacementRollsBackWhenNewAppCannotStart() async throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: parent) }
        let target = parent.appendingPathComponent("折历.app")
        let staged = AppReplacement(installed: target, staging: parent.appendingPathComponent("stage"))
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: staged.candidate, withIntermediateDirectories: true)
        let marker = target.appendingPathComponent("version")
        try Data("old".utf8).write(to: marker)
        try Data("new".utf8).write(to: staged.candidate.appendingPathComponent("version"))
        await #expect(throws: ReplacementError.self) {
            try await staged.install {
                #expect(try String(contentsOf: marker, encoding: .utf8) == "new")
                throw ReplacementError("模拟启动失败")
            }
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "old")
        #expect(!fm.fileExists(atPath: staged.staging.path))
    }

    @Test func restartLayoutRoundTrip() throws {
        let frame = CGRect(x: -900, y: 200, width: 620, height: 440)
        let layout = RestartLayout(anchor: Date(timeIntervalSince1970: 1700000000), board: frame,
                                   bar: CGRect(x: -600, y: 350, width: 176, height: 38), overview: nil)
        let arg = try layout.argument
        let data = try #require(Data(base64Encoded: String(arg.dropFirst(RestartLayout.flag.count))))
        let restored = try JSONDecoder().decode(RestartLayout.self, from: data)
        #expect(restored.board == frame)
        #expect(restored.bar == layout.bar)
        #expect(restored.anchor == layout.anchor)
    }
}
