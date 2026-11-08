import CoreBluetooth
import Foundation
import Observation

/// Connects to a Bluetooth laser distance meter and publishes every distance the
/// worker measures with the device's own button.
///
/// Supported protocols (both commonly used in Germany):
/// - Leica DISTO (D1, D2, D110, D510, X3, X4 …): distance characteristic sends a
///   little-endian Float32 in metres.
/// - Bosch GLM / PLR with Bluetooth (GLM 50 C, GLM 100 C, GLM 120 C …): after an
///   "auto sync" command the device sends one frame per measurement with the
///   distance as little-endian Float32 in metres at byte 7.
@Observable
final class LaserMeterManager: NSObject {
    enum State: Equatable {
        case bluetoothOff
        case unauthorized
        case idle
        case scanning
        case connecting(String)
        case connected(String)
    }

    struct Reading: Equatable {
        var meters: Double
        var date: Date
    }

    private(set) var state: State = .idle
    /// Devices found while scanning (name per peripheral id).
    private(set) var discovered: [UUID: String] = [:]
    private(set) var lastReading: Reading?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connected: CBPeripheral?
    private var wantsScan = false

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: Public API

    func startScan() {
        wantsScan = true
        discovered = [:]
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            beginScanIfPossible()
        }
    }

    func stopScan() {
        wantsScan = false
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(to id: UUID) {
        guard let central, let peripheral = peripherals[id] else { return }
        stopScan()
        state = .connecting(discovered[id] ?? "")
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func disconnect() {
        if let connected { central?.cancelPeripheralConnection(connected) }
        connected = nil
        state = .idle
    }

    // MARK: Private

    private func beginScanIfPossible() {
        guard wantsScan, let central, central.state == .poweredOn else { return }
        state = .scanning
        // Some meters do not advertise their service UUID, so scan everything and filter by name.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func publish(_ meters: Double) {
        lastReading = Reading(meters: meters, date: .now)
    }
}

// MARK: - CoreBluetooth delegates (callbacks arrive on the main queue)

extension LaserMeterManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if state == .bluetoothOff || state == .unauthorized { state = .idle }
                beginScanIfPossible()
            case .unauthorized:
                state = .unauthorized
            default:
                state = .bluetoothOff
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        MainActor.assumeIsolated {
            guard LaserMeterProtocol.isLaserMeter(name: name, services: services) else { return }
            peripherals[peripheral.identifier] = peripheral
            discovered[peripheral.identifier] = name ?? String(localized: "Laser meter")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            connected = peripheral
            state = .connected(discovered[peripheral.identifier] ?? peripheral.name ?? "")
            peripheral.discoverServices([LaserMeterProtocol.leicaService, LaserMeterProtocol.boschService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { state = .idle }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if connected?.identifier == peripheral.identifier { connected = nil }
            state = .idle
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            if service.uuid == LaserMeterProtocol.leicaService {
                peripheral.discoverCharacteristics([LaserMeterProtocol.leicaDistance], for: service)
            } else if service.uuid == LaserMeterProtocol.boschService {
                peripheral.discoverCharacteristics([LaserMeterProtocol.boschData], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == LaserMeterProtocol.leicaDistance || characteristic.uuid == LaserMeterProtocol.boschData {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.uuid == LaserMeterProtocol.boschData {
                // Ask the Bosch meter to send every measurement automatically.
                peripheral.writeValue(LaserMeterProtocol.boschAutoSync, for: characteristic, type: .withResponse)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let meters: Double?
        if characteristic.uuid == LaserMeterProtocol.leicaDistance {
            meters = LaserMeterProtocol.leicaDistance(from: data)
        } else if characteristic.uuid == LaserMeterProtocol.boschData {
            meters = LaserMeterProtocol.boschDistance(from: data)
        } else {
            meters = nil
        }
        guard let meters else { return }
        MainActor.assumeIsolated { publish(meters) }
    }
}

// MARK: - Device protocols (pure, testable)

nonisolated enum LaserMeterProtocol {
    // Leica DISTO
    static let leicaService = CBUUID(string: "3AB10100-F831-4395-B29D-570977D5BF94")
    static let leicaDistance = CBUUID(string: "3AB10101-F831-4395-B29D-570977D5BF94")
    // Bosch GLM
    static let boschService = CBUUID(string: "02A6C0D0-0451-4000-B000-FB3210111989")
    static let boschData = CBUUID(string: "02A6C0D1-0451-4000-B000-FB3210111989")
    static let boschAutoSync = Data([0xC0, 0x55, 0x02, 0x01, 0x00, 0x1A])

    static func isLaserMeter(name: String?, services: [CBUUID]) -> Bool {
        if services.contains(leicaService) || services.contains(boschService) { return true }
        guard let name = name?.uppercased() else { return false }
        return ["DISTO", "GLM", "PLR", "BOSCH", "LEICA", "ZAMO"].contains { name.contains($0) }
    }

    static func leicaDistance(from data: Data) -> Double? {
        guard data.count >= 4 else { return nil }
        return validated(float32(data, at: 0))
    }

    static func boschDistance(from data: Data) -> Double? {
        // Measurement frame: C0 55 10 … with the distance at bytes 7…10.
        guard data.count >= 11, data[data.startIndex] == 0xC0,
              data[data.startIndex + 1] == 0x55, data[data.startIndex + 2] == 0x10 else { return nil }
        return validated(float32(data, at: 7))
    }

    private static func float32(_ data: Data, at offset: Int) -> Float {
        let start = data.startIndex + offset
        let bits = UInt32(data[start]) | UInt32(data[start + 1]) << 8
            | UInt32(data[start + 2]) << 16 | UInt32(data[start + 3]) << 24
        return Float(bitPattern: bits)
    }

    private static func validated(_ value: Float) -> Double? {
        guard value.isFinite, value > 0.01, value < 300 else { return nil }
        return Double(value)
    }
}
