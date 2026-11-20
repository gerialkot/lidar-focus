import ARKit
import Vision

/// ARKit + LiDAR + Vision: a kijelölt célpont követése és a távolság mérése.
/// Koordináták: "kép" = a kamera nyers (fekvő) képe, normalizált 0..1, bal felső origó.
///              "nézet" = a képernyő, normalizált 0..1, bal felső origó.
final class FocusEngine: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published var boxView: CGRect?          // a követett keret a képernyőn (normalizált)
    @Published var distance: Float?          // simított távolság méterben
    @Published var status = "Bökj rá a célpontra"

    private let queue = DispatchQueue(label: "focus.engine")
    private let sequenceHandler = VNSequenceRequestHandler()
    private var trackRequest: VNTrackObjectRequest?
    private var pendingTap: CGPoint?
    private var viewSize: CGSize = .zero
    private var smoothed: Float?
    private var frameCount = 0
    private var lastImageRect: CGRect?

    func start() {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            status = "Ez a készülék nem támogatja a LiDAR mélységet"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
            ? [.sceneDepth, .smoothedSceneDepth] : [.sceneDepth]
        session.delegate = self
        session.delegateQueue = queue
        session.run(config)
    }

    /// Rábökés a képernyőre (pont pixelben, a nézet méretével).
    func tap(at point: CGPoint, viewSize size: CGSize) {
        let norm = CGPoint(x: point.x / size.width, y: point.y / size.height)
        queue.async {
            self.viewSize = size
            self.pendingTap = norm
        }
    }

    func clear() {
        queue.async {
            self.trackRequest = nil
            self.lastImageRect = nil
            self.smoothed = nil
            DispatchQueue.main.async {
                self.boxView = nil
                self.distance = nil
                self.status = "Bökj rá a célpontra"
            }
        }
    }

    // MARK: - ARSessionDelegate (a saját sorunkon fut)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard viewSize != .zero else { return }
        let toView = frame.displayTransform(for: .portrait, viewportSize: viewSize)
        frameCount += 1

        // Új kijelölés
        if let tap = pendingTap {
            pendingTap = nil
            let p = tap.applying(toView.inverted())
            let half: CGFloat = 0.08
            let imgRect = CGRect(x: p.x - half, y: p.y - half, width: half * 2, height: half * 2)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let visionRect = CGRect(x: imgRect.minX, y: 1 - imgRect.maxY, width: imgRect.width, height: imgRect.height)
            let req = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: visionRect))
            req.trackingLevel = .accurate
            trackRequest = req
            lastImageRect = imgRect
            smoothed = nil
            publish(status: "Követés")
        }

        guard let req = trackRequest else { return }

        // Követés minden 2. képkockán (30 Hz), a mélység minden képkockán
        if frameCount % 2 == 0 {
            do {
                try sequenceHandler.perform([req], on: frame.capturedImage, orientation: .up)
            } catch {
                lost(); return
            }
            guard let obs = req.results?.first as? VNDetectedObjectObservation, obs.confidence > 0.3 else {
                lost(); return
            }
            req.inputObservation = obs
            let r = obs.boundingBox
            lastImageRect = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        }

        guard let imgRect = lastImageRect else { return }
        let viewRect = imgRect.applying(toView)

        if let d = depth(in: imgRect, frame: frame) {
            smoothed = smoothed.map { $0 * 0.7 + d * 0.3 } ?? d
        }
        let dist = smoothed
        DispatchQueue.main.async {
            self.boxView = viewRect
            self.distance = dist
        }
    }

    private func lost() {
        trackRequest = nil
        lastImageRect = nil
        DispatchQueue.main.async {
            self.boxView = nil
            self.status = "Célpont elveszett, bökj rá újra"
        }
    }

    private func publish(status: String) {
        DispatchQueue.main.async { self.status = status }
    }

    /// A keret középső részének LiDAR-mélysége: a megbízható pontok 30. percentilise
    /// (így inkább az előtérben lévő célpontot méri, nem a mögötte lévő hátteret).
    private func depth(in r: CGRect, frame: ARFrame) -> Float? {
        guard let sd = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let dm = sd.depthMap
        CVPixelBufferLockBaseAddress(dm, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dm, .readOnly) }
        let w = CVPixelBufferGetWidth(dm), h = CVPixelBufferGetHeight(dm)
        guard let base = CVPixelBufferGetBaseAddress(dm) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(dm)

        var confBase: UnsafeMutableRawPointer?
        var confRow = 0
        if let cm = sd.confidenceMap {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            confBase = CVPixelBufferGetBaseAddress(cm)
            confRow = CVPixelBufferGetBytesPerRow(cm)
        }
        defer { if let cm = sd.confidenceMap { CVPixelBufferUnlockBaseAddress(cm, .readOnly) } }

        let x0 = max(0, Int((r.midX - r.width * 0.25) * CGFloat(w)))
        let x1 = min(w - 1, Int((r.midX + r.width * 0.25) * CGFloat(w)))
        let y0 = max(0, Int((r.midY - r.height * 0.25) * CGFloat(h)))
        let y1 = min(h - 1, Int((r.midY + r.height * 0.25) * CGFloat(h)))
        guard x0 <= x1, y0 <= y1 else { return nil }

        var vals: [Float] = []
        vals.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for y in y0...y1 {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
            let conf = confBase.map { ($0 + y * confRow).assumingMemoryBound(to: UInt8.self) }
            for x in x0...x1 {
                let v = row[x]
                if v > 0, v.isFinite, (conf?[x] ?? 2) >= 1 { vals.append(v) }
            }
        }
        guard vals.count >= 5 else { return nil }
        vals.sort()
        return vals[vals.count * 3 / 10]
    }
}
