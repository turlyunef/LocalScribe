import CoreAudio
import XCTest
@testable import LocalScribe

@MainActor final class MicrophoneRoutingTests: XCTestCase {
    private let preferred = MicrophoneInputDevice(deviceID: 11, uid: "selected", name: "Headset", isBuiltIn: false,
                                                   transportType: kAudioDeviceTransportTypeBluetooth)
    private let otherHeadset = MicrophoneInputDevice(deviceID: 12, uid: "z-other", name: "Headset", isBuiltIn: false,
                                                      transportType: kAudioDeviceTransportTypeBluetooth)
    private let usb = MicrophoneInputDevice(deviceID: 13, uid: "a-usb", name: "USB microphone", isBuiltIn: false,
                                             transportType: kAudioDeviceTransportTypeUSB)
    private let builtIn = MicrophoneInputDevice(deviceID: 14, uid: "built-in", name: "MacBook", isBuiltIn: true,
                                                 transportType: kAudioDeviceTransportTypeBuiltIn)
    private let virtual = MicrophoneInputDevice(deviceID: 15, uid: "virtual", name: "Loopback", isBuiltIn: false,
                                                 transportType: kAudioDeviceTransportTypeVirtual)
    private let aggregate = MicrophoneInputDevice(deviceID: 16, uid: "aggregate", name: "Aggregate", isBuiltIn: false,
                                                   transportType: kAudioDeviceTransportTypeAggregate)

    func testSelectedUIDOutranksWorkingExternalAndBuiltIn() async {
        var inventory = MicrophoneDevicesSnapshot(
            devices: [builtIn, otherHeadset, virtual, aggregate, usb, preferred],
            defaultDeviceID: usb.deviceID
        )
        XCTAssertEqual(inventory.candidates(for: preferred.selection, keeping: otherHeadset.uid),
                       [preferred, otherHeadset, usb, builtIn])

        inventory.devices.removeAll { $0.uid == preferred.uid }
        XCTAssertEqual(inventory.candidates(for: preferred.selection), [usb, otherHeadset, builtIn])
        XCTAssertEqual(inventory.candidates(for: preferred.selection, keeping: otherHeadset.uid),
                       [otherHeadset, usb, builtIn])
        XCTAssertEqual(inventory.candidates(for: preferred.selection, keeping: builtIn.uid), [usb, otherHeadset, builtIn])

        inventory.defaultDeviceID = otherHeadset.deviceID
        XCTAssertEqual(inventory.candidates(for: preferred.selection), [otherHeadset, usb, builtIn])
        inventory.defaultDeviceID = virtual.deviceID
        XCTAssertEqual(inventory.candidates(for: preferred.selection), [usb, otherHeadset, builtIn])
        XCTAssertEqual(inventory.candidates(for: preferred.selection, keeping: aggregate.uid), [usb, otherHeadset, builtIn])
    }

    func testExplicitVirtualSelectionAndStrictBuiltInAndDefaultModes() async {
        var inventory = MicrophoneDevicesSnapshot(devices: [usb, builtIn, virtual], defaultDeviceID: virtual.deviceID)
        XCTAssertTrue(virtual.selection.allowsAutomaticFallback)
        XCTAssertFalse(MicrophoneSelection.builtIn.allowsAutomaticFallback)
        XCTAssertFalse(MicrophoneSelection.systemDefault.allowsAutomaticFallback)
        XCTAssertEqual(inventory.candidates(for: virtual.selection), [virtual, usb, builtIn])
        XCTAssertEqual(inventory.candidates(for: .builtIn), [builtIn])
        XCTAssertEqual(inventory.candidates(for: .systemDefault), [virtual])

        inventory.devices = [usb]
        XCTAssertTrue(inventory.candidates(for: .builtIn).isEmpty)
        XCTAssertTrue(inventory.candidates(for: .systemDefault).isEmpty)
    }

    func testCandidatePinsUseFreshInventoryAndRejectReusedDeviceID() async {
        var inventory = MicrophoneDevicesSnapshot(devices: [preferred, usb, builtIn], defaultDeviceID: usb.deviceID)
        func route(_ uid: String) -> HALInputRoute {
            HALInputRoute(uid: uid, nominalRate: 48_000, channels: 1, streams: [], controls: [])
        }
        var routes = [preferred.deviceID: route(otherHeadset.uid), usb.deviceID: route(usb.uid),
                      builtIn.deviceID: route(builtIn.uid)]
        let devices = MicrophoneDevices(observeChanges: false, loadSnapshot: { inventory }, loadRoute: { routes[$0] })
        XCTAssertEqual(devices.candidates(for: preferred.selection).map(\.uid), [usb.uid, builtIn.uid])
        XCTAssertThrowsError(try devices.resolve(preferred.selection))

        let reattached = MicrophoneInputDevice(deviceID: 20, uid: preferred.uid, name: preferred.name, isBuiltIn: false,
                                                transportType: preferred.transportType)
        inventory.devices = [usb, reattached, builtIn]
        routes[reattached.deviceID] = route(reattached.uid)
        XCTAssertEqual(devices.snapshot.device(for: preferred.selection)?.deviceID, preferred.deviceID)
        XCTAssertEqual(devices.candidates(for: preferred.selection).first?.deviceID, reattached.deviceID)
    }
}
