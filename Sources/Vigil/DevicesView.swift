import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import VigilCore
import VigilSync

/// Pair iPhones and iPads with this Mac, see what they report, and revoke them.
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var mode: PairingMode = .qr
    @State private var confirmRevoke: PairedDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Color.clear.frame(height: 0)
                .pageHeader("Devices", subtitle: "This Mac is the host. Pair your iPhone and iPad to sync over your local network.")

            Card {
                SectionHeader(number: "01", title: "Pair a device", note: "local network only")
                pairingBody
            }
            .crosshairs()

            Card {
                SectionHeader(number: "02", title: "Paired devices", note: "\(model.devices.count) paired with \(model.hostName)")
                if model.devices.isEmpty {
                    Text("No devices yet. Pair one above. Each device gets its own key, so you can remove any of them on its own.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.devices) { d in deviceRow(d) }
            }
            .crosshairs()

            Card {
                SectionHeader(number: "03", title: "How it's protected")
                VStack(alignment: .leading, spacing: 6) {
                    bullet("Only your local network. Vigil has no internet code; cellular is never used, and other addresses are refused.")
                    bullet("Every device gets its own 256-bit key. All sync traffic is encrypted with it (TLS).")
                    bullet("QR codes work once and expire after 2 minutes. PIN pairing shows a code on both screens, so nobody can sit in the middle.")
                    bullet("Remove a device and its key is deleted: it can't connect again, and the data it sent is erased.")
                }
            }
        }
        .onAppear { model.reloadDevices() }
        .confirmationDialog("Remove \(confirmRevoke?.name ?? "device")?", isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } })) {
            Button("Remove", role: .destructive) { if let d = confirmRevoke { model.revokeDevice(d) }; confirmRevoke = nil }
        } message: {
            Text("Its key is deleted and the data it sent is erased. You can pair it again later.")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("→").font(Theme.label(10)).foregroundStyle(Theme.accent)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pairing

    @ViewBuilder
    private var pairingBody: some View {
        switch model.pairing {
        case .open(let m, let url, let expires)?:
            HStack(alignment: .center, spacing: 32) {
                if m == .qr, let url {
                    PairingCode(url: url).frame(width: 240, height: 240)
                } else {
                    DotRing(size: 200).frame(width: 240, height: 240)
                        .overlay(Image(systemName: "number").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(m == .qr ? "Scan with your iPhone or iPad" : "Waiting for your device…").font(.title3.weight(.semibold))
                    Text(m == .qr
                         ? "Open Vigil on the device, tap Pair with Mac, and point the camera at this code."
                         : "Open Vigil on the device and tap Pair with PIN. You'll both see the same 6-digit code.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("EXPIRES IN \(DurationText.clock(max(0, expires.timeIntervalSince(ctx.date))))")
                            .font(Theme.label(10)).foregroundStyle(.secondary)
                    }
                    Button("Cancel") { model.closePairing() }
                }
                Spacer()
            }
        case .confirm(let code, let name)?:
            HStack(spacing: 32) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(name.uppercased()) SHOWS").font(Theme.label(10)).foregroundStyle(.secondary)
                    Text(code.prefix(3) + " " + code.suffix(3))
                        .font(.system(size: 54, weight: .light, design: .monospaced)).tracking(4)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Does your device show the same code?").font(.title3.weight(.semibold))
                    Text("If it doesn't, something else is trying to pair. Choose Doesn't match.").foregroundStyle(.secondary)
                    HStack {
                        Button("Doesn't match") { model.confirmPairing(false) }
                        Button("Codes match") { model.confirmPairing(true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                }
            }
        case .paired(let d)?:
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(Theme.accent)
                Text("\(d.name) is paired with this Mac.").font(.title3.weight(.semibold))
                Spacer()
                Button("Pair another") { model.pairing = nil }
            }
        default:
            HStack(alignment: .center, spacing: 16) {
                Picker("", selection: $mode) {
                    Text("QR code").tag(PairingMode.qr)
                    Text("PIN").tag(PairingMode.pin)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                Button { model.openPairing(mode) } label: { Label("Start pairing", systemImage: "qrcode") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                if case .failed(let why)? = model.pairing {
                    Text(why).font(.callout).foregroundStyle(Theme.distracting)
                }
                Spacer()
            }
            if model.host == nil {
                Text("Device sync couldn't start on this Mac. Restart Vigil and try again.").font(.caption).foregroundStyle(Theme.distracting)
            }
        }
    }

    // MARK: Device rows

    private func deviceRow(_ d: PairedDevice) -> some View {
        let online = model.onlineDevices.contains(d.id) || d.isOnline()
        let usage = model.deviceUsageToday(d)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: d.platform == "iPadOS" ? "ipad" : "iphone").font(.system(size: 26, weight: .light))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(d.name).font(.system(size: 14, weight: .semibold))
                    Circle().fill(online ? Theme.accent : Theme.hairline).frame(width: 7, height: 7)
                    Text(online ? "ONLINE" : d.lastSeen.map { "SEEN \($0.formatted(.relative(presentation: .named)).uppercased())" } ?? "NOT SEEN YET")
                        .font(Theme.label(9)).foregroundStyle(.secondary)
                }
                Text("\(d.model ?? "Device") · \(d.platform ?? "iOS") · paired \(d.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(Theme.label(9.5)).foregroundStyle(.secondary)
                if !usage.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(usage.prefix(4)) { u in
                            Text("\(u.key) \(u.precision > 60 ? "≈" : "")\(DurationText.short(u.seconds))").font(Theme.label(9.5))
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
            Button("Remove…", role: .destructive) { confirmRevoke = d }.disabled(model.isLocked)
        }
        .padding(.vertical, 6)
    }
}

/// The QR code inside a slowly turning ring of dots, so it's clear the screen is live.
/// The code itself is drawn black-on-white in both modes so every camera can read it.
struct PairingCode: View {
    var url: String

    var body: some View {
        ZStack {
            DotRing(size: 240)
            if let image = PairingCode.qr(url) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 150, height: 150)
                    .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            }
        }
    }

    static func qr(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let output = f.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Concentric rings of dots drifting at different speeds (Vigil's own pairing animation).
struct DotRing: View {
    var size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            Canvas { gc, sz in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                for ring in 0..<4 {
                    let r = size / 2 - CGFloat(ring) * 9 - 4
                    let count = 64 - ring * 8
                    let speed = (ring % 2 == 0 ? 1.0 : -1.0) * (0.15 + Double(ring) * 0.05)
                    for i in 0..<count {
                        let a = Double(i) / Double(count) * 2 * .pi + t * speed
                        let wave = (sin(a * 3 + t * 1.3 + Double(ring)) + 1) / 2
                        let dot = 1.2 + wave * 2.2
                        let p = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
                        gc.fill(Path(ellipseIn: CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)),
                                with: .color(Theme.ink.opacity(0.25 + wave * 0.6)))
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}
