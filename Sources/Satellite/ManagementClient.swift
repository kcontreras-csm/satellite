import AppKit
import Combine

/// The managed-device half of the admin protocol. Management is **mandatory** for any Satellite built with an
/// enrollment profile baked in (bundle.sh copies `management.profile` into the app, or `$SATELLITE_MANAGEMENT_PROFILE`
/// points at one). Such a build enrolls itself on first launch with no user action, connects to the admin's relay
/// inbox, reports what it has, applies the admin's policy (removing and refusing blocked extensions, installing
/// pinned ones, locking settings), and obeys one-off remove/disable/enable commands. If the local state file is
/// deleted, it simply re-enrolls on the next launch from the baked-in profile.
///
/// A build with no baked-in profile is unmanaged (ordinary Satellite); it can still be enrolled by hand with
/// `Satellite --enroll <token>` for testing.
@MainActor
final class ManagementClient: ObservableObject {
    static let shared = ManagementClient()

    enum Status: Equatable { case notEnrolled, connecting, online, offline(String) }

    @Published private(set) var state: ManagementState?
    @Published private(set) var status: Status = .notEnrolled

    var isManaged: Bool { state != nil }
    var policy: ManagementPolicy { state?.policy ?? .none }

    private var keys: Management.Keys?
    private var connection: SatellaConnection?
    private var inventoryTimer: Timer?
    /// While the admin hasn't acknowledged this device yet, re-announce often (the admin may have started after
    /// the device). Stops once confirmed, when the slower inventory timer takes over.
    private var announceTimer: Timer?
    private var started = false

    private init() { state = ManagementState.load() }

    private var host: String { state?.admin.host ?? SatellaConnection.defaultHost }
    private func channel(_ s: ManagementState) -> String {
        Management.deviceInbox(admin: s.admin.sign, device: (try? Management.Keys(s.keys).signHex) ?? "")
    }

    /// Called once at launch. Connects if enrolled; otherwise enrolls from the baked-in profile if there is one.
    func start() {
        guard !started else { return }
        started = true
        if let state {
            PolicyEnforcer.apply(state.policy)   // apply what we already know before the network is up
            Task { await connect(state) }
        } else if let token = Self.bundledProfileToken() {
            Task { await autoEnroll(token) }
        }
    }

    // MARK: Enrollment

    /// Enrolls silently from the baked-in profile. Records the enrollment at once (so the device counts as managed
    /// from first launch, even before the admin is reachable) and keeps announcing itself until acknowledged.
    private func autoEnroll(_ tokenText: String) async {
        guard let token = try? Management.parseToken(tokenText), Management.tokenValid(token) else { started = false; return }
        let keys = Management.Keys.create()
        let newState = ManagementState(
            keys: keys.stored,
            admin: .init(sign: token.a, kx: token.k, name: token.n, host: token.h, enrolledAt: Date()),
            policy: .none, deviceName: Self.defaultDeviceName, enrollSecret: token.s, confirmed: false)
        newState.save()
        state = newState
        PolicyEnforcer.apply(.none)
        await connect(newState)
    }

    /// Enrolls this device by hand from a one-time token (`Satellite --enroll <token>`). Waits for the admin's
    /// welcome so it can report success or failure, then keeps running unless `start` is false.
    func enroll(token text: String, start keepRunning: Bool = true) async throws {
        let token = try Management.parseToken(text)
        guard Management.tokenValid(token) else { throw Management.ProtocolError("That enrollment token has expired.") }
        let keys = Management.Keys.create()
        let welcome = PendingWelcome()
        let channel = Management.deviceInbox(admin: token.a, device: keys.signHex)
        let connection = SatellaConnection(host: token.h ?? SatellaConnection.defaultHost, identity: keys, channels: [channel]) { relay in
            Task { @MainActor in welcome.receive(relay.text, keys: keys, adminKx: token.k) }
        }
        try await connection.start()
        if let sealed = Self.sealedEnroll(secret: token.s, keys: keys, adminSign: token.a, adminKx: token.k, deviceName: Self.defaultDeviceName) {
            await connection.send(sealed, on: Management.adminInbox(token.a))
        }
        let policy = try await welcome.wait()
        await connection.stop()

        let newState = ManagementState(
            keys: keys.stored,
            admin: .init(sign: token.a, kx: token.k, name: token.n, host: token.h, enrolledAt: Date()),
            policy: policy, deviceName: Self.defaultDeviceName, enrollSecret: token.s, confirmed: true)
        newState.save()
        state = newState
        PolicyEnforcer.apply(policy)
        started = false
        if keepRunning { start() }
    }

    // MARK: Connected operation

    private func connect(_ state: ManagementState) async {
        status = .connecting
        let keys: Management.Keys
        do { keys = try Management.Keys(state.keys) } catch { status = .offline("keys unreadable"); return }
        self.keys = keys
        let connection = SatellaConnection(host: host, identity: keys, channels: [channel(state)]) { [weak self] relay in
            Task { @MainActor in self?.handle(relay.text) }
        }
        self.connection = connection
        do {
            try await connection.start()
            status = .online
            await report()
            scheduleReports()
            scheduleAnnounce(state)
        } catch {
            status = .offline(error.localizedDescription)
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)   // a managed laptop is often offline at launch
            if self.connection === connection { await connect(state) }
        }
    }

    private func scheduleReports() {
        inventoryTimer?.invalidate()
        inventoryTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.report(kind: "inventory") }
        }
    }

    /// Re-announce every 20s until the admin acknowledges us, so a device that came up before the admin's `serve`
    /// is picked up within seconds of the admin starting — not up to 30 minutes later.
    private func scheduleAnnounce(_ state: ManagementState) {
        announceTimer?.invalidate()
        guard !state.confirmed else { return }
        announceTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.state?.confirmed == false else { timer.invalidate(); return }
                await self.report()
            }
        }
    }

    /// Tells the admin about this device. Until the admin has acknowledged us (`confirmed`), each report is an
    /// enrollment announcement carrying the proof, so a device that came up before the admin was serving still
    /// gets recorded. After that, it's a plain check-in.
    private func report(kind: String = "hello") async {
        guard let state, let keys, let connection else { return }
        let message: String?
        if state.confirmed {
            message = try? Management.seal(keys, toSign: state.admin.sign, toKx: state.admin.kx,
                                           Hello(type: kind, version: AppInfo.version.description, policyVersion: state.policy.version,
                                                 os: Self.osDescription, model: Self.model, build: Self.build, extensions: PolicyEnforcer.inventory()))
        } else {
            message = Self.sealedEnroll(secret: state.enrollSecret, keys: keys, adminSign: state.admin.sign, adminKx: state.admin.kx, deviceName: state.deviceName)
        }
        if let message { await connection.send(message, on: Management.adminInbox(state.admin.sign)) }
    }

    private struct Hello: Encodable {
        var type: String; var id = Management.newID(); var ts = Management.now()
        var version: String; var policyVersion: Int
        var os: String; var model: String; var build: String?
        var extensions: [PolicyEnforcer.ExtensionReport]
    }

    /// Facts about this Mac shown to the admin, read once. "macOS 15.1", the hardware model, and the build stamp.
    static let osDescription: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }()
    static let model: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }()
    static var build: String? { Bundle.main.object(forInfoDictionaryKey: "SatelliteBuild") as? String }

    /// Builds and seals an enrollment announcement, carrying the proof that this device holds a valid secret.
    private static func sealedEnroll(secret: String, keys: Management.Keys, adminSign: String, adminKx: String, deviceName: String) -> String? {
        guard let proof = try? Management.enrollProof(secret: secret, deviceSign: keys.signHex, deviceKx: keys.kxB64) else { return nil }
        struct Enroll: Encodable { var type = "enroll"; var id = Management.newID(); var ts = Management.now(); var secret: String; var proof: String; var deviceName: String; var version: String }
        let message = Enroll(secret: secret, proof: proof, deviceName: deviceName, version: AppInfo.version.description)
        return try? Management.seal(keys, toSign: adminSign, toKx: adminKx, message, includeKx: true)
    }

    private func handle(_ text: String) {
        guard let state, let keys, let env = Management.peek(text, keys: keys), env.f == state.admin.sign else { return }
        guard let (header, _) = try? Management.open(Management.Message.self, keys, env, senderKx: state.admin.kx) else { return }
        switch header.type {
        case "policy", "welcome":
            struct Carrier: Decodable { var policy: ManagementPolicy }
            guard let (_, carrier) = try? Management.open(Carrier.self, keys, env, senderKx: state.admin.kx) else { return }
            confirm()
            applyIfNewer(carrier.policy)
        case "command":
            struct Command: Decodable { var command: String; var extensionId: String }
            guard let (_, command) = try? Management.open(Command.self, keys, env, senderKx: state.admin.kx) else { return }
            confirm()
            runCommand(command.command, command.extensionId)
        default:
            break
        }
    }

    /// Marks the device acknowledged, so it switches from enrollment announcements to plain check-ins.
    private func confirm() {
        guard var state, !state.confirmed else { return }
        state.confirmed = true
        state.save()
        self.state = state
        announceTimer?.invalidate()   // acknowledged; the slow inventory timer is enough now
        announceTimer = nil
    }

    private func applyIfNewer(_ policy: ManagementPolicy) {
        guard var state, policy.version > state.policy.version else { return }
        state.policy = policy
        state.save()
        self.state = state
        PolicyEnforcer.apply(policy)
        Toast.show("Updated by \(state.admin.name)", in: NSApp.keyWindow)
        Task { await report(kind: "inventory") }   // confirm the new version back to the admin
    }

    private func runCommand(_ command: String, _ extensionId: String) {
        PolicyEnforcer.run(command, on: extensionId)
        guard let state, let keys, let connection else { return }
        struct Result: Encodable { var type = "result"; var id = Management.newID(); var ts = Management.now(); var command: String; var extensionId: String }
        let message = Result(command: command, extensionId: extensionId)
        Task {
            if let sealed = try? Management.seal(keys, toSign: state.admin.sign, toKx: state.admin.kx, message) {
                await connection.send(sealed, on: Management.adminInbox(state.admin.sign))
            }
        }
    }

    // MARK: Baked-in profile

    /// The enrollment profile this build carries, if any: a bundled `management.profile` resource, or a path in
    /// `$SATELLITE_MANAGEMENT_PROFILE` (for development). The contents are a `satadm1.` token with no expiry.
    static func bundledProfileToken() -> String? {
        if let path = ProcessInfo.processInfo.environment["SATELLITE_MANAGEMENT_PROFILE"], !path.isEmpty,
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let url = Bundle.main.url(forResource: "management", withExtension: "profile"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static var defaultDeviceName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
}

/// Collects a `welcome` reply during by-hand enrollment, turning the first valid one into the starting policy.
@MainActor
private final class PendingWelcome {
    private var continuation: CheckedContinuation<ManagementPolicy, Error>?
    private var result: Result<ManagementPolicy, Error>?

    func receive(_ text: String, keys: Management.Keys, adminKx: String) {
        guard let env = Management.peek(text, keys: keys) else { return }
        struct Carrier: Decodable { var policy: ManagementPolicy }
        guard let (header, carrier) = try? Management.open(Carrier.self, keys, env, senderKx: adminKx), header.type == "welcome" else { return }
        finish(.success(carrier.policy))
    }

    func wait() async throws -> ManagementPolicy {
        if let result { return try result.get() }
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            finish(.failure(Management.ProtocolError("The admin didn\u{2019}t answer. Make sure they are running \u{201C}satellite-admin serve\u{201D}, then try again.")))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in self.continuation = continuation }
    }

    private func finish(_ outcome: Result<ManagementPolicy, Error>) {
        if let continuation { self.continuation = nil; continuation.resume(with: outcome) }
        else { result = outcome }
    }
}
