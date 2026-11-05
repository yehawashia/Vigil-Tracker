import AppKit
import SceneKit
import SwiftUI
import VigilCore

/// 3D "time terrain": 24 hours × 28 days, three stacked dot layers (productive, neutral, distracting).
/// Each layer is one point-cloud geometry plus one wireframe grid: 6 draw calls in total, rendered
/// only when you interact (no continuous rendering), so it costs nothing while you just look at it.
struct TerrainCard: View {
    var t: TrendsData
    @State private var layers: Set<ActivityCategory> = Set(ActivityCategory.allCases)
    @State private var spin = false
    @State private var resetToken = 0
    @State private var hover: (day: String, hour: Int)?

    var body: some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(number: "03", title: "Time terrain", note: "drag to orbit · scroll to zoom")
                    Text("last 4 weeks · hours across, days deep · height = minutes · one layer per category")
                        .font(Theme.label(10)).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 18) {
                ZStack(alignment: .topLeading) {
                    TerrainScene(terrain: t.terrain, layers: layers, spin: spin, resetToken: resetToken)
                        .frame(height: 380)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array([ActivityCategory.productive, .neutral, .distracting].enumerated()), id: \.offset) { i, c in
                            HStack(spacing: 8) {
                                BracketRail(label: String(format: "%02d", 3 - i)).frame(height: 70)
                                Button { toggle(c) } label: {
                                    HStack(spacing: 6) {
                                        Circle().fill(layers.contains(c) ? c.color : Color.clear)
                                            .overlay(Circle().strokeBorder(c.color, lineWidth: 1)).frame(width: 8, height: 8)
                                        Text(c.label.uppercased()).font(Theme.label(9.5))
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(layers.contains(c) ? Theme.ink : .secondary)
                            }
                            .padding(.vertical, 22)
                        }
                    }
                    .padding(.top, 20)
                }
                .crosshairs()
                VStack(alignment: .leading, spacing: 10) {
                    Text("HOUR × DAY").font(Theme.label(9.5)).foregroundStyle(.secondary)
                    HourHeatmap(terrain: t.terrain, hover: $hover).frame(width: 300, height: 240)
                    readout
                    Spacer(minLength: 0)
                    HStack {
                        Toggle("Slow spin", isOn: $spin).toggleStyle(.checkbox).font(.caption)
                        Spacer()
                        Button("Reset view") { resetToken += 1 }.controlSize(.small)
                    }
                }
                .frame(width: 300)
            }
        }
    }

    private func toggle(_ c: ActivityCategory) {
        if layers.contains(c) { if layers.count > 1 { layers.remove(c) } } else { layers.insert(c) }
    }

    @ViewBuilder
    private var readout: some View {
        if let h = hover, let d = t.terrain.first(where: { $0.day == h.day }), h.hour < d.hours.count {
            let b = d.hours[h.hour]
            VStack(alignment: .leading, spacing: 3) {
                Text("\(shortDate(h.day)) · \(String(format: "%02d:00", h.hour))").font(Theme.label(10))
                ForEach(ActivityCategory.allCases) { c in
                    let v = c == .productive ? b.productive : c == .neutral ? b.neutral : b.distracting
                    HStack(spacing: 6) {
                        Circle().fill(c.color).frame(width: 6, height: 6)
                        Text(c.label.uppercased()).font(Theme.label(9)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((v / 60).rounded()))m").font(Theme.label(10))
                    }
                }
            }
            .padding(8)
            .overlay(Rectangle().strokeBorder(Theme.hairline))
        } else {
            Text("Hover the grid for exact minutes.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func shortDate(_ day: String) -> String {
        guard let d = DayKey.date(from: day) else { return day }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"
        return f.string(from: d).uppercased()
    }
}

/// Day rows × hour columns; cell darkness = active minutes. Hover reports the cell.
struct HourHeatmap: View {
    var terrain: [DayHours]
    @Binding var hover: (day: String, hour: Int)?

    var body: some View {
        GeometryReader { geo in
            let rows = max(1, terrain.count)
            let cw = geo.size.width / 24, ch = geo.size.height / CGFloat(rows)
            let peak = max(60, terrain.flatMap(\.hours).map { $0.productive + $0.neutral + $0.distracting }.max() ?? 60)
            Canvas { ctx, _ in
                for (r, d) in terrain.enumerated() {
                    for b in d.hours {
                        let total = b.productive + b.neutral + b.distracting
                        let rect = CGRect(x: CGFloat(b.hour) * cw + 0.5, y: CGFloat(r) * ch + 0.5, width: cw - 1, height: ch - 1)
                        if total <= 0 {
                            ctx.fill(Path(ellipseIn: rect.insetBy(dx: cw * 0.42, dy: ch * 0.42)), with: .color(Theme.hairline))
                            continue
                        }
                        let dominant: ActivityCategory = b.distracting > b.productive ? .distracting : (b.productive >= b.neutral ? .productive : .neutral)
                        ctx.fill(Path(rect), with: .color(dominant.color.opacity(0.15 + 0.85 * min(1, total / peak))))
                    }
                }
                if let h = hover, let r = terrain.firstIndex(where: { $0.day == h.day }) {
                    let rect = CGRect(x: CGFloat(h.hour) * cw, y: CGFloat(r) * ch, width: cw, height: ch)
                    ctx.stroke(Path(rect), with: .color(Theme.ink), lineWidth: 1.2)
                    var cross = Path()
                    cross.move(to: CGPoint(x: rect.midX, y: 0)); cross.addLine(to: CGPoint(x: rect.midX, y: geo.size.height))
                    cross.move(to: CGPoint(x: 0, y: rect.midY)); cross.addLine(to: CGPoint(x: geo.size.width, y: rect.midY))
                    ctx.stroke(cross, with: .color(Theme.ink.opacity(0.25)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let hour = max(0, min(23, Int(p.x / cw)))
                    let row = max(0, min(rows - 1, Int(p.y / ch)))
                    if row < terrain.count { hover = (terrain[row].day, hour) }
                case .ended: hover = nil
                }
            }
        }
    }
}

/// SceneKit host. Rebuilds geometry only when data, visible layers or the colour scheme change.
private struct TerrainScene: NSViewRepresentable {
    var terrain: [DayHours]
    var layers: Set<ActivityCategory>
    var spin: Bool
    var resetToken: Int
    @Environment(\.colorScheme) private var scheme

    final class Coordinator {
        var signature = ""
        var resetToken = 0
        let root = SCNNode()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.rendersContinuously = false
        let scene = SCNScene()
        scene.rootNode.addChildNode(context.coordinator.root)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 12.5
        camera.name = "camera"
        scene.rootNode.addChildNode(camera)
        view.scene = scene
        view.pointOfView = camera
        resetCamera(view)
        return view
    }

    private func resetCamera(_ view: SCNView) {
        guard let cam = view.scene?.rootNode.childNode(withName: "camera", recursively: false) else { return }
        cam.position = SCNVector3(26, 24, 30)
        cam.look(at: SCNVector3(0, 5, 0))
        view.pointOfView = cam
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        if c.resetToken != resetToken { c.resetToken = resetToken; resetCamera(view) }
        let sig = "\(terrain.map(\.day).joined())|\(terrain.count)|\(layers.map(\.rawValue).sorted())|\(scheme)|\(terrain.last?.hours.map { $0.productive + $0.neutral + $0.distracting } ?? [])"
        if sig != c.signature {
            c.signature = sig
            c.root.childNodes.forEach { $0.removeFromParentNode() }
            build(into: c.root, appearance: NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        }
        c.root.removeAction(forKey: "spin")
        if spin {
            c.root.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 60)), forKey: "spin")
            view.rendersContinuously = true
        } else {
            view.rendersContinuously = false
        }
    }

    private func color(_ c: Color, _ appearance: NSAppearance?) -> NSColor {
        var out = NSColor.white
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            out = NSColor(c).usingColorSpace(.sRGB) ?? .white
        }
        return out
    }

    private func build(into root: SCNNode, appearance: NSAppearance?) {
        let days = terrain.count
        guard days > 0 else { return }
        let layerOrder: [ActivityCategory] = [.distracting, .neutral, .productive]  // bottom to top
        let spacing: Float = 4.2
        let peak = max(1, terrain.flatMap(\.hours).map { max($0.productive, $0.neutral, $0.distracting) }.max() ?? 1)
        let ink = color(Theme.ink, appearance)

        for (li, cat) in layerOrder.enumerated() where layers.contains(cat) {
            let base = Float(li) * spacing
            let tint = color(cat.color, appearance)
            var vertices: [SCNVector3] = []
            var colors: [Float] = []
            for (d, day) in terrain.enumerated() {
                for b in day.hours where b.hour < 24 {
                    let v = cat == .productive ? b.productive : cat == .neutral ? b.neutral : b.distracting
                    let h = Float(v / peak)
                    vertices.append(SCNVector3(Float(b.hour) - 11.5, base + h * 3.6, Float(d) - Float(days) / 2))
                    // Empty cells are faint dust; busy cells are bright and full colour.
                    let a = v > 0 ? 0.55 + 0.45 * Float(min(1, v / peak * 1.4)) : 0.18
                    let src = v > 0 ? tint : ink
                    colors += [Float(src.redComponent), Float(src.greenComponent), Float(src.blueComponent), a]
                }
            }
            let vSource = SCNGeometrySource(vertices: vertices)
            let cData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
            let cSource = SCNGeometrySource(data: cData, semantic: .color, vectorCount: vertices.count, usesFloatComponents: true,
                                            componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
            let indices = (0..<Int32(vertices.count)).map { $0 }
            let element = SCNGeometryElement(indices: indices, primitiveType: .point)
            element.pointSize = 5
            element.minimumPointScreenSpaceRadius = 2
            element.maximumPointScreenSpaceRadius = 7
            let geo = SCNGeometry(sources: [vSource, cSource], elements: [element])
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            geo.materials = [m]
            root.addChildNode(SCNNode(geometry: geo))

            // Wireframe floor for the layer (every 3 hours, every 7 days), like a technical drawing.
            var lines: [SCNVector3] = []
            let z0 = -Float(days) / 2, z1 = Float(days - 1) - Float(days) / 2
            for hour in stride(from: 0, through: 24, by: 3) {
                let x = Float(hour) - 12
                lines += [SCNVector3(x, base - 0.05, z0 - 0.5), SCNVector3(x, base - 0.05, z1 + 0.5)]
            }
            for d in stride(from: 0, through: days, by: 7) {
                let z = Float(d) - Float(days) / 2 - 0.5
                lines += [SCNVector3(-12, base - 0.05, z), SCNVector3(12, base - 0.05, z)]
            }
            let lineGeo = SCNGeometry(sources: [SCNGeometrySource(vertices: lines)],
                                      elements: [SCNGeometryElement(indices: (0..<Int32(lines.count)).map { $0 }, primitiveType: .line)])
            let lm = SCNMaterial()
            lm.lightingModel = .constant
            lm.diffuse.contents = ink.withAlphaComponent(0.16)
            lineGeo.materials = [lm]
            root.addChildNode(SCNNode(geometry: lineGeo))
        }
    }
}
