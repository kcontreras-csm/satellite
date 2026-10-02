import AppKit
import CryptoKit

enum UpdateDefaults {
    /// Overrides the built-in feed (useful for testing a release before publishing it).
    static let feedURL = "updateFeedURL"
    static let autoCheck = "autoCheckForUpdates"
    static let skippedVersion = "skippedUpdateVersion"
}

/// Backend-less self-updater. Polls a static JSON file ("appcast.json") attached to the latest GitHub Release:
///
///     { "version": "1.1.0", "url": "https://.../Satellite-1.1.0.zip", "sha256": "...", "notes": "..." }
///
/// When it advertises a newer version the user is asked; on accept the zip is downloaded, verified, swapped in
/// place of the running app, and Satellite relaunches. Releases are produced by scripts/release.sh + CI.
/// Only an installed app bundle updates itself; a `swift run` binary never does.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let defaultFeedURL = "https://github.com/kcontreras-csm/satellite/releases/latest/download/appcast.json"

    struct Manifest: Codable {
        let version: String
        let url: String
        let notes: String?
        /// Checksum of the zip; verified before installing when present.
        let sha256: String?
    }

    private var timer: Timer?
    private var busy = false

    private var isInstalledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var feedURL: URL? {
        if let override = UserDefaults.standard.string(forKey: UpdateDefaults.feedURL), let url = URL(string: override) {
            return url
        }
        return URL(string: Self.defaultFeedURL)
    }

    /// Silent check shortly after launch and then every 24 hours (unless turned off in Settings).
    func startPeriodicChecks() {
        guard isInstalledApp else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.check(silent: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(silent: true) }
        }
    }

    /// `silent` is for the background checks: no "up to date" or error messages, and it honors the
    /// "check automatically" setting and any skipped version.
    func check(silent: Bool) {
        if silent, !(UserDefaults.standard.object(forKey: UpdateDefaults.autoCheck) as? Bool ?? true) { return }
        guard isInstalledApp else {
            if !silent {
                info("Updates work in the installed app",
                     "This copy of Satellite isn\u{2019}t running from an app bundle. Build one with scripts/bundle.sh.")
            }
            return
        }
        guard let feedURL, !busy else { return }
        busy = true

        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Satellite/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        Task { @MainActor in
            defer { self.busy = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    if !silent { self.info("No updates yet", "No release has been published.") }
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw UpdateError("The update server answered \(http.statusCode).")
                }
                let manifest = try JSONDecoder().decode(Manifest.self, from: data)
                guard Self.isValidVersion(manifest.version), let url = URL(string: manifest.url), url.scheme == "https" else {
                    throw UpdateError("The update feed is malformed.")
                }
                if Self.isVersion(manifest.version, newerThan: self.currentVersion) {
                    if silent, UserDefaults.standard.string(forKey: UpdateDefaults.skippedVersion) == manifest.version { return }
                    self.offerUpdate(manifest, downloadURL: url)
                } else if !silent {
                    self.info("You\u{2019}re up to date", "Satellite \(self.currentVersion) is the latest version.")
                }
            } catch {
                NSLog("[Updater] check failed: %@", error.localizedDescription)
                if !silent { self.info("Update check failed", error.localizedDescription) }
            }
        }
    }

    // MARK: Flow

    private func offerUpdate(_ manifest: Manifest, downloadURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Satellite \(manifest.version) is available"
        alert.informativeText = (manifest.notes ?? "A new version is ready.")
            + "\n\nYou have \(currentVersion). Install and relaunch now?"
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in await self.downloadAndInstall(manifest, from: downloadURL) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(manifest.version, forKey: UpdateDefaults.skippedVersion)
        default:
            break
        }
    }

    private func downloadAndInstall(_ manifest: Manifest, from url: URL) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            offerManualDownload(url, reason: "Satellite can\u{2019}t replace itself where it is installed (\(target.deletingLastPathComponent().path)).")
            return
        }

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("satellite-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let (zipURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError("The download failed (\(http.statusCode)).")
            }
            if let expected = manifest.sha256?.lowercased(), try Self.sha256(of: zipURL) != expected {
                throw UpdateError("The download didn\u{2019}t match its checksum, so it was not installed.")
            }

            // ditto preserves the code signature, unlike naive unzip tools.
            guard try await Self.run("/usr/bin/ditto", ["-xk", zipURL.path, workDir.path]) == 0,
                  let newApp = try FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError("The downloaded archive doesn\u{2019}t contain an app.")
            }

            // It must really be Satellite, newer than this one, with an intact signature.
            let info = Bundle(url: newApp)?.infoDictionary
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
                throw UpdateError("The downloaded app isn\u{2019}t Satellite.")
            }
            guard let newVersion = info?["CFBundleShortVersionString"] as? String, Self.isVersion(newVersion, newerThan: currentVersion) else {
                throw UpdateError("The downloaded app isn\u{2019}t newer than this one.")
            }
            guard try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0 else {
                throw UpdateError("The downloaded app\u{2019}s signature is damaged.")
            }

            // Hand off to a detached shell that waits for this process to quit, copies the new app next to the
            // old one, then swaps them. If the copy fails the current app is left untouched and reopened.
            let script = """
            target="$1"; new="$2"; pid="$3"; work="$4"
            for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
            if ditto "$new" "$target.updating"; then
              rm -rf "$target" && mv "$target.updating" "$target"
            else
              rm -rf "$target.updating"
            fi
            open "$target"
            rm -rf "$work"
            """
            let handoff = Process()
            handoff.executableURL = URL(fileURLWithPath: "/bin/zsh")
            handoff.arguments = ["-c", script, "satellite-update", target.path, newApp.path,
                                 String(ProcessInfo.processInfo.processIdentifier), workDir.path]
            handoff.standardInput = FileHandle.nullDevice
            handoff.standardOutput = FileHandle.nullDevice
            handoff.standardError = FileHandle.nullDevice
            try handoff.run()
            NSLog("[Updater] installing %@, relaunching", newVersion)
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            NSLog("[Updater] install failed: %@", error.localizedDescription)
            info("Update failed", error.localizedDescription)
        }
    }

    private func offerManualDownload(_ url: URL, reason: String) {
        let alert = NSAlert()
        alert.messageText = "Can\u{2019}t update automatically"
        alert.informativeText = reason + " Download the new version and replace the app yourself."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }

    private func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Helpers

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) async throws -> Int32 {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isValidVersion(_ text: String) -> Bool {
        !text.isEmpty && text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { Int($0) != nil }
    }

    /// Numeric dotted-version comparison: "1.10" > "1.9" > "1.9" == "1.9.0".
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
