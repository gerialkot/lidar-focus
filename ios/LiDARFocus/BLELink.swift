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
    private var lastTime = Date.distantPast

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Küldés max. 30 Hz-en, csak ha változott (force: mindig).
    func send(us: Int, force: Bool = false) {
        guard let p = peripheral, let t = target else { return }
        let now = Date()
        if !force && (us == lastSent || now.timeIntervalSince(lastTime) < 0.033) { return }
        lastSent = us
        lastTime = now
        let type: CBCharacteristicWriteType = t.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data(String(us).utf8), for: t, type: type)
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
