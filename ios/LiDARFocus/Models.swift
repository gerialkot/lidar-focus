import Foundation

/// Egy kalibrációs pont: ezen a távolságon ennél a szervóértéknél éles a kép.
struct CalPoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var distance: Float   // méter
    var us: Int           // szervó impulzus (µs)
}

/// Lencseprofil: objektívenként saját kalibráció és szervóhatárok.
struct LensProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var minUs: Int = 600
    var maxUs: Int = 2400
    var points: [CalPoint] = []

    var isCalibrated: Bool { points.count >= 2 }

    /// Távolság -> szervó µs. Az élességskála kb. az 1/távolsággal arányos, ezért 1/d szerint interpolál.
    func us(for d: Float) -> Int? {
        guard isCalibrated, d > 0 else { return nil }
        let p = points.sorted { 1 / $0.distance < 1 / $1.distance }
        let x = 1 / d
        var result: Int
        if x <= 1 / p[0].distance {
            result = p[0].us
        } else if x >= 1 / p[p.count - 1].distance {
            result = p[p.count - 1].us
        } else {
            result = p[0].us
            for i in 0..<(p.count - 1) {
                let a = p[i], b = p[i + 1]
                let xa = 1 / a.distance, xb = 1 / b.distance
                if x >= xa && x <= xb {
                    if xb - xa < 1e-6 { result = a.us; break }
                    let t = (x - xa) / (xb - xa)
                    result = Int((Float(a.us) + t * Float(b.us - a.us)).rounded())
                    break
                }
            }
        }
        return min(max(result, minUs), maxUs)
    }
}

/// Lencseprofilok tárolása (UserDefaults), aktív profil kezelése.
final class ProfileStore: ObservableObject {
    @Published var profiles: [LensProfile] { didSet { save() } }
    @Published var activeID: UUID {
        didSet { UserDefaults.standard.set(activeID.uuidString, forKey: activeKey) }
    }

    private let key = "lens.profiles"
    private let activeKey = "lens.active"

    init() {
        var loaded: [LensProfile] = []
        if let data = UserDefaults.standard.data(forKey: key),
           let p = try? JSONDecoder().decode([LensProfile].self, from: data) {
            loaded = p
        }
        if loaded.isEmpty {
            // Az előző verzió kalibrációjának átvétele
            var first = LensProfile(name: "Alap objektív")
            if let data = UserDefaults.standard.data(forKey: "calibration.points"),
               let pts = try? JSONDecoder().decode([CalPoint].self, from: data) {
                first.points = pts
            }
            loaded = [first]
        }
        let savedID = UserDefaults.standard.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
        profiles = loaded
        activeID = loaded.first(where: { $0.id == savedID })?.id ?? loaded[0].id
        save()
    }

    var active: LensProfile {
        profiles.first { $0.id == activeID } ?? profiles[0]
    }

    func updateActive(_ change: (inout LensProfile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == activeID }) else { return }
        change(&profiles[i])
    }

    func add(name: String) {
        let p = LensProfile(name: name)
        profiles.append(p)
        activeID = p.id
    }

    func delete(_ id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = profiles[0].id }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
}

/// One Euro szűrő: álló célpontnál erősen simít, gyors mozgásnál alig késik.
struct OneEuroFilter {
    private let minCutoff: Double
    private let beta: Double
    private let dCutoff: Double
    private var x: Double?
    private var dx: Double = 0
    private var t: Double?

    init(minCutoff: Double, beta: Double, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    mutating func reset() {
        x = nil
        t = nil
        dx = 0
    }

    mutating func filter(_ value: Double, time: Double) -> Double {
        guard let px = x, let pt = t, time > pt else {
            x = value
            t = time
            return value
        }
        let dt = time - pt
        let ad = alpha(dCutoff, dt)
        dx = ad * ((value - px) / dt) + (1 - ad) * dx
        let a = alpha(minCutoff + beta * abs(dx), dt)
        let nx = a * value + (1 - a) * px
        x = nx
        t = time
        return nx
    }

    private func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
