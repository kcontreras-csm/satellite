import SwiftUI

/// Settings > Management. Management is mandatory on a build that carries an admin profile, so this tab is
/// read-only: it shows which admin is in charge, the connection state, and exactly what the policy does, so
/// nothing about it is hidden from the person using the device. An unmanaged (profile-less) build shows that it
/// isn't managed.
struct ManagementSettings: View {
    @ObservedObject var client = ManagementClient.shared

    var body: some View {
        Form {
            if let state = client.state {
                managed(state)
            } else {
                Section("Management") {
                    Text("This Satellite isn\u{2019}t managed. A build distributed by your team carries its administrator\u{2019}s profile and enrolls on its own.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func managed(_ state: ManagementState) -> some View {
        Section("Managed device") {
            LabeledContent("Administrator", value: state.admin.name)
            LabeledContent("This device", value: state.deviceName)
            LabeledContent("Status") { statusLabel }
            LabeledContent("Enrolled", value: state.admin.enrolledAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Policy", value: "version \(state.policy.version)")
        }

        let policy = state.policy
        if !policy.blockedIds.isEmpty {
            Section("Blocked extensions") {
                Text("These are removed and can\u{2019}t be installed on this device.").font(.footnote).foregroundStyle(.secondary)
                ForEach(policy.blockedIds, id: \.self) { Text($0).font(.callout.monospaced()) }
            }
        }
        if !policy.pinned.isEmpty {
            Section("Pinned extensions") {
                Text("Installed and held at a set version by your administrator.").font(.footnote).foregroundStyle(.secondary)
                ForEach(policy.pinned.sorted(by: { $0.key < $1.key }), id: \.key) { id, version in
                    LabeledContent(id, value: version)
                }
            }
        }
        if !policy.lockedSettings.isEmpty {
            Section("Locked settings") {
                Text("Set by your administrator; you can\u{2019}t change these here.").font(.footnote).foregroundStyle(.secondary)
                ForEach(policy.lockedSettings.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    LabeledContent(Self.settingTitles[key] ?? key, value: value)
                }
            }
        }
        Section {
            Text("This Satellite is managed by \(state.admin.name). Its policy applies automatically; to change it, contact your administrator.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch client.status {
        case .online: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .connecting: Label("Connecting\u{2026}", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .offline(let why): Label("Offline \u{2014} \(why)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .notEnrolled: Label("Not enrolled", systemImage: "circle").foregroundStyle(.secondary)
        }
    }

    static let settingTitles = [
        "agent-text": "Page text for agents",
        "snapshot-text": "Page text in snapshots",
        "auto-update": "Automatic updates",
        "mcp": "MCP server",
    ]
}
