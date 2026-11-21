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
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    private var pendingUs: Int?
    private var inFlight = false
    private var inFlightSince = Date.distantPast
    private var lastAck = Date()
    private var watchdog: Timer?

    /// Mindig csak a LEGFRISSEBB érték megy ki: ha a Bluetooth még foglalt,
    /// a köztes értékek eldobódnak, így nem gyűlik fel késés.
    func send(us: Int, force: Bool = false) {
        guard peripheral != nil, target != nil else { return }
        if !force && us == lastSent && pendingUs == nil { return }
        pendingUs = us
        flush()
    }

    /// Mindig nyugtázott írás (withResponse). A válasz nélküli írást szándékosan nem használjuk:
    /// iOS-en a canSendWriteWithoutResponse egy idő után tartósan false-on ragadhat, és a
    /// peripheralIsReady sem jön meg -> az app örökre vár (ettől állt le a motor).
    private func flush() {
        guard let p = peripheral, let t = target, let us = pendingUs, !inFlight else { return }
        inFlight = true
        inFlightSince = Date()
        p.writeValue(Data(String(us).utf8), for: t, type: .withResponse)
        lastSent = us
        pendingUs = nil
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        inFlight = false
        lastAck = Date()
        flush()
    }

    /// Őrkutya: ha egy írásra 1,5 s alatt nem jön nyugta, a kapcsolat beragadt -> bontás és újracsatlakozás
    /// (ugyanaz, amit az app újraindítása csinált). Mozgás nélkül másodpercenként életjelet küld,
    /// hogy a beragadás akkor is kiderüljön, ha épp nincs új érték.
    private func tick() {
        guard let p = peripheral, target != nil else { return }
        let now = Date()
        if inFlight && now.timeIntervalSince(inFlightSince) > 1.5 {
            state = "Kapcsolat beragadt, újracsatlakozás…"
            central.cancelPeripheralConnection(p)   // didDisconnect -> reset() -> újrakeresés
            return
        }
        if !inFlight && pendingUs == nil && lastSent >= 0 && now.timeIntervalSince(lastAck) > 1.0 {
            pendingUs = lastSent
            flush()
        }
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
            lastAck = Date()
            connected = true
            state = "ESP32 csatlakozva"
        }
    }
}
