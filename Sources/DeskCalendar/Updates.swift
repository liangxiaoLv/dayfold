import AppKit
import CryptoKit
import SwiftUI

struct DayfoldRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let size: Int
        let digest: String?
        let state: String
    }

    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft, prerelease, assets
    }

    func update(after current: String) throws -> Installer? {
        guard !draft, !prerelease, tagName.hasPrefix("v") else { throw UpdateError.invalidRelease }
        let version = String(tagName.dropFirst())
        func components(_ value: String) throws -> [Int] {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { throw UpdateError.invalidRelease }
            return try parts.map {
                guard let number = Int($0), number >= 0, String(number) == $0 else { throw UpdateError.invalidRelease }
                return number
            }
        }
        guard try components(current).lexicographicallyPrecedes(components(version)) else { return nil }
        let name = "Dayfold-\(version)-macOS-universal.dmg"
        guard let asset = assets.first(where: { $0.name == name && $0.state == "uploaded" }),
              asset.size > 0, let digest = asset.digest, digest.hasPrefix("sha256:") else { throw UpdateError.missingInstaller }
        let hash = String(digest.dropFirst(7))
        guard hash.utf8.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw UpdateError.missingInstaller }
        return Installer(version: version, name: name, size: asset.size, hash: hash)
    }
}

enum UpdateError: LocalizedError {
    case invalidRelease, missingInstaller, integrity, network(Int), open
    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "无法识别正式版的版本信息。"
        case .missingInstaller: return "新版的通用安装包或校验值尚未就绪，请稍后重试。"
        case .integrity: return "安装包校验失败，请重新下载。"
        case .network(403), .network(429): return "GitHub 暂时限制了请求，请稍后再试。"
        case let .network(code): return "更新服务暂时不可用（HTTP \(code)）。"
        case .open: return "系统未能打开安装包，请重试。"
        }
    }
}

struct Installer {
    let version: String
    let name: String
    let size: Int
    let hash: String
    static let releases = URL(string: "https://github.com/liangxiaoLv/dayfold/releases")!
    var url: URL { Self.releases.appendingPathComponent("download/v" + version).appendingPathComponent(name) }

    func verify(_ file: URL) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count == size, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else {
            throw UpdateError.integrity
        }
    }

    func download() async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        try checkResponse(response)
        try verify(file)
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskCalendar/Updates").appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
        } else { try FileManager.default.moveItem(at: file, to: destination) }
        return destination
    }
}

private func checkResponse(_ response: URLResponse) throws {
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else { throw UpdateError.network(code) }
}

@MainActor
final class Updates: ObservableObject {
    enum State {
        case checking, current, available(Installer), downloading, opened, failed(String)
    }
    @Published private(set) var state = State.checking
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private var operation: Task<Void, Never>?

    func check() {
        guard operation == nil else { return }
        state = .checking
        operation = Task {
            defer { operation = nil }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/liangxiaoLv/dayfold/releases/latest")!,
                                         cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Dayfold/" + current, forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                try checkResponse(response)
                let release = try JSONDecoder().decode(DayfoldRelease.self, from: data)
                state = try release.update(after: current).map(State.available) ?? .current
            } catch { state = .failed(error.localizedDescription) }
        }
    }
    func download(_ installer: Installer) {
        guard operation == nil else { return }
        state = .downloading
        operation = Task {
            defer { operation = nil }
            do {
                let url = try await installer.download()
                guard NSWorkspace.shared.open(url) else { throw UpdateError.open }
                state = .opened
            } catch { state = .failed(error.localizedDescription) }
        }
    }
}

struct UpdateView: View {
    @ObservedObject var updates: Updates
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 46, height: 46)
                VStack(alignment: .leading) {
                    Text("折历").font(.title2.bold())
                    Text("当前版本 v" + updates.current).foregroundStyle(.secondary)
                }
            }
            Divider()
            switch updates.state {
            case .checking: ProgressView("正在检查 GitHub 正式版…")
            case .downloading: ProgressView("正在下载并校验安装包…")
            case .current: Label("已是最新版本", systemImage: "checkmark.circle")
            case let .available(installer):
                Text("发现新版本 v" + installer.version).font(.headline)
                Button("下载并打开安装包") { updates.download(installer) }.keyboardShortcut(.defaultAction)
            case .opened:
                Text("安装包已打开。请先保存编辑并退出折历，再将新版拖到当前应用所在文件夹，选择「替换」。")
                Button("显示当前应用位置") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
            case let .failed(message):
                Text(message)
                Button("重新检查") { updates.check() }
            }
            Spacer(minLength: 0)
            Link("GitHub 版本说明", destination: Installer.releases.appendingPathComponent("latest")).font(.callout)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
