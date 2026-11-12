import Foundation

// Checks the Claude Code skills store: listing a repository of skills, installing one into the skills folder
// (verified, with an origin file), detecting an update, and removing it. Uses the local source and temp folders
// (SATELLITE_SKILLS_STORE_DIR for the "repository", SATELLITE_SKILLS_DIR for where skills install).

var failures = 0
func check(_ ok: Bool, _ name: String) { print(ok ? "  ok  \(name)" : "  FAIL \(name)"); if !ok { failures += 1 } }

let fm = FileManager.default

// Live diagnosis: `--github owner/name` fetches the real repo and tries to install every skill, printing results.
if let i = CommandLine.arguments.firstIndex(of: "--github") {
    let repo = CommandLine.arguments.dropFirst(i + 1).first ?? "kcontreras-csm/claude-skills"
    let source = SkillGitHubSource(config: StoreConfig(repository: repo))
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let index = try await source.fetchIndex(cached: nil)
            print("listed \(index.entries.count): \(index.entries.map(\.id))")
            for entry in index.entries {
                print("  files for \(entry.id): \(entry.files.map(\.path))")
                do { try await SkillInstaller.install(entry, from: index, using: source); print("    installed \(entry.id) OK") }
                catch { print("    FAILED \(entry.id): \(error.localizedDescription)") }
            }
        } catch { print("fetchIndex failed: \(error.localizedDescription)") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}
let storeDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SATELLITE_SKILLS_STORE_DIR"]!, isDirectory: true)
let installDir = AppPaths.skills   // = SATELLITE_SKILLS_DIR

func writeSkill(_ id: String, name: String, version: String, body: String, extra: [String: String] = [:]) {
    let dir = storeDir.appendingPathComponent(id)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let md = "---\nname: \(name)\ndescription: Does \(name) things\nversion: \(version)\n---\n\n\(body)\n"
    try! md.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    for (path, content) in extra {
        let file = dir.appendingPathComponent(path)
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! content.write(to: file, atomically: true, encoding: .utf8)
    }
}

writeSkill("case-triage", name: "Case Triage", version: "1.0.0", body: "Triage a case.", extra: ["reference/notes.md": "notes v1"])
writeSkill("closure", name: "Closure", version: "2.1.0", body: "Close a case.")
writeSkill("manual-skill", name: "Manual Skill", version: "1.0.0", body: "Store copy of a hand-placed skill.")

func run(_ work: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { await work(); sem.signal() }
    sem.wait()
}

let source = SkillLocalSource(directory: storeDir)

run {
    do {
        let index = try await source.fetchIndex(cached: nil)
        check(Set(index.entries.map(\.id)) == ["case-triage", "closure", "manual-skill"], "lists the skills")
        check(index.entries.first?.name == "Case Triage", "reads name from SKILL.md frontmatter, sorted")

        guard let triage = index.entries.first(where: { $0.id == "case-triage" }) else { return check(false, "found case-triage") }
        try await SkillInstaller.install(triage, from: index, using: source)
        let installed = installDir.appendingPathComponent("case-triage")
        check(fm.fileExists(atPath: installed.appendingPathComponent("SKILL.md").path), "installed SKILL.md")
        check(fm.fileExists(atPath: installed.appendingPathComponent("reference/notes.md").path), "installed nested file")
        check(SkillOrigin.read(from: installed)?.version == "1.0.0", "wrote origin with version")

        // An update: bump the store's version and change a file, reinstall, confirm the new content lands.
        writeSkill("case-triage", name: "Case Triage", version: "1.1.0", body: "Triage a case better.", extra: ["reference/notes.md": "notes v2"])
        let index2 = try await source.fetchIndex(cached: nil)
        let updated = index2.entries.first { $0.id == "case-triage" }!
        check(SemVer(updated.version)! > SemVer(SkillOrigin.read(from: installed)!.version)!, "store version is newer than installed")
        try await SkillInstaller.install(updated, from: index2, using: source)
        let notes = try String(contentsOf: installed.appendingPathComponent("reference/notes.md"), encoding: .utf8)
        check(notes == "notes v2", "update replaced the file")
        check(SkillOrigin.read(from: installed)?.version == "1.1.0", "origin updated to the new version")

        // Verification: a wrong SHA in the file list is rejected.
        var bad = updated
        bad.files = bad.files.map { $0.path == "SKILL.md" ? StoreFile(path: $0.path, sha: String(repeating: "0", count: 40), size: $0.size) : $0 }
        do { try await SkillInstaller.install(bad, from: index2, using: source); check(false, "rejects a bad checksum") }
        catch { check(true, "rejects a bad checksum") }
        check(try! String(contentsOf: installed.appendingPathComponent("reference/notes.md"), encoding: .utf8) == "notes v2", "failed install left the old one intact")

        // Replace: a skill placed by hand (no origin) becomes store-managed after installing the store copy over it.
        let manual = installDir.appendingPathComponent("manual-skill")
        try fm.createDirectory(at: manual, withIntermediateDirectories: true)
        try "---\nname: Manual Skill\n---\nlocal edits".write(to: manual.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        check(SkillOrigin.read(from: manual) == nil, "a hand-placed skill has no origin")
        let storeManual = index2.entries.first { $0.id == "manual-skill" }!
        try await SkillInstaller.install(storeManual, from: index2, using: source)
        check(SkillOrigin.read(from: manual)?.source == source.identifier, "replace made it store-managed (wrote origin)")
        check(try! String(contentsOf: manual.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("Store copy"), "replace overwrote the hand-placed copy")

        // Remove.
        try fm.trashItem(at: installed, resultingItemURL: nil)
        check(!fm.fileExists(atPath: installed.path), "removed the skill folder")
    } catch {
        check(false, "no error: \(error.localizedDescription)")
    }
}

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
