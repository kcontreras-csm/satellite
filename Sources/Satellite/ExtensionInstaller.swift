import Foundation

enum ExtensionInstaller {
    /// Downloads every file of `entry` at the index's commit into a staging folder, validates the result,
    /// then swaps it into the extensions directory in one step. A failure leaves any existing version untouched.
    static func install(_ entry: StoreEntry, from index: StoreIndex, using source: StoreSource) async throws {
        let fm = FileManager.default
        let id = entry.id
        guard ExtensionManifest.isValidID(id) else { throw StoreError.invalid("Invalid extension id.") }

        let root = AppPaths.extensions
        let staging = root.appendingPathComponent(".installing-\(id)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let stagingRoot = staging.resolvingSymlinksInPath().path + "/"
        var downloaded = 0
        let downloads = await boundedMap(entry.files) { file -> (StoreFile, Result<Data, Error>) in
            // The await stays in its own statement: with `return (file, .success(try await ...))` the optimized
            // build handed back a corrupted tuple (garbage paths, or no results at all), so installs failed in the
            // released app while debug builds worked.
            do {
                let data = try await source.download(file, of: entry)
                return (file, .success(data))
            } catch {
                return (file, .failure(error))
            }
        }
        for (file, result) in downloads {
            let data = try result.get()
            downloaded += data.count
            guard downloaded <= StoreLimits.maxTotalSize else { throw StoreError.tooLarge("\(id)") }
            guard ExtensionManifest.isSafeRelativePath(file.path) else { throw StoreError.invalid("Unsafe file path in \(id).") }
            let destination = staging.appendingPathComponent(file.path)
            guard destination.resolvingSymlinksInPath().path.hasPrefix(stagingRoot) else { throw StoreError.invalid("Unsafe file path in \(id).") }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
        }

        // Validate what actually landed on disk, not what the index claimed.
        let manifest = try ExtensionManifest.parse(try Data(contentsOf: staging.appendingPathComponent("manifest.json")), folderName: id)
        guard manifest.version == entry.manifest.version else {
            throw StoreError.invalid("Downloaded version \(manifest.version) does not match the listed version \(entry.manifest.version).")
        }
        for file in manifest.codeFiles where !fm.fileExists(atPath: staging.appendingPathComponent(file).path) {
            throw StoreError.invalid("\u{201C}\(file)\u{201D} is missing from the download.")
        }

        try ExtensionOrigin(
            source: entry.location?.repository ?? index.source, ref: entry.location?.ref ?? index.revision,
            installedVersion: manifest.version, installedAt: Date()).write(to: staging)

        let target = root.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: target)
        }
    }
}

// MARK: - Planning

struct InstallStep: Identifiable {
    let entry: StoreEntry
    let isUpdate: Bool
    var id: String { entry.id }
}

struct InstallPlan {
    var steps: [InstallStep] = []
    var problems: [String] = []
    var canInstall: Bool { problems.isEmpty && !steps.isEmpty }

    /// Everything the steps together are allowed to do.
    var permissions: [ExtensionPermission] {
        ExtensionPermission.allCases.filter { permission in steps.contains { $0.entry.manifest.permissions.contains(permission) } }
    }
}

enum StorePlanner {
    /// Works out what has to be installed or updated so `target` and all its dependencies are satisfied,
    /// dependencies first. Nothing is downloaded; problems explain why a plan can't be carried out.
    static func plan(installing target: StoreEntry, index: StoreIndex, installed: [ExtensionInfo]) -> InstallPlan {
        var plan = InstallPlan()
        let installedByID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
        var planned: [String: ExtensionManifest] = [:]

        func current(_ id: String) -> ExtensionManifest? { planned[id] ?? installedByID[id]?.manifest }

        func visit(_ entry: StoreEntry, path: [String]) {
            let name = entry.manifest.name
            if let problem = entry.manifest.compatibilityProblem {
                plan.problems.append("\(name): \(problem)")
                return
            }
            guard !path.contains(entry.id) else {
                plan.problems.append("Circular dependency: " + (path + [entry.id]).joined(separator: " \u{2192} "))
                return
            }
            for (depID, range) in entry.manifest.dependencyRanges {
                if let have = current(depID), have.isLibrary, range.contains(have.semver) { continue }
                if let have = current(depID), !have.isLibrary {
                    plan.problems.append("\u{201C}\(depID)\u{201D} is installed but is not a library.")
                    continue
                }
                guard let candidate = index.entries.first(where: { $0.id == depID }) else {
                    plan.problems.append("\(name) requires \u{201C}\(depID)\u{201D} \(range), which is not in the store.")
                    continue
                }
                guard candidate.manifest.isLibrary else {
                    plan.problems.append("\u{201C}\(depID)\u{201D} is not a library.")
                    continue
                }
                guard range.contains(candidate.manifest.semver) else {
                    plan.problems.append("\(name) requires \u{201C}\(depID)\u{201D} \(range), but the store has \(candidate.manifest.version).")
                    continue
                }
                visit(candidate, path: path + [entry.id])
            }
            if !plan.steps.contains(where: { $0.id == entry.id }) {
                plan.steps.append(InstallStep(entry: entry, isUpdate: installedByID[entry.id] != nil))
                planned[entry.id] = entry.manifest
            }
        }
        visit(target, path: [])

        // Updating a library must not break something else that is already installed.
        var everything = installedByID.compactMapValues(\.manifest)
        everything.merge(planned) { _, new in new }
        for (id, manifest) in everything.sorted(by: { $0.key < $1.key }) {
            for (depID, range) in manifest.dependencyRanges {
                guard let dep = everything[depID], planned[depID] != nil || planned[id] != nil else { continue }
                if !range.contains(dep.semver) {
                    plan.problems.append("\(manifest.name) requires \u{201C}\(depID)\u{201D} \(range), which would become \(dep.version).")
                }
            }
        }
        return plan
    }
}
