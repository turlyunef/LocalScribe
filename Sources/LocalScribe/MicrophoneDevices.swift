import Combine
import CoreAudio
import Foundation
import LocalScribeCore

struct RecordingSourcePreferences: Equatable, Sendable {
    var microphoneEnabled = true
    var systemAudioEnabled = false
    var microphone: MicrophoneSelection = .builtIn

    var hasEnabledSource: Bool { microphoneEnabled || systemAudioEnabled }

    init() {}

    private static let defaultsKey = "recordingSources"

    init(defaults: UserDefaults) {
        let settings = defaults.dictionary(forKey: Self.defaultsKey)
        microphoneEnabled = settings?["microphoneEnabled"] as? Bool ?? true
        systemAudioEnabled = settings?["systemAudioEnabled"] as? Bool ?? false
        switch settings?["microphone"] as? String {
        case "systemDefault": microphone = .systemDefault
        case "device":
            if let uid = settings?["uid"] as? String, !uid.isEmpty,
               let name = settings?["name"] as? String, !name.isEmpty {
                microphone = .device(uid: uid, name: name)
            }
        default: break
        }
    }

    func save(to defaults: UserDefaults) {
        var settings: [String: Any] = ["microphoneEnabled": microphoneEnabled, "systemAudioEnabled": systemAudioEnabled]
        switch microphone {
        case .builtIn: settings["microphone"] = "builtIn"
        case .systemDefault: settings["microphone"] = "systemDefault"
        case .device(let uid, let name):
            settings["microphone"] = "device"
            settings["uid"] = uid
            settings["name"] = name
        }
        defaults.set(settings, forKey: Self.defaultsKey)
    }
}

enum MicrophoneSelection: Hashable, Sendable {
    case builtIn
    case systemDefault
    case device(uid: String, name: String)

    var allowsAutomaticFallback: Bool {
        if case .device = self { return true }
        return false
    }

    var unavailableMessage: String {
        switch self {
        case .builtIn: return "Встроенный микрофон недоступен."
        case .systemDefault: return "Системный микрофон по умолчанию недоступен."
        case .device(_, let name): return "Микрофон «\(name)» недоступен."
        }
    }
}

struct MicrophoneInputDevice: Equatable, Identifiable, Sendable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
    var transportType: UInt32 = kAudioDeviceTransportTypeUnknown

    var id: String { uid }
    var selection: MicrophoneSelection { .device(uid: uid, name: name) }

    fileprivate var isPhysicalExternal: Bool {
        switch transportType {
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return !isBuiltIn
        default:
            return false
        }
    }
}

struct MicrophoneDevicesSnapshot: Equatable, Sendable {
    var devices: [MicrophoneInputDevice] = []
    var defaultDeviceID: AudioDeviceID?

    func device(for selection: MicrophoneSelection) -> MicrophoneInputDevice? {
        switch selection {
        case .builtIn: return devices.first(where: \.isBuiltIn)
        case .systemDefault: return devices.first { $0.deviceID == defaultDeviceID }
        case .device(let uid, _): return devices.first { $0.uid == uid }
        }
    }

    func candidates(for selection: MicrophoneSelection, keeping uid: String? = nil) -> [MicrophoneInputDevice] {
        let preferred = device(for: selection)
        guard case .device(let preferredUID, _) = selection else {
            return preferred.map { [$0] } ?? []
        }

        func rank(_ device: MicrophoneInputDevice) -> Int {
            if device.uid == uid { return 0 }
            if device.deviceID == defaultDeviceID { return 1 }
            return 2
        }
        let otherExternal = devices.filter { $0.uid != preferredUID && $0.isPhysicalExternal }
            .sorted { lhs, rhs in
                let left = rank(lhs), right = rank(rhs)
                return left == right ? lhs.uid < rhs.uid : left < right
            }
        var result = preferred.map { [$0] } ?? []
        result.append(contentsOf: otherExternal)
        if let builtIn = device(for: .builtIn), builtIn.uid != preferredUID { result.append(builtIn) }
        return result
    }
}

struct PinnedMicrophone: Equatable, Sendable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    fileprivate let route: HALInputRoute
}

/// HAL writes never change the system default input. Each start resolves a fresh
/// device, and all subsequent checks compare against that pinned route.
@MainActor final class MicrophoneDevices: ObservableObject {
    @Published private(set) var snapshot = MicrophoneDevicesSnapshot()
    private let loadSnapshot: () -> MicrophoneDevicesSnapshot
    private let loadRoute: (AudioDeviceID) -> HALInputRoute?
    private var inventoryObservation: HALPropertyObservation?
    private var deviceObservation: HALPropertyObservation?
    private let observeChanges: Bool

    init(observeChanges: Bool = true, loadSnapshot: (() -> MicrophoneDevicesSnapshot)? = nil,
         loadRoute: ((AudioDeviceID) -> HALInputRoute?)? = nil) {
        self.observeChanges = observeChanges
        self.loadSnapshot = loadSnapshot ?? HALInput.snapshot
        self.loadRoute = loadRoute ?? HALInput.route
        if observeChanges {
            inventoryObservation = HALPropertyObservation([
                HALInput.systemProperty(kAudioHardwarePropertyDevices),
                HALInput.systemProperty(kAudioHardwarePropertyDefaultInputDevice)
            ]) { [weak self] in self?.refresh() }
        }
        if observeChanges || loadSnapshot != nil { refresh() }
    }

    func refresh() {
        let current = loadSnapshot()
        let devicesChanged = snapshot.devices != current.devices
        if snapshot != current { snapshot = current }
        guard observeChanges, devicesChanged else { return }
        deviceObservation?.stop()
        deviceObservation = HALPropertyObservation(current.devices.flatMap { device in
            [HALInput.globalProperty(device.deviceID, kAudioDevicePropertyDeviceIsAlive),
             HALInput.globalProperty(device.deviceID, kAudioObjectPropertyName),
             HALInput.inputProperty(device.deviceID, kAudioDevicePropertyStreamConfiguration)]
        }) { [weak self] in self?.refresh() }
    }

    func resolve(_ selection: MicrophoneSelection) throws -> PinnedMicrophone {
        guard let device = loadSnapshot().device(for: selection), let pin = pin(device) else {
            throw ScribeError.message(selection.unavailableMessage)
        }
        return pin
    }

    func candidates(for selection: MicrophoneSelection, keeping uid: String? = nil) -> [PinnedMicrophone] {
        loadSnapshot().candidates(for: selection, keeping: uid).compactMap { pin($0) }
    }

    private func pin(_ device: MicrophoneInputDevice) -> PinnedMicrophone? {
        guard let route = loadRoute(device.deviceID), route.uid == device.uid else { return nil }
        return PinnedMicrophone(deviceID: device.deviceID, uid: device.uid, name: device.name, route: route)
    }

    func validate(_ pinned: PinnedMicrophone) throws {
        let current = try refreshFormat(of: pinned)
        guard current == pinned else {
            throw ScribeError.message("Вход или формат микрофона изменился. Автоматическое переключение отключено.")
        }
    }

    /// Bluetooth can renegotiate PCM when the same input starts streaming.
    /// A different device or reported physical input still invalidates the pin.
    func refreshFormat(of pinned: PinnedMicrophone) throws -> PinnedMicrophone {
        guard let route = loadRoute(pinned.deviceID), route.uid == pinned.uid else {
            throw ScribeError.message(MicrophoneSelection.device(uid: pinned.uid, name: pinned.name).unavailableMessage)
        }
        guard route.controls == pinned.route.controls else {
            throw ScribeError.message("Физический вход выбранного микрофона изменился.")
        }
        return PinnedMicrophone(deviceID: pinned.deviceID, uid: pinned.uid, name: pinned.name, route: route)
    }

    func isMuted(_ microphone: PinnedMicrophone) -> Bool {
        microphoneMuteState(microphone) == true
    }

    func microphoneMuteState(_ microphone: PinnedMicrophone) -> Bool? {
        let device = microphone.deviceID
        guard HALInput.isAlive(device),
              HALInput.string(HALInput.globalProperty(device, kAudioDevicePropertyDeviceUID)) == microphone.uid else { return nil }

        let channels = microphone.route.channels
        let available = HALInput.muteProperties(device, channels: channels).filter { property in
            var address = property.address
            return AudioObjectHasProperty(device, &address)
        }
        guard !available.isEmpty else { return nil }
        var mutedChannels = 0
        for property in available {
            guard let value = HALInput.scalar(property, initial: UInt32(0)) else { return nil }
            if property.element == kAudioObjectPropertyElementMain {
                if value == 1 { return true }
            } else if value == 1 {
                mutedChannels += 1
            }
        }
        return mutedChannels == channels
    }

    func observe(_ pinned: PinnedMicrophone, changes: @escaping @MainActor () -> Void) -> HALPropertyObservation {
        let device = pinned.deviceID
        return HALPropertyObservation([
            HALInput.systemProperty(kAudioHardwarePropertyDevices),
            HALInput.globalProperty(device, kAudioDevicePropertyDeviceIsAlive),
            HALInput.globalProperty(device, kAudioDevicePropertyNominalSampleRate),
            HALInput.globalProperty(device, kAudioDevicePropertyDeviceHasChanged),
            HALInput.globalProperty(device, kAudioObjectPropertyControlList),
            HALInput.inputProperty(device, kAudioDevicePropertyStreams),
            HALInput.inputProperty(device, kAudioDevicePropertyStreamConfiguration)
        ] + HALInput.muteProperties(device, channels: pinned.route.channels)
          + pinned.route.controls.map(\.property) + pinned.route.streams.flatMap { stream in
            [HALInput.globalProperty(stream.id, kAudioStreamPropertyVirtualFormat),
             HALInput.globalProperty(stream.id, kAudioStreamPropertyPhysicalFormat)]
        }, changes: changes)
    }
}

/// Retains the exact block, queue, object and address needed to unregister.
final class HALPropertyObservation {
    private var registrations: [HALInput.Property] = []
    private let block: AudioObjectPropertyListenerBlock
    private let active = NSLock()
    private var stopped = false

    fileprivate init(_ properties: [HALInput.Property], changes: @escaping @MainActor () -> Void) {
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in changes() }
        }
        block = listener
        for property in properties {
            var address = property.address
            if AudioObjectHasProperty(property.object, &address),
               AudioObjectAddPropertyListenerBlock(property.object, &address, .main, listener) == noErr {
                registrations.append(property)
            }
        }
    }

    func stop() {
        let pending = active.withLock {
            guard !stopped else { return [HALInput.Property]() }
            stopped = true
            return registrations
        }
        for property in pending {
            var address = property.address
            AudioObjectRemovePropertyListenerBlock(property.object, &address, .main, block)
        }
    }

    deinit { stop() }
}

struct HALInputRoute: Equatable, Sendable {
    let uid: String
    let nominalRate: Double
    let channels: Int
    let streams: [HALInput.Stream]
    let controls: [HALInput.Control]
}

enum HALInput {
    struct Property: Equatable, Sendable {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
        let element: AudioObjectPropertyElement

        var address: AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        }
    }

    struct Control: Equatable, Sendable {
        let property: Property
        let values: [UInt32]?
    }

    struct Stream: Equatable, Sendable {
        let id: AudioStreamID
        let virtual: Format?
        let physical: Format?
    }

    struct Format: Equatable, Sendable {
        let rate: Double
        let id: UInt32
        let flags: UInt32
        let bytesPerPacket: UInt32
        let framesPerPacket: UInt32
        let bytesPerFrame: UInt32
        let channels: UInt32
        let bitsPerChannel: UInt32

        init(_ format: AudioStreamBasicDescription) {
            rate = format.mSampleRate
            id = format.mFormatID
            flags = format.mFormatFlags
            bytesPerPacket = format.mBytesPerPacket
            framesPerPacket = format.mFramesPerPacket
            bytesPerFrame = format.mBytesPerFrame
            channels = format.mChannelsPerFrame
            bitsPerChannel = format.mBitsPerChannel
        }
    }

    static func globalProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Property {
        Property(object: object, selector: selector, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain)
    }

    static func inputProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Property {
        Property(object: object, selector: selector, scope: kAudioObjectPropertyScopeInput, element: element)
    }

    static func systemProperty(_ selector: AudioObjectPropertySelector) -> Property {
        globalProperty(AudioObjectID(kAudioObjectSystemObject), selector)
    }

    static func muteProperties(_ device: AudioDeviceID, channels: Int) -> [Property] {
        (0...channels).map { inputProperty(device, kAudioDevicePropertyMute, element: AudioObjectPropertyElement($0)) }
    }

    static func snapshot() -> MicrophoneDevicesSnapshot {
        let ids = uint32Values(systemProperty(kAudioHardwarePropertyDevices)) ?? []
        let devices = ids.compactMap { id -> MicrophoneInputDevice? in
            guard isAlive(id), (channelCount(id) ?? 0) > 0,
                  let uid = string(globalProperty(id, kAudioDevicePropertyDeviceUID)),
                  let name = string(globalProperty(id, kAudioObjectPropertyName)) else { return nil }
            let transport = scalar(globalProperty(id, kAudioDevicePropertyTransportType),
                                   initial: kAudioDeviceTransportTypeUnknown) ?? kAudioDeviceTransportTypeUnknown
            return MicrophoneInputDevice(deviceID: id, uid: uid, name: name,
                                         isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                                         transportType: transport)
        }
        return MicrophoneDevicesSnapshot(devices: devices, defaultDeviceID: scalar(systemProperty(kAudioHardwarePropertyDefaultInputDevice),
                                                                                     initial: AudioDeviceID(0)))
    }

    static func route(_ id: AudioDeviceID) -> HALInputRoute? {
        guard isAlive(id), let uid = string(globalProperty(id, kAudioDevicePropertyDeviceUID)),
              let channels = channelCount(id), channels > 0,
              let rate = scalar(globalProperty(id, kAudioDevicePropertyNominalSampleRate), initial: Double(0)),
              rate.isFinite, rate > 0,
              let streamIDs = uint32Values(inputProperty(id, kAudioDevicePropertyStreams)), !streamIDs.isEmpty else { return nil }
        let streams = streamIDs.map { streamID in
            Stream(id: streamID,
                   virtual: format(globalProperty(streamID, kAudioStreamPropertyVirtualFormat)),
                   physical: format(globalProperty(streamID, kAudioStreamPropertyPhysicalFormat)))
        }
        let controls = (0...channels).flatMap { element in
            [kAudioDevicePropertyDataSource, kAudioDevicePropertyJackIsConnected].compactMap { selector -> Control? in
                let property = inputProperty(id, selector, element: AudioObjectPropertyElement(element))
                var address = property.address
                guard AudioObjectHasProperty(id, &address) else { return nil }
                let values = selector == kAudioDevicePropertyDataSource
                    ? uint32Values(property)?.sorted()
                    : scalar(property, initial: UInt32(0)).map { [$0] }
                return Control(property: property, values: values)
            }
        }
        return HALInputRoute(uid: uid, nominalRate: rate, channels: channels, streams: streams, controls: controls)
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool {
        scalar(globalProperty(id, kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0)) == 1
    }

    static func channelCount(_ id: AudioDeviceID) -> Int? {
        let property = inputProperty(id, kAudioDevicePropertyStreamConfiguration)
        var address = property.address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return nil }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, data) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
        let listHeader = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride
        guard list.count <= (Int(size) - listHeader) / MemoryLayout<AudioBuffer>.stride else { return nil }
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func uint32Values(_ property: Property) -> [UInt32]? {
        var address = property.address
        var size: UInt32 = 0
        let stride = MemoryLayout<UInt32>.stride
        for _ in 0..<2 {
            guard AudioObjectGetPropertyDataSize(property.object, &address, 0, nil, &size) == noErr else { return nil }
            guard size > 0 else { return [] }
            guard Int(size).isMultiple(of: stride) else { return nil }
            var values = [UInt32](repeating: 0, count: Int(size) / stride)
            let status = values.withUnsafeMutableBytes { bytes in
                AudioObjectGetPropertyData(property.object, &address, 0, nil, &size, bytes.baseAddress!)
            }
            if status == noErr, Int(size).isMultiple(of: stride), Int(size) / stride <= values.count {
                return Array(values.prefix(Int(size) / stride))
            }
        }
        return nil
    }

    static func scalar<T>(_ property: Property, initial: T) -> T? {
        var address = property.address
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(property.object, &address, 0, nil, &size, pointer)
        }
        return status == noErr && size == MemoryLayout<T>.size ? value : nil
    }

    static func string(_ property: Property) -> String? {
        guard let result = scalar(property, initial: nil as Unmanaged<CFString>?),
              let value = result?.takeRetainedValue() as String?, !value.isEmpty else { return nil }
        return value
    }

    static func format(_ property: Property) -> Format? {
        guard let value = scalar(property, initial: AudioStreamBasicDescription()), value.mSampleRate.isFinite else { return nil }
        return Format(value)
    }
}
