import SwiftUI
import ARKit
import SceneKit

@main
struct LiDARFocusApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView().preferredColorScheme(.dark)
        }
    }
}

extension Color {
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.22)
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
    @StateObject private var store = ProfileStore()

    @State private var autoMode = false
    @State private var manualUs: Double = 1500
    @State private var outputUs: Int = 1500
    @State private var showProfiles = false

    var body: some View {
        ZStack {
            GeometryReader { geo in
                ZStack {
                    ARCameraView(session: engine.session)
                    TargetOverlay(engine: engine, size: geo.size)
                }
                .contentShape(Rectangle())
                .onTapGesture { p in
                    engine.tap(at: p, viewSize: geo.size)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                DistanceReadout(engine: engine)
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .onAppear {
            engine.start()
            clampManual()
        }
        .onReceive(engine.$distance) { d in
            guard autoMode, let d, let us = store.active.us(for: d) else { return }
            outputUs = us
            ble.send(us: us)
        }
        .onChange(of: manualUs) { _, v in
            guard !autoMode else { return }
            outputUs = Int(v)
            ble.send(us: Int(v))
        }
        .onChange(of: autoMode) { _, auto in
            if !auto {
                outputUs = Int(manualUs)
                ble.send(us: Int(manualUs), force: true)
            }
        }
        .onChange(of: store.activeID) { _, _ in
            if !store.active.isCalibrated { autoMode = false }
            clampManual()
        }
        .sheet(isPresented: $showProfiles) {
            ProfilesSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
    }

    private func clampManual() {
        let p = store.active
        manualUs = min(max(manualUs, Double(p.minUs)), Double(p.maxUs))
    }

    private func savePoint() {
        guard let d = engine.distance else { return }
        store.updateActive { $0.points.append(CalPoint(distance: d, us: Int(manualUs))) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Felső sáv

    private var topBar: some View {
        HStack(spacing: 8) {
            Pill(icon: ble.connected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
                 text: ble.connected ? "ESP32" : "Keresés…",
                 color: ble.connected ? .green : .orange)
            Spacer(minLength: 4)
            Button { showProfiles = true } label: {
                Pill(icon: "camera.aperture", text: store.active.name, color: .amber, chevron: true)
            }
            Spacer(minLength: 4)
            Button { engine.clear() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.white)
            .opacity(engine.state == .idle ? 0.35 : 1)
            .disabled(engine.state == .idle)
        }
    }

    // MARK: - Alsó panel

    private var bottomPanel: some View {
        let p = store.active
        return VStack(spacing: 14) {
            FocusBar(minUs: p.minUs, maxUs: p.maxUs, current: outputUs, marks: p.points.map(\.us))

            ModeSwitch(autoMode: $autoMode, autoEnabled: p.isCalibrated)

            if autoMode {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(engine.state == .idle ? "Bökj a célpontra a képen" : "Az élesség követi a célpontot")
                    Spacer()
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    Slider(value: $manualUs, in: Double(p.minUs)...Double(p.maxUs), step: 1)
                        .tint(.amber)
                    Image(systemName: "circle.circle").foregroundStyle(.secondary)
                }
                HStack {
                    Button(action: savePoint) {
                        Label(engine.distance.map { String(format: "Rögzítés  %.2f m", $0) } ?? "Jelölj ki célpontot",
                              systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.amber)
                    .foregroundStyle(.black)
                    .disabled(engine.distance == nil)

                    Text(p.isCalibrated ? "\(p.points.count) pont" : "\(p.points.count)/2 pont")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(p.isCalibrated ? Color.secondary : Color.orange)
                        .frame(width: 64)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.08)))
    }
}

// MARK: - Komponensek

struct Pill: View {
    let icon: String
    let text: String
    let color: Color
    var chevron = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct DistanceReadout: View {
    @ObservedObject var engine: FocusEngine

    var body: some View {
        VStack(spacing: 0) {
            (Text(engine.distance.map { String(format: "%.2f", $0) } ?? "–.––")
                .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
             + Text(" m")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.6)))
            HStack(spacing: 6) {
                Circle().fill(stateColor).frame(width: 7, height: 7)
                Text(subtitle)
            }
            .font(.caption.weight(.bold))
            .kerning(1.2)
            .foregroundStyle(stateColor)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 8)
        .animation(.easeOut(duration: 0.2), value: engine.state)
    }

    private var subtitle: String {
        switch engine.state {
        case .idle: return "BÖKJ A CÉLPONTRA"
        case .searching: return "CÉLPONT KERESÉSE…"
        case .tracking:
            if engine.kind == .object { return "TÁRGY · LIDAR" }
            return engine.faceView != nil ? "ARC · LIDAR" : "EMBER · LIDAR"
        }
    }

    private var stateColor: Color {
        switch engine.state {
        case .idle: return .white.opacity(0.7)
        case .searching: return .red
        case .tracking: return engine.kind == .person ? .green : .amber
        }
    }
}

/// Sarokjelölő keret, mint egy kamera fókuszmezője.
struct CornerBrackets: Shape {
    var length: CGFloat = 20

    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = min(length, r.width / 3, r.height / 3)
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}

struct TargetOverlay: View {
    @ObservedObject var engine: FocusEngine
    let size: CGSize

    var body: some View {
        ZStack {
            // Felismert emberek (amíg nincs kijelölés): koppintható jelöltek
            if engine.state == .idle {
                ForEach(Array(engine.peopleView.enumerated()), id: \.offset) { _, r in
                    let b = px(r)
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                        .frame(width: b.width, height: b.height)
                        .position(x: b.midX, y: b.midY)
                }
            }

            if let t = engine.targetView {
                let b = px(t)
                CornerBrackets()
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: b.width, height: b.height)
                    .position(x: b.midX, y: b.midY)
                    .shadow(color: color.opacity(0.7), radius: 6)

                if let f = engine.faceView {
                    let fb = px(f)
                    let s = max(fb.width, fb.height)
                    Circle()
                        .stroke(color.opacity(0.9), lineWidth: 2)
                        .frame(width: s, height: s)
                        .position(x: fb.midX, y: fb.midY)
                }

                Text(tag)
                    .font(.caption2.weight(.heavy))
                    .kerning(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(color, in: Capsule())
                    .position(x: b.midX, y: max(14, b.minY - 14))
            }
        }
        .animation(.easeOut(duration: 0.12), value: engine.targetView)
        .allowsHitTesting(false)
    }

    private func px(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * size.width, y: r.minY * size.height,
               width: r.width * size.width, height: r.height * size.height)
    }

    private var color: Color {
        switch engine.state {
        case .searching: return .red
        default: return engine.kind == .person ? .green : .amber
        }
    }

    private var tag: String {
        let d = engine.distance.map { String(format: " %.2f m", $0) } ?? ""
        switch engine.state {
        case .searching: return "KERESÉS"
        default: return (engine.kind == .person ? (engine.faceView != nil ? "ARC" : "EMBER") : "TÁRGY") + d
        }
    }
}

/// Fókuszsáv: a szervó helyzete a profil tartományában, kalibrációs jelekkel.
struct FocusBar: View {
    let minUs: Int
    let maxUs: Int
    let current: Int
    let marks: [Int]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("FÓKUSZ").font(.caption2.weight(.heavy)).kerning(1.5).foregroundStyle(.secondary)
                Spacer()
                Text("\(current) µs").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                let w = g.size.width
                let pos = frac(current) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14)).frame(height: 6)
                    Capsule()
                        .fill(LinearGradient(colors: [Color.amber.opacity(0.5), .amber], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, pos), height: 6)
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                        Capsule().fill(Color.white.opacity(0.85)).frame(width: 2, height: 12)
                            .offset(x: frac(m) * w - 1)
                    }
                    Circle().fill(Color.white).frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .offset(x: pos - 8)
                }
                .frame(height: 16)
                .animation(.easeOut(duration: 0.1), value: current)
            }
            .frame(height: 16)
        }
    }

    private func frac(_ us: Int) -> CGFloat {
        guard maxUs > minUs else { return 0 }
        return CGFloat(min(max(us, minUs), maxUs) - minUs) / CGFloat(maxUs - minUs)
    }
}

struct ModeSwitch: View {
    @Binding var autoMode: Bool
    let autoEnabled: Bool
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            segment("Kézi", icon: "hand.point.up.left.fill", value: false)
            segment("Automata", icon: "scope", value: true)
        }
        .padding(4)
        .background(Color.white.opacity(0.08), in: Capsule())
    }

    private func segment(_ title: String, icon: String, value: Bool) -> some View {
        let selected = autoMode == value
        let disabled = value && !autoEnabled
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { autoMode = value }
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .foregroundStyle(selected ? Color.black : Color.white)
                .background {
                    if selected {
                        Capsule().fill(Color.amber).matchedGeometryEffect(id: "seg", in: ns)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

// MARK: - Lencseprofilok

struct ProfilesSheet: View {
    @ObservedObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var showNew = false
    @State private var renameText = ""
    @State private var showRename = false

    var body: some View {
        NavigationStack {
            List {
                Section("Lencseprofilok") {
                    ForEach(store.profiles) { p in
                        Button { store.activeID = p.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "camera.aperture")
                                    .font(.title3)
                                    .foregroundStyle(Color.amber)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).foregroundStyle(.primary)
                                    Text(p.isCalibrated ? "\(p.points.count) kalibrációs pont" : "Nincs kalibrálva")
                                        .font(.caption)
                                        .foregroundStyle(p.isCalibrated ? Color.secondary : Color.orange)
                                }
                                Spacer()
                                if p.id == store.activeID {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.amber)
                                }
                            }
                        }
                    }
                    .onDelete { idx in
                        let ids = idx.map { store.profiles[$0].id }
                        ids.forEach { store.delete($0) }
                    }
                    Button { newName = ""; showNew = true } label: {
                        Label("Új profil", systemImage: "plus")
                    }
                }

                Section("Aktív: \(store.active.name)") {
                    Stepper("Szervó min: \(store.active.minUs) µs", value: minBinding,
                            in: 500...(store.active.maxUs - 50), step: 10)
                    Stepper("Szervó max: \(store.active.maxUs) µs", value: maxBinding,
                            in: (store.active.minUs + 50)...2500, step: 10)
                    Button("Átnevezés") { renameText = store.active.name; showRename = true }
                }

                Section("Kalibrációs pontok") {
                    if store.active.points.isEmpty {
                        Text("Kézi módban állítsd élesre a célpontot, majd nyomd meg a Rögzítés gombot. Legalább 2 pont kell, a közelitől a távoliig.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sortedPoints) { pt in
                        HStack {
                            Text(String(format: "%.2f m", pt.distance)).monospacedDigit()
                            Spacer()
                            Text("\(pt.us) µs").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in
                        let ids = Set(idx.map { sortedPoints[$0].id })
                        store.updateActive { $0.points.removeAll { ids.contains($0.id) } }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Objektívek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Kész") { dismiss() } }
            }
            .alert("Új lencseprofil", isPresented: $showNew) {
                TextField("pl. Sigma 18-35 f/1.8", text: $newName)
                Button("Mégse", role: .cancel) {}
                Button("Létrehozás") {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    store.add(name: n.isEmpty ? "Új objektív" : n)
                }
            }
            .alert("Átnevezés", isPresented: $showRename) {
                TextField("Név", text: $renameText)
                Button("Mégse", role: .cancel) {}
                Button("Mentés") {
                    let n = renameText.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { store.updateActive { $0.name = n } }
                }
            }
        }
    }

    private var sortedPoints: [CalPoint] {
        store.active.points.sorted { $0.distance < $1.distance }
    }

    private var minBinding: Binding<Int> {
        Binding(get: { store.active.minUs }, set: { v in store.updateActive { $0.minUs = v } })
    }

    private var maxBinding: Binding<Int> {
        Binding(get: { store.active.maxUs }, set: { v in store.updateActive { $0.maxUs = v } })
    }
}
