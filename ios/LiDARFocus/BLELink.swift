import CoreBluetooth

/// Bluetooth kapcsolat az ESP32-vel ("LiDARFocus"). A szervó értékét szövegként küldi, pl. "1500".
final class BLELink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var state = "Bluetooth indul..."
    @Published var connected = false

    private let serviceUUID = CBUUID(string: "d4d460b4-0917-44c6-bcb5-1bedf9ba1fe6")
    private let targetUUID = CBUUID(string: "02fe3441-a588-4c2b-9e64-6b85d560343c")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var target: CBCharacteristic?
    private var lastSent = -1

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private var pendingUs: Int?
    private var inFlight = false

    /// Mindig csak a LEGFRISSEBB érték megy ki: ha a Bluetooth még foglalt,
    /// a köztes értékek eldobódnak, így nem gyűlik fel késés.
    func send(us: Int, force: Bool = false) {
        guard peripheral != nil, target != nil else { return }
        if !force && us == lastSent && pendingUs == nil { return }
        pendingUs = us
        flush()
    }

    private func flush() {
        guard let p = peripheral, let t = target, let us = pendingUs else { return }
        let data = Data(String(us).utf8)
        if t.properties.contains(.writeWithoutResponse) {
            guard p.canSendWriteWithoutResponse else { return }   // peripheralIsReady hívja újra
            p.writeValue(data, for: t, type: .withoutResponse)
        } else {
            guard !inFlight else { return }                       // didWriteValueFor hívja újra
            inFlight = true
            p.writeValue(data, for: t, type: .withResponse)
        }
        lastSent = us
        pendingUs = nil
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        inFlight = false
        flush()
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        flush()
    }

    private func scan() {
        state = "Keresés: LiDARFocus..."
        central.scanForPeripherals(withServices: [serviceUUID])
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn { scan() } else { state = "Bluetooth nem elérhető" }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        c.stopScan()
        peripheral = p
        p.delegate = self
        state = "Csatlakozás..."
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        reset()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        reset()
    }

    private func reset() {
        connected = false
        target = nil
        peripheral = nil
        lastSent = -1
        pendingUs = nil
        inFlight = false
        scan()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == serviceUUID {
            p.discoverCharacteristics([targetUUID], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if let c = s.characteristics?.first(where: { $0.uuid == targetUUID }) {
            target = c
            connected = true
            state = "ESP32 csatlakozva"
        }
    }
}
