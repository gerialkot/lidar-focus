import SwiftUI
import ARKit
import SceneKit

@main
struct LiDARFocusApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Élő kamerakép az ARKit sessionből.
struct ARCameraView: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.session = session
        v.automaticallyUpdatesLighting = false
        return v
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var engine = FocusEngine()
    @StateObject private var ble = BLELink()
    @StateObject private var cal = Calibration()

    @State private var manualMode = true
    @State private var manualUs: Double = 1500
    @State private var currentUs: Int?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ARCameraView(session: engine.session)
                if let b = engine.boxView {
                    Rectangle()
                        .stroke(Color.yellow, lineWidth: 3)
                        .frame(width: b.width * geo.size.width, height: b.height * geo.size.height)
                        .position(x: b.midX * geo.size.width, y: b.midY * geo.size.height)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { p in engine.tap(at: p, viewSize: geo.size) }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) { infoPanel }
        .overlay(alignment: .bottom) { controlPanel }
        .onAppear { engine.start() }
        .onReceive(engine.$distance) { d in
            guard !manualMode, let d, let us = cal.us(for: d) else { return }
            currentUs = us
            ble.send(us: us)
        }
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ble.state).foregroundColor(ble.connected ? .green : .orange)
            Text(engine.status)
            Text(engine.distance.map { String(format: "Távolság: %.2f m", $0) } ?? "Távolság: –")
                .font(.title2.monospacedDigit())
            Text("Szervó: \(manualMode ? Int(manualUs) : (currentUs ?? 0)) µs")
                .font(.body.monospacedDigit())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.55))
        .foregroundColor(.white)
    }

    private var controlPanel: some View {
        VStack(spacing: 10) {
            Picker("Mód", selection: $manualMode) {
                Text("Kézi / kalibrálás").tag(true)
                Text("Automata élesség").tag(false)
            }
            .pickerStyle(.segmented)

            if manualMode {
                Slider(value: $manualUs, in: 600...2400, step: 1)
                    .onChange(of: manualUs) { _, v in ble.send(us: Int(v)) }
                HStack {
                    Button("Pont mentése") {
                        if let d = engine.distance {
                            cal.points.append(CalPoint(distance: d, us: Int(manualUs)))
                        }
                    }
                    .disabled(engine.distance == nil)
                    Spacer()
                    Text("Pontok: \(cal.points.count)")
                    Spacer()
                    Button("Pontok törlése", role: .destructive) { cal.points.removeAll() }
                }
                ForEach(cal.points.sorted { $0.distance < $1.distance }) { p in
                    Text(String(format: "%.2f m → %d µs", p.distance, p.us))
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if cal.points.count < 2 {
                Text("Legalább 2 kalibrációs pont kell").foregroundColor(.orange)
            }

            Button("Kijelölés törlése") { engine.clear() }
        }
        .padding(12)
        .background(.black.opacity(0.55))
        .foregroundColor(.white)
        .onChange(of: manualMode) { _, manual in
            if manual { ble.send(us: Int(manualUs), force: true) }
        }
    }
}
