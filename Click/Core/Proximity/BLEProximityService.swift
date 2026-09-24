import CoreBluetooth
import Foundation

/// The Bluetooth factor of Tap to Connect (spec §23.5).
///
/// Advertises only the Click service UUID and serves this tap's 4-digit token from a readable
/// GATT characteristic; scans for the same service, connects, and reads peers' tokens. Wire
/// identifiers match KMP `ProximityBleCodec`. All radio work is bounded and stops on `stop()`.
/// Callbacks arrive on the main queue (`queue: nil`), so state is main-actor isolated.
@MainActor
final class BLEProximityService: NSObject {
    enum Availability: Equatable, Sendable {
        case ready
        case poweredOff
        case unauthorized
        case unsupported
    }

    private let serviceUUID = CBUUID(string: ProximityCodec.serviceUUID)
    private let characteristicUUID = CBUUID(string: ProximityCodec.tokenCharacteristicUUID)

    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var tokenCharacteristic: CBMutableCharacteristic?
    private var tokenPayload = Data()
    private var ownToken = ""
    private var wantsAdvertising = false
    private var wantsScanning = false
    private var connecting: [UUID: CBPeripheral] = [:]
    private var attempted: Set<UUID> = []
    private(set) var detectedTokens: Set<String> = []
    private var stateWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates the central manager (which shows the system Bluetooth prompt the first time) and
    /// waits until CoreBluetooth resolves its state. Called only after explicit user intent.
    func prepare() async -> Availability {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        }
        if let central, central.state == .unknown || central.state == .resetting {
            // The first state update arrives after the user answers the Bluetooth prompt; the
            // timeout keeps an unanswered prompt from hanging the flow.
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.resumeStateWaiters()
            }
            await withCheckedContinuation { stateWaiters.append($0) }
            timeout.cancel()
        }
        return availability(central?.state ?? .unknown)
    }

    /// Advertises `token` and scans for peers for `hold`, then waits up to `grace` for in-flight
    /// GATT reads. Returns peer tokens (never this device's own).
    func exchange(token: String, hold: Duration, grace: Duration) async -> Set<String> {
        ownToken = token
        tokenPayload = ProximityCodec.gattPayload(token)
        detectedTokens = []
        attempted = []
        wantsAdvertising = true
        wantsScanning = true
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        } else {
            publishService()
        }
        startScanIfReady()

        try? await Task.sleep(for: hold)
        wantsScanning = false
        central?.stopScan()
        let graceDeadline = ContinuousClock.now + grace
        while !connecting.isEmpty, ContinuousClock.now < graceDeadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        stop()
        return detectedTokens
    }

    /// Stops advertising, scanning, and connections immediately.
    func stop() {
        wantsAdvertising = false
        wantsScanning = false
        central?.stopScan()
        for peripheral in connecting.values {
            central?.cancelPeripheralConnection(peripheral)
        }
        connecting = [:]
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        tokenCharacteristic = nil
    }

    private func availability(_ state: CBManagerState) -> Availability {
        switch state {
        case .poweredOn: .ready
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        default: .unsupported
        }
    }

    private func startScanIfReady() {
        guard wantsScanning, let central, central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func publishService() {
        guard wantsAdvertising, let peripheralManager, peripheralManager.state == .poweredOn,
              tokenCharacteristic == nil else { return }
        let characteristic = CBMutableCharacteristic(
            type: characteristicUUID,
            properties: .read,
            value: nil,
            permissions: .readable
        )
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [characteristic]
        tokenCharacteristic = characteristic
        peripheralManager.add(service)
    }

    private func resumeStateWaiters() {
        let waiters = stateWaiters
        stateWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func finishRead(_ peripheral: CBPeripheral) {
        connecting[peripheral.identifier] = nil
        central?.cancelPeripheralConnection(peripheral)
    }
}

extension BLEProximityService: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        resumeStateWaiters()
        startScanIfReady()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard wantsScanning, !attempted.contains(peripheral.identifier) else { return }
        attempted.insert(peripheral.identifier)
        connecting[peripheral.identifier] = peripheral
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connecting[peripheral.identifier] = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connecting[peripheral.identifier] = nil
    }
}

extension BLEProximityService: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            finishRead(peripheral)
            return
        }
        peripheral.discoverCharacteristics([characteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
            finishRead(peripheral)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if error == nil, let token = ProximityCodec.parseGattPayload(characteristic.value), token != ownToken {
            detectedTokens.insert(token)
        }
        finishRead(peripheral)
    }
}

extension BLEProximityService: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        publishService()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil, wantsAdvertising else { return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == characteristicUUID else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= tokenPayload.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = tokenPayload.subdata(in: request.offset..<tokenPayload.count)
        peripheral.respond(to: request, withResult: .success)
    }
}
