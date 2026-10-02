import Foundation
import IOKit.hid

// MARK: - Errors

enum SecurityKeyError: Error, LocalizedError {
    case openFailed(String)
    case timeout
    case protocolError(String)
    case hid(UInt8)

    var errorDescription: String? {
        switch self {
        case .openFailed(let detail): return "Couldn\u{2019}t open the security key (\(detail))."
        case .timeout: return "The security key didn\u{2019}t respond in time."
        case .protocolError(let detail): return "The security key sent something unexpected (\(detail))."
        case .hid(let code): return "The security key reported an error (0x\(String(code, radix: 16)))."
        }
    }
}

/// A CTAP2 status code returned by the key.
struct CTAPError: Error, LocalizedError {
    let code: UInt8

    static let credentialExcluded: UInt8 = 0x19
    static let unsupportedAlgorithm: UInt8 = 0x26
    static let operationDenied: UInt8 = 0x27
    static let keyStoreFull: UInt8 = 0x28
    static let unsupportedOption: UInt8 = 0x2B
    static let keepaliveCancel: UInt8 = 0x2D
    static let noCredentials: UInt8 = 0x2E
    static let userActionTimeout: UInt8 = 0x2F
    static let notAllowed: UInt8 = 0x30
    static let pinInvalid: UInt8 = 0x31
    static let pinBlocked: UInt8 = 0x32
    static let pinAuthInvalid: UInt8 = 0x33
    static let pinAuthBlocked: UInt8 = 0x34
    static let pinNotSet: UInt8 = 0x35
    static let pinRequired: UInt8 = 0x36
    static let actionTimeout: UInt8 = 0x3A
    static let uvBlocked: UInt8 = 0x3C
    static let uvInvalid: UInt8 = 0x3F

    var errorDescription: String? {
        switch code {
        case Self.credentialExcluded: return "This security key is already registered."
        case Self.unsupportedAlgorithm: return "The security key doesn\u{2019}t support the kind of credential the site asked for."
        case Self.operationDenied, Self.notAllowed, Self.keepaliveCancel: return "The request was declined on the security key."
        case Self.keyStoreFull: return "The security key has no room for another credential."
        case Self.noCredentials: return "This security key has no credential for this site."
        case Self.userActionTimeout, Self.actionTimeout: return "The security key wasn\u{2019}t touched in time."
        case Self.pinInvalid: return "The PIN is incorrect."
        case Self.pinBlocked: return "The security key\u{2019}s PIN is blocked. Reset the key to use it again."
        case Self.pinAuthBlocked: return "Too many wrong PINs. Unplug the security key and plug it in again."
        case Self.pinNotSet: return "This site needs a PIN, but the security key has none. Set a PIN on the key first."
        case Self.pinRequired, Self.pinAuthInvalid: return "The security key needs its PIN for this."
        case Self.uvBlocked, Self.uvInvalid: return "User verification on the security key failed."
        default: return "The security key returned error 0x\(String(code, radix: 16))."
        }
    }
}

// MARK: - Device

/// Something that exchanges 64-byte CTAPHID packets. The real implementation is a USB key; tests use a fake.
@MainActor
protocol HIDPacketDevice: AnyObject {
    var packetHandler: ((Data) -> Void)? { get set }
    func open() throws
    func sendPacket(_ packet: Data) throws
}

/// A USB security key (a HID device on the FIDO usage page).
@MainActor
final class FIDODevice: HIDPacketDevice, Identifiable {
    let ref: IOHIDDevice
    let id: UInt64
    let name: String
    var packetHandler: ((Data) -> Void)?

    private var buffer: UnsafeMutablePointer<UInt8>?
    private var isOpen = false

    init(ref: IOHIDDevice) {
        self.ref = ref
        var entry: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(ref), &entry)
        id = entry
        let product = IOHIDDeviceGetProperty(ref, kIOHIDProductKey as CFString) as? String
        name = (product?.isEmpty == false ? product : nil) ?? "Security key"
    }

    func open() throws {
        guard !isOpen else { return }
        let result = IOHIDDeviceOpen(ref, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw SecurityKeyError.openFailed("IOKit 0x\(String(UInt32(bitPattern: result), radix: 16))")
        }
        let reported = (IOHIDDeviceGetProperty(ref, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
        let size = max(reported, 64)
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        pointer.initialize(repeating: 0, count: size)
        buffer = pointer
        IOHIDDeviceRegisterInputReportCallback(ref, pointer, size, FIDODevice.inputCallback, Unmanaged.passUnretained(self).toOpaque())
        // Common modes keep packets flowing while a modal alert (PIN entry) is on screen.
        IOHIDDeviceScheduleWithRunLoop(ref, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        isOpen = true
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        packetHandler = nil
        if let buffer {
            IOHIDDeviceRegisterInputReportCallback(ref, buffer, 64, nil, nil)
            buffer.deallocate()
            self.buffer = nil
        }
        IOHIDDeviceClose(ref, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func sendPacket(_ packet: Data) throws {
        let result = packet.withUnsafeBytes { raw -> IOReturn in
            IOHIDDeviceSetReport(ref, kIOHIDReportTypeOutput, 0, raw.bindMemory(to: UInt8.self).baseAddress!, packet.count)
        }
        guard result == kIOReturnSuccess else {
            throw SecurityKeyError.protocolError("write failed, IOKit 0x\(String(UInt32(bitPattern: result), radix: 16))")
        }
    }

    private static let inputCallback: IOHIDReportCallback = { context, _, _, _, _, report, length in
        guard let context else { return }
        var packet = Data(bytes: report, count: length)
        if packet.count > 64 { packet = packet.suffix(64) }  // some systems prepend a report id
        let device = Unmanaged<FIDODevice>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { device.packetHandler?(packet) }
    }
}

/// Watches for USB security keys being plugged in and removed.
@MainActor
final class FIDODeviceMonitor: ObservableObject {
    static let shared = FIDODeviceMonitor()

    @Published private(set) var devices: [FIDODevice] = []
    private var manager: IOHIDManager?
    private var listeners: [UUID: AsyncStream<FIDODevice>.Continuation] = [:]

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDPrimaryUsagePageKey: 0xF1D0, kIOHIDPrimaryUsageKey: 0x01]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.matched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.removed, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    /// Keys plugged in from now on.
    func arrivals() -> AsyncStream<FIDODevice> {
        start()
        let token = UUID()
        return AsyncStream { continuation in
            listeners[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.listeners[token] = nil }
            }
        }
    }

    private func added(_ ref: IOHIDDevice) {
        let device = FIDODevice(ref: ref)
        guard !devices.contains(where: { $0.id == device.id }) else { return }
        devices.append(device)
        for continuation in listeners.values { continuation.yield(device) }
    }

    private func removed(_ ref: IOHIDDevice) {
        var entry: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(ref), &entry)
        for device in devices where device.id == entry { device.close() }
        devices.removeAll { $0.id == entry }
    }

    private static let matched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let monitor = Unmanaged<FIDODeviceMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.added(device) }
    }

    private static let removed: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let monitor = Unmanaged<FIDODeviceMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.removed(device) }
    }
}

// MARK: - CTAPHID channel

/// What the FIDO2 and U2F clients need from a connected key.
@MainActor
protocol CTAPTransport: AnyObject {
    var supportsCBOR: Bool { get }
    /// Sends one CTAP2 request (command byte + CBOR) and returns the CBOR that follows the status byte.
    func cbor(_ request: Data) async throws -> Data
    /// Sends one U2F APDU and returns the raw response including the status word.
    func msg(_ apdu: Data) async throws -> Data
    /// Called with CTAPHID keepalive statuses (1 = processing, 2 = waiting for a touch).
    var onKeepalive: ((UInt8) -> Void)? { get set }
}

/// CTAPHID: framing of messages into 64-byte packets, channel allocation, keepalives and cancellation.
@MainActor
final class CTAPHIDChannel: CTAPTransport {
    static let broadcast: UInt32 = 0xFFFF_FFFF

    private let device: HIDPacketDevice
    private var channel = CTAPHIDChannel.broadcast
    private(set) var capabilities: UInt8 = 0
    var onKeepalive: ((UInt8) -> Void)?

    var supportsCBOR: Bool { capabilities & 0x04 != 0 }

    init(device: HIDPacketDevice) {
        self.device = device
    }

    /// Opens the device and allocates a channel for this conversation.
    func initialize() async throws {
        try device.open()
        let nonce = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let reply = try await exchange(
            command: 0x86, payload: nonce, channel: Self.broadcast, timeout: 5,
            accept: { $0.count >= 17 && $0.prefix(8) == nonce })
        let bytes = [UInt8](reply)
        channel = UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11])
        capabilities = bytes[16]
    }

    func cbor(_ request: Data) async throws -> Data {
        let reply = try await exchange(command: 0x90, payload: request, channel: channel, timeout: 180)
        guard let status = reply.first else { throw SecurityKeyError.protocolError("empty reply") }
        guard status == 0 else { throw CTAPError(code: status) }
        return Data(reply.dropFirst())
    }

    func msg(_ apdu: Data) async throws -> Data {
        try await exchange(command: 0x83, payload: apdu, channel: channel, timeout: 180)
    }

    // MARK: Framing

    private func sendFrames(command: UInt8, payload: Data, channel: UInt32) throws {
        guard payload.count <= 7609 else { throw SecurityKeyError.protocolError("message too large") }
        let bytes = [UInt8](payload)
        func header(_ last: UInt8) -> [UInt8] {
            [UInt8(channel >> 24), UInt8((channel >> 16) & 0xFF), UInt8((channel >> 8) & 0xFF), UInt8(channel & 0xFF), last]
        }

        var packet = header(command) + [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]
        var offset = min(57, bytes.count)
        packet += bytes[0..<offset]
        packet += [UInt8](repeating: 0, count: 64 - packet.count)
        try device.sendPacket(Data(packet))

        var sequence: UInt8 = 0
        while offset < bytes.count {
            let end = min(offset + 59, bytes.count)
            var next = header(sequence) + bytes[offset..<end]
            next += [UInt8](repeating: 0, count: 64 - next.count)
            try device.sendPacket(Data(next))
            offset = end
            sequence += 1
        }
    }

    private func sendCancel(channel: UInt32) {
        let header: [UInt8] = [UInt8(channel >> 24), UInt8((channel >> 16) & 0xFF), UInt8((channel >> 8) & 0xFF), UInt8(channel & 0xFF), 0x91, 0, 0]
        try? device.sendPacket(Data(header + [UInt8](repeating: 0, count: 64 - header.count)))
    }

    private func exchange(command: UInt8, payload: Data, channel: UInt32, timeout: TimeInterval,
                          accept: @escaping (Data) -> Bool = { _ in true }) async throws -> Data {
        let state = Exchange(channel: channel, command: command | 0x80, accept: accept, onKeepalive: { [weak self] in self?.onKeepalive?($0) })
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                state.continuation = continuation
                device.packetHandler = { [weak state] packet in state?.receive(packet) }
                state.timeout = Task { @MainActor [weak state] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    state?.finish(.failure(SecurityKeyError.timeout))
                }
                do { try sendFrames(command: command, payload: payload, channel: channel) }
                catch { state.finish(.failure(error)) }
            }
        } onCancel: {
            Task { @MainActor in
                if state.continuation != nil { self.sendCancel(channel: channel) }
                state.finish(.failure(CancellationError()))
            }
        }
    }
}

/// Reassembles one reply message from incoming packets.
@MainActor
private final class Exchange {
    let channel: UInt32
    let command: UInt8
    let accept: (Data) -> Bool
    let onKeepalive: (UInt8) -> Void
    var continuation: CheckedContinuation<Data, Error>?
    var timeout: Task<Void, Never>?

    private var buffer = Data()
    private var expected = 0
    private var nextSequence: UInt8 = 0
    private var assembling = false

    init(channel: UInt32, command: UInt8, accept: @escaping (Data) -> Bool, onKeepalive: @escaping (UInt8) -> Void) {
        self.channel = channel
        self.command = command
        self.accept = accept
        self.onKeepalive = onKeepalive
    }

    func receive(_ packet: Data) {
        let p = [UInt8](packet)
        guard continuation != nil, p.count >= 5 else { return }
        let cid = UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
        guard cid == channel else { return }

        if p[4] & 0x80 != 0 {
            switch p[4] {
            case 0xBB where p.count > 7:
                onKeepalive(p[7])
            case 0xBF where p.count > 7:
                finish(.failure(SecurityKeyError.hid(p[7])))
            case command:
                guard p.count >= 7 else { return }
                expected = Int(p[5]) << 8 | Int(p[6])
                buffer = Data(p[7..<min(p.count, 7 + min(expected, 57))])
                nextSequence = 0
                assembling = true
                completeIfReady()
            default:
                break
            }
        } else if assembling {
            guard p[4] == nextSequence else {
                finish(.failure(SecurityKeyError.protocolError("packets out of order")))
                return
            }
            nextSequence &+= 1
            let take = min(expected - buffer.count, p.count - 5)
            buffer.append(contentsOf: p[5..<5 + take])
            completeIfReady()
        }
    }

    private func completeIfReady() {
        guard buffer.count >= expected else { return }
        assembling = false
        if accept(buffer) {
            finish(.success(buffer))
        } else {
            buffer = Data()
            expected = 0
        }
    }

    func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        continuation.resume(with: result)
    }
}
