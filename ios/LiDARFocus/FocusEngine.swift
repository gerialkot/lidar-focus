import ARKit
import Vision

enum TargetKind { case person, object }
enum TrackState: Equatable { case idle, tracking, searching }

/// ARKit + LiDAR + Vision.
/// - Ember: minden képkockán emberkeresés (Vision), a kijelölt személyt helyzet alapján azonosítja újra.
///   Távolság: arc, ha látszik; különben csak az ember pixelei (ARKit személyszegmentálás).
/// - Tárgy: Vision tárgykövető.
/// Koordináták: "nyers" = a kamera fekvő képe, normalizált 0..1, bal felső origó.
///              "nézet" = a képernyő, normalizált 0..1, bal felső origó.
final class FocusEngine: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published var targetView: CGRect?
    @Published var faceView: CGRect?
    @Published var peopleView: [CGRect] = []
    @Published var kind: TargetKind = .person
    @Published var state: TrackState = .idle
    @Published var distance: Float?

    private let queue = DispatchQueue(label: "focus.engine", qos: .userInteractive)
    private let sequenceHandler = VNSequenceRequestHandler()
    private let humanRequest: VNDetectHumanRectanglesRequest = {
        let r = VNDetectHumanRectanglesRequest()
        r.upperBodyOnly = false
        return r
    }()
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private var trackRequest: VNTrackObjectRequest?

    private var semantics: ARConfiguration.FrameSemantics = []
    private var viewSize: CGSize = .zero
    private var pendingTap: CGPoint?
    private var targetKind: TargetKind = .person
    private var targetRect: CGRect?
    private var faceRect: CGRect?
    private var humans: [CGRect] = []
    private var faces: [CGRect] = []
    private var active = false
    private var missed = 0
    private var frameCount = 0
    private var filter = OneEuroFilter(minCutoff: 0.8, beta: 0.6)
    private var filtered: Float?

    // MARK: - Indítás

    func start() {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else { return }
        var sem: ARConfiguration.FrameSemantics = [.sceneDepth]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) { sem.insert(.smoothedSceneDepth) }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) { sem.insert(.personSegmentationWithDepth) }
        session.delegate = self
        session.delegateQueue = queue
        queue.async {
            self.semantics = sem
            self.runConfig()
        }
    }

    private func runConfig() {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = semantics
        session.run(config)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // Ha a személyszegmentálás a mélységgel együtt nem fut, nélküle indítjuk újra
        if semantics.contains(.personSegmentationWithDepth) {
            semantics.remove(.personSegmentationWithDepth)
            runConfig()
        }
    }

    // MARK: - Vezérlés

    func tap(at point: CGPoint, viewSize size: CGSize) {
        let norm = CGPoint(x: point.x / size.width, y: point.y / size.height)
        queue.async {
            self.viewSize = size
            self.pendingTap = norm
        }
    }

    func clear() {
        queue.async {
            self.active = false
            self.trackRequest = nil
            self.targetRect = nil
            self.faceRect = nil
            self.filter.reset()
            self.filtered = nil
            DispatchQueue.main.async {
                self.targetView = nil
                self.faceView = nil
                self.distance = nil
                self.state = .idle
            }
        }
    }

    // MARK: - Képkockánként (a saját sorunkon)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard viewSize != .zero else { return }
        frameCount += 1
        let toView = frame.displayTransform(for: .portrait, viewportSize: viewSize)
        let runDetect = frameCount % 2 == 0 || pendingTap != nil

        // 1) Ember- és arckeresés (30 Hz)
        if runDetect {
            let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .right)
            try? handler.perform([humanRequest, faceRequest])
            humans = (humanRequest.results ?? []).filter { $0.confidence > 0.4 }.map { rawRect(fromVision: $0.boundingBox) }
            faces = (faceRequest.results ?? []).map { rawRect(fromVision: $0.boundingBox) }
        }

        // 2) Új kijelölés
        if let tap = pendingTap {
            pendingTap = nil
            select(at: tap.applying(toView.inverted()))
        }

        // 3) Célpont frissítése
        if active, let last = targetRect, runDetect {
            switch targetKind {
            case .person:
                if let match = bestMatch(for: last, in: humans) {
                    targetRect = lerp(last, match, 0.6)
                    missed = 0
                    faceRect = faces
                        .filter { match.contains(CGPoint(x: $0.midX, y: $0.midY)) }
                        .max { area($0) < area($1) }
                } else {
                    missed += 1
                    faceRect = nil
                }
            case .object:
                if let req = trackRequest {
                    var ok = false
                    if (try? sequenceHandler.perform([req], on: frame.capturedImage, orientation: .right)) != nil,
                       let obs = req.results?.first as? VNDetectedObjectObservation, obs.confidence > 0.3 {
                        req.inputObservation = obs
                        targetRect = rawRect(fromVision: obs.boundingBox)
                        ok = true
                    }
                    missed = ok ? 0 : missed + 1
                }
            }
        }

        // 4) Távolság (60 Hz) – csak ha a célpont látszik
        if active, missed == 0, let r = targetRect {
            var d: Float?
            if targetKind == .person {
                if let f = faceRect {
                    d = sampleDepth(f, shrink: 0.4, useMask: false, percentile: 0.5, frame: frame)
                }
                if d == nil { d = sampleDepth(r, shrink: 0.15, useMask: true, percentile: 0.5, frame: frame) }
                if d == nil { d = sampleDepth(r, shrink: 0.5, useMask: false, percentile: 0.3, frame: frame) }
            } else {
                d = sampleDepth(r, shrink: 0.5, useMask: false, percentile: 0.3, frame: frame)
            }
            if let d {
                filtered = Float(filter.filter(Double(d), time: frame.timestamp))
            }
        }

        // 5) Közzététel a felületnek
        let tView = active ? targetRect?.applying(toView) : nil
        let fView = active ? faceRect?.applying(toView) : nil
        let pView = humans.map { $0.applying(toView) }
        let st: TrackState = !active ? .idle : (missed > 6 ? .searching : .tracking)
        let k = targetKind
        let dist = active ? filtered : nil
        DispatchQueue.main.async {
            self.targetView = tView
            self.faceView = fView
            self.peopleView = pView
            self.state = st
            self.kind = k
            self.distance = dist
        }
    }

    private func select(at p: CGPoint) {
        if let h = humans.filter({ $0.contains(p) }).min(by: { area($0) < area($1) }) {
            targetKind = .person
            targetRect = h
            trackRequest = nil
        } else {
            targetKind = .object
            let half: CGFloat = 0.07
            let r = CGRect(x: p.x - half, y: p.y - half, width: half * 2, height: half * 2)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let req = VNTrackObjectRequest(detectedObjectObservation:
                VNDetectedObjectObservation(boundingBox: visionRect(fromRaw: r)))
            req.trackingLevel = .accurate
            trackRequest = req
            targetRect = r
        }
        faceRect = nil
        active = true
        missed = 0
        filter.reset()
        filtered = nil
    }

    /// Az előző helyhez legjobban illő ember: először átfedés, ha nincs, a legközelebbi.
    private func bestMatch(for last: CGRect, in cands: [CGRect]) -> CGRect? {
        guard !cands.isEmpty else { return nil }
        if let best = cands.max(by: { iou($0, last) < iou($1, last) }), iou(best, last) > 0.25 {
            return best
        }
        let lc = CGPoint(x: last.midX, y: last.midY)
        let maxDist: CGFloat = missed > 0 ? 0.35 : 0.15
        guard let near = cands.min(by: { dist($0, lc) < dist($1, lc) }) else { return nil }
        return dist(near, lc) < maxDist ? near : nil
    }

    // MARK: - LiDAR mélység mintavétel

    /// A téglalap (szűkítve) mélységpontjaiból a megadott percentilis.
    /// useMask: csak az ARKit által emberként jelölt pixelek számítanak.
    private func sampleDepth(_ r: CGRect, shrink: CGFloat, useMask: Bool, percentile: Float, frame: ARFrame) -> Float? {
        guard let sd = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let dm = sd.depthMap
        let cm = sd.confidenceMap
        let seg = useMask ? frame.segmentationBuffer : nil
        if useMask && seg == nil { return nil }

        let bufs = [dm, cm, seg].compactMap { $0 }
        bufs.forEach { CVPixelBufferLockBaseAddress($0, .readOnly) }
        defer { bufs.forEach { CVPixelBufferUnlockBaseAddress($0, .readOnly) } }

        guard let dBase = CVPixelBufferGetBaseAddress(dm) else { return nil }
        let w = CVPixelBufferGetWidth(dm), h = CVPixelBufferGetHeight(dm)
        let dRow = CVPixelBufferGetBytesPerRow(dm)
        let cBase = cm.flatMap { CVPixelBufferGetBaseAddress($0) }
        let cRow = cm.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let sBase = seg.flatMap { CVPixelBufferGetBaseAddress($0) }
        let sW = seg.map { CVPixelBufferGetWidth($0) } ?? 1
        let sH = seg.map { CVPixelBufferGetHeight($0) } ?? 1
        let sRow = seg.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        let rr = r.insetBy(dx: r.width * shrink / 2, dy: r.height * shrink / 2)
        let x0 = max(0, Int(rr.minX * CGFloat(w))), x1 = min(w - 1, Int(rr.maxX * CGFloat(w)))
        let y0 = max(0, Int(rr.minY * CGFloat(h))), y1 = min(h - 1, Int(rr.maxY * CGFloat(h)))
        guard x0 <= x1, y0 <= y1 else { return nil }

        var vals: [Float] = []
        vals.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for y in y0...y1 {
            let drow = (dBase + y * dRow).assumingMemoryBound(to: Float32.self)
            let crow = cBase.map { ($0 + y * cRow).assumingMemoryBound(to: UInt8.self) }
            let srow = sBase.map { ($0 + min(sH - 1, y * sH / h) * sRow).assumingMemoryBound(to: UInt8.self) }
            for x in x0...x1 {
                let v = drow[x]
                guard v > 0, v.isFinite else { continue }
                if let crow, crow[x] < 1 { continue }
                if let srow, srow[min(sW - 1, x * sW / w)] < 128 { continue }
                vals.append(v)
            }
        }
        guard vals.count >= 4 else { return nil }
        vals.sort()
        return vals[min(vals.count - 1, Int(Float(vals.count) * percentile))]
    }
}

// MARK: - Geometria segédfüggvények

/// Vision (álló kép, .right orientáció, bal alsó origó) <-> nyers kamerakép (bal felső origó).
/// A leképezés önmaga inverze, így mindkét irányba ugyanaz.
private func rawRect(fromVision r: CGRect) -> CGRect {
    CGRect(x: 1 - r.maxY, y: 1 - r.maxX, width: r.height, height: r.width)
}

private func visionRect(fromRaw r: CGRect) -> CGRect {
    CGRect(x: 1 - r.maxY, y: 1 - r.maxX, width: r.height, height: r.width)
}

private func area(_ r: CGRect) -> CGFloat { r.width * r.height }

private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    if i.isNull { return 0 }
    let u = area(a) + area(b) - area(i)
    return u > 0 ? area(i) / u : 0
}

private func dist(_ r: CGRect, _ p: CGPoint) -> CGFloat {
    hypot(r.midX - p.x, r.midY - p.y)
}

private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: a.minX + (b.minX - a.minX) * t,
           y: a.minY + (b.minY - a.minY) * t,
           width: a.width + (b.width - a.width) * t,
           height: a.height + (b.height - a.height) * t)
}
