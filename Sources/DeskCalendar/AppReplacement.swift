import AppKit
import Darwin

struct ReplacementError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// The backup is the old bundle itself. The swap is a single operation on the same volume.
struct AppReplacement {
    let installed: URL
    let staging: URL
    var candidate: URL { staging.appendingPathComponent(installed.lastPathComponent) }

    static func prepare(image: URL, installer: Installer, installed: URL, identifier: String) throws -> Self {
        let fm = FileManager.default
        let staging = installed.deletingLastPathComponent().appendingPathComponent(".dayfold-update-" + UUID().uuidString)
        let replacement = Self(installed: installed, staging: staging)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw ReplacementError("无法写入当前 App 所在文件夹。请从可写的应用程序文件夹运行折历，然后重试。")
        }
        do {
            let mount = fm.temporaryDirectory.appendingPathComponent("DayfoldMount-" + UUID().uuidString)
            try fm.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            // rmdir never recursively deletes anything on a still-mounted volume.
            defer { _ = rmdir(mount.path) }
            try installer.verify(image)
            try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
            defer { try? run("/usr/bin/hdiutil", ["detach", mount.path]) }
            let source = mount.appendingPathComponent("折历.app")
            guard source.resolvingSymlinksInPath().path == mount.resolvingSymlinksInPath().appendingPathComponent("折历.app").path else {
                throw ReplacementError("安装包中的 App 路径无效。")
            }
            try run("/usr/bin/ditto", [source.path, replacement.candidate.path])
            guard let bundle = Bundle(url: replacement.candidate),
                  bundle.bundleIdentifier == identifier,
                  bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == installer.version else {
                throw ReplacementError("安装包的应用标识或版本不匹配。")
            }
            try run("/usr/bin/codesign", ["--verify", "--strict", "--all-architectures", replacement.candidate.path])
            return replacement
        } catch {
            replacement.discard()
            throw error
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: executable)
        command.arguments = arguments
        command.standardInput = FileHandle.nullDevice
        command.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        command.standardError = pipe
        try command.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else {
            throw ReplacementError("准备安装包失败。 " + String(decoding: output.prefix(500), as: UTF8.self))
        }
    }

    func discard() { try? FileManager.default.removeItem(at: staging) }

    private func swap() throws {
        guard renamex_np(installed.path, candidate.path, UInt32(RENAME_SWAP)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    @MainActor
    func install(launch: () async throws -> Void) async throws {
        do { try swap() }
        catch { discard(); throw error }
        do {
            try await launch()
        } catch let launchError {
            do { try swap() }
            catch { throw ReplacementError("恢复旧版失败。旧版备份保存在 " + candidate.path) }
            discard()
            throw ReplacementError("新版启动失败，已恢复原来的折历。 " + launchError.localizedDescription)
        }
        discard()
    }

    @MainActor
    func restart(arguments: [String]) async throws {
        try await install {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.allowsRunningApplicationSubstitution = false
            config.activates = false
            config.addsToRecentItems = false
            config.arguments = arguments
            let app = try await NSWorkspace.shared.openApplication(at: installed, configuration: config)
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.bundleURL?.resolvingSymlinksInPath().path == installed.resolvingSymlinksInPath().path else {
                throw ReplacementError("系统未能启动当前位置的新版折历。")
            }
            // Launch Services can return before the new app finishes initializing its windows.
            for _ in 0..<200 where !app.isFinishedLaunching && !app.isTerminated {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard app.isFinishedLaunching, !app.isTerminated else {
                if !app.isTerminated { app.terminate() }
                throw ReplacementError("新版未能完成启动。")
            }
        }
    }
}
