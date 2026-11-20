import Foundation

struct CalPoint: Codable, Identifiable {
    var id = UUID()
    var distance: Float   // méter
    var us: Int           // szervó impulzus
}

/// Kalibrációs tábla: távolság -> szervó µs.
/// Az objektív élességskálája kb. az 1/távolsággal arányos, ezért 1/d szerint interpolálunk.
final class Calibration: ObservableObject {
    @Published var points: [CalPoint] = [] { didSet { save() } }
    private let key = "calibration.points"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let p = try? JSONDecoder().decode([CalPoint].self, from: data) {
            points = p
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(points) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func us(for d: Float) -> Int? {
        guard points.count >= 2, d > 0 else { return nil }
        let p = points.sorted { 1 / $0.distance < 1 / $1.distance }
        let x = 1 / d
        if x <= 1 / p[0].distance { return p[0].us }
        if x >= 1 / p[p.count - 1].distance { return p[p.count - 1].us }
        for i in 0..<(p.count - 1) {
            let a = p[i], b = p[i + 1]
            let xa = 1 / a.distance, xb = 1 / b.distance
            if x >= xa && x <= xb {
                if xb - xa < 1e-6 { return a.us }
                let t = (x - xa) / (xb - xa)
                return Int((Float(a.us) + t * Float(b.us - a.us)).rounded())
            }
        }
        return nil
    }
}
