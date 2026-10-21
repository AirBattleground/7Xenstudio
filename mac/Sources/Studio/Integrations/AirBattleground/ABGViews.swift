import SwiftUI
import AppKit
import AVFoundation

// MARK: - QR scanner (camera) for the connect link

private struct QRScannerView: NSViewRepresentable {
    var onCode: (String) -> Void
    var onFailure: (String) -> Void
    func makeCoordinator() -> Coord { Coord(onCode: onCode, onFailure: onFailure) }
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true
        context.coordinator.start(in: v)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { context.coordinator.layout(v) }
    static func dismantleNSView(_ v: NSView, coordinator: Coord) { coordinator.stop() }

    final class Coord: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        let onCode: (String) -> Void, onFailure: (String) -> Void
        let session = AVCaptureSession(); var preview: AVCaptureVideoPreviewLayer?
        init(onCode: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) { self.onCode = onCode; self.onFailure = onFailure }
        func start(in view: NSView) {
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { [self] in
                    guard ok, let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
                        onFailure("Couldn't open the camera. Allow camera access in System Settings, or paste the link below."); return
                    }
                    session.addInput(input)
                    let out = AVCaptureMetadataOutput()
                    guard session.canAddOutput(out) else { onFailure("Couldn't start QR scanning. Paste the link below."); return }
                    session.addOutput(out)
                    out.setMetadataObjectsDelegate(self, queue: .main)
                    out.metadataObjectTypes = [.qr]
                    let l = AVCaptureVideoPreviewLayer(session: session); l.videoGravity = .resizeAspectFill; l.frame = view.bounds
                    view.layer?.addSublayer(l); preview = l
                    DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
                }
            }
        }
        func layout(_ v: NSView) { preview?.frame = v.bounds }
        func stop() { if session.isRunning { session.stopRunning() } }
        func metadataOutput(_ o: AVCaptureMetadataOutput, didOutput objs: [AVMetadataObject], from c: AVCaptureConnection) {
            if let s = (objs.first as? AVMetadataMachineReadableCodeObject)?.stringValue { onCode(s) }
        }
    }
}

// MARK: - Connect dialog (studio-link pairing)

struct ABGConnectDialog: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var scanning = false
    @State private var camError: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect AirBattleground").font(.title2.bold())
            Text("On AirBattleground open Manager → Studio → \"Connect a studio\", then show the QR code to this Mac's camera, or paste the link or key.")
                .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if scanning {
                ZStack(alignment: .bottom) {
                    QRScannerView(onCode: { code in if ABGLink.parse(code) != nil { text = code; scanning = false; submit() } },
                                  onFailure: { camError = $0; scanning = false })
                        .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(busy ? "Connecting…" : "Looking for the QR code…").font(.caption).padding(6).frame(maxWidth: .infinity).background(.black.opacity(0.6))
                }
            } else {
                Button { camError = nil; scanning = true } label: { Label("Scan with the camera", systemImage: "camera") }
            }
            if let c = camError { Text(c).font(.caption).foregroundStyle(Theme.warn) }
            Text("Or paste the link or key").font(.caption).foregroundStyle(Theme.muted)
            TextField("7xen-studio://connect?… or sw_…", text: $text).textFieldStyle(.roundedBorder).onSubmit(submit).disabled(busy)
            if let e = error { Text(e).font(.caption).foregroundStyle(Theme.program).fixedSize(horizontal: false, vertical: true) }
            Text("The key is kept in your Mac's Keychain and only sent to AirBattleground.").font(.caption).foregroundStyle(Theme.muted)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { submit() } label: { Label(busy ? "Connecting…" : "Connect", systemImage: "link") }
                    .keyboardShortcut(.defaultAction).disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(20).frame(width: 460)
    }
    private func submit() {
        guard !busy else { return }
        guard ABGLink.parse(text) != nil else {
            error = "That isn't a studio link. Copy the whole link (7xen-studio://connect…) or the key starting with sw_."; return
        }
        busy = true; error = nil
        Task {
            do { try await model.abg.connect(link: text); dismiss(); if !model.abg.hasMatch { model.abg.showMatches = true } }
            catch { self.error = ABGController.message(error) }
            busy = false
        }
    }
}

// MARK: - Match picker

struct ABGMatchPicker: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var includeFinished = false

    var body: some View {
        let abg = model.abg
        let items = ABGController.filter(abg.matches, query: query, includeFinished: includeFinished)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pick the match to cover").font(.title2.bold()); Spacer()
                Button { Task { await abg.refreshMatches() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(abg.matchesLoading)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search matches or teams", text: $query).textFieldStyle(.roundedBorder)
                Toggle("Finished", isOn: $includeFinished).toggleStyle(.checkbox)
            }
            if let e = abg.matchesError { Text(e).font(.caption).foregroundStyle(Theme.program) }
            if abg.matchesLoading && abg.matches.isEmpty { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
            else if items.isEmpty {
                EmptyState(icon: "sportscourt", title: abg.matches.isEmpty ? "No matches yet" : "No match found",
                           message: abg.matches.isEmpty ? "Matches you manage on AirBattleground show up here." : "Try another search, or include finished matches.")
            } else {
                List(items) { m in
                    Button { abg.select(m); dismiss() } label: {
                        HStack(spacing: 10) {
                            StatusDot(color: m.status == .live ? Theme.program : m.status == .upcoming ? Theme.accent : Theme.faint, pulse: m.status == .live)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.title).font(Theme.Font.bodyBold)
                                if !m.subtitle.isEmpty { Text(m.subtitle).font(Theme.Font.caption).foregroundStyle(Theme.muted) }
                            }
                            Spacer()
                            if let d = Self.when(m.startsAt) { Text(d).font(Theme.Font.caption).foregroundStyle(Theme.muted) }
                            Pill(text: m.status.rawValue.uppercased(), color: m.status == .live ? Theme.program : Theme.muted)
                            if abg.link?.eventId == m.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.frame(minHeight: 240)
            }
            HStack {
                if abg.hasMatch { Button("Clear selection", role: .destructive) { abg.clearSelection() } }
                Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 560, height: 460)
        .task { if abg.matches.isEmpty || Date().timeIntervalSince(abg.matchesLoadedAt ?? .distantPast) > 30 { await abg.refreshMatches() } }
    }
    static func when(_ iso: String?) -> String? {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) ?? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: iso) }() else { return nil }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Status chips

/// Toolbar chip: connection + selected match; click for details.
struct ABGToolbarChip: View {
    @Environment(AppModel.self) var model
    @State private var open = false
    var body: some View {
        let abg = model.abg
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: abg.isConnected ? "link" : "link.badge.plus")
                Text(abg.isConnected ? (abg.hasMatch ? (abg.selectedTitle ?? "Match") : "Select match") : "AirBattleground")
                    .lineLimit(1).frame(maxWidth: 170)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(abg.lastError != nil ? Theme.warn : abg.isConnected ? (abg.hasMatch ? Theme.ok : Theme.accent) : Theme.muted)
        }
        .buttonStyle(.studio(.secondary, height: 26))
        .help(abg.isConnected ? "AirBattleground: \(abg.account?.name ?? "")" : "Connect AirBattleground")
        .popover(isPresented: $open, arrowEdge: .bottom) { ABGStatusPanel(close: { open = false }).environment(model) }
        .accessibilityLabel("AirBattleground").accessibilityValue(abg.isConnected ? "Connected, \(abg.selectedTitle ?? "no match")" : "Not connected")
    }
}

struct ABGStatusPanel: View {
    @Environment(AppModel.self) var model
    var close: () -> Void
    var body: some View {
        let abg = model.abg
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StatusDot(color: abg.isConnected ? (abg.lastError == nil ? Theme.ok : Theme.warn) : Theme.faint)
                Text(abg.isConnected ? "AirBattleground connected" : "AirBattleground not connected").font(Theme.Font.heading)
            }
            if let a = abg.account { Text("\(a.name)\(a.org.map { " · \($0)" } ?? "")").font(Theme.Font.caption).foregroundStyle(Theme.muted) }
            if let e = abg.lastError { Text(e).font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true) }
            if abg.isConnected {
                Divider()
                ABGMatchSummary()
                HStack {
                    Button(abg.hasMatch ? "Change match" : "Select match") { close(); abg.showMatches = true }
                    Spacer()
                    Button("Disconnect", role: .destructive) { abg.disconnect(); close() }.disabled(abg.isBroadcasting)
                }
            } else {
                Button { close(); abg.showConnect = true } label: { Label("Connect…", systemImage: "link") }.buttonStyle(.studio(.primary(Theme.accent), height: 28))
            }
        }.padding(14).frame(width: 300)
    }
}

/// Match title / teams (and status) for popovers and sheets.
struct ABGMatchSummary: View {
    @Environment(AppModel.self) var model
    var body: some View {
        if let l = model.abg.link, l.eventId != nil {
            VStack(alignment: .leading, spacing: 2) {
                Text(l.eventTitle ?? "Match").font(Theme.Font.bodyBold)
                if let s = l.eventSubtitle { Text(s).font(Theme.Font.caption).foregroundStyle(Theme.muted) }
            }
        } else { Text("No match selected").font(Theme.Font.caption).foregroundStyle(Theme.muted) }
    }
}

/// Badge for the program monitor (match title / teams) while a match is attached.
struct ABGMatchBadge: View {
    @Environment(AppModel.self) var model
    var body: some View {
        if model.abg.isConnected, let l = model.abg.link, let t = l.eventTitle {
            HStack(spacing: 5) {
                Image(systemName: "sportscourt.fill").font(.system(size: 10))
                Text(t).lineLimit(1)
                if let s = l.eventSubtitle { Text("· \(s)").lineLimit(1).foregroundStyle(.white.opacity(0.65)) }
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8).frame(height: 22).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .help("AirBattleground match: \(t)")
        }
    }
}

// MARK: - Settings section

struct ABGSettingsSection: View {
    @Environment(AppModel.self) var model
    var body: some View {
        let abg = model.abg
        Section("AirBattleground") {
            if let a = abg.account {
                LabeledContent("Account", value: "\(a.name)\(a.org.map { " · \($0)" } ?? "")")
                LabeledContent("Server", value: abg.host ?? abgDefaultHost)
                LabeledContent("Match") {
                    HStack { Text(abg.link?.eventTitle ?? "None selected").foregroundStyle(abg.hasMatch ? Color.primary : Color.secondary)
                        Button(abg.hasMatch ? "Change…" : "Select…") { abg.showMatches = true } }
                }
                if let e = abg.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                Button("Disconnect", role: .destructive) { abg.disconnect() }.disabled(abg.isBroadcasting)
            } else {
                Text("Not connected. Link this studio to AirBattleground to pick a match and stream to the admin's YouTube.").foregroundStyle(.secondary)
                Button { abg.showConnect = true } label: { Label("Connect AirBattleground…", systemImage: "link") }
            }
        }
    }
}

// MARK: - Go Live sheet

struct GoLiveSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State private var option: GoLiveOption = .adminYouTube
    @State private var alsoRecord = true
    @State private var advancedOpen = false
    @State private var advanced: Set<String> = []
    @State private var starting = false
    @State private var error: String?
    @State private var showConnect = false
    @State private var showMatches = false

    private var youtubeReady: Bool { model.abg.isConnected && model.abg.hasMatch }

    var body: some View {
        let abg = model.abg
        VStack(alignment: .leading, spacing: 14) {
            Text("Go live").font(.title2.bold())
            optionRow(.adminYouTube, title: "Admin YouTube", icon: "play.rectangle.fill", enabled: youtubeReady) {
                if youtubeReady {
                    Text("Streams to the admin's YouTube channel for the selected match.").foregroundStyle(Theme.muted)
                    HStack(spacing: 6) { Image(systemName: "sportscourt.fill"); ABGMatchSummary(); Spacer(); Button("Change") { showMatches = true }.controlSize(.small) }
                        .padding(8).background(Theme.panelHi, in: RoundedRectangle(cornerRadius: 8))
                    Toggle("Also record to disk", isOn: $alsoRecord).toggleStyle(.checkbox)
                } else if !abg.isConnected {
                    Text("Connect AirBattleground to stream to the admin's YouTube.").foregroundStyle(Theme.muted)
                    Button { showConnect = true } label: { Label("Connect", systemImage: "link") }.controlSize(.small)
                } else {
                    Text("Select the AirBattleground match to cover first.").foregroundStyle(Theme.muted)
                    Button { showMatches = true } label: { Label("Select match", systemImage: "sportscourt") }.controlSize(.small)
                }
            }
            optionRow(.recordOnly, title: "Record only", icon: "internaldrive.fill", enabled: true) {
                Text("Records the show to a file on this Mac. Nothing is streamed.").foregroundStyle(Theme.muted)
            }
            if !model.destinations.isEmpty && option == .adminYouTube && youtubeReady {
                DisclosureGroup("Advanced: other destinations", isExpanded: $advancedOpen) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.destinations) { d in
                            Toggle(d.name, isOn: Binding(get: { advanced.contains(d.id) }, set: { if $0 { advanced.insert(d.id) } else { advanced.remove(d.id) } })).toggleStyle(.checkbox)
                        }
                        Text("Your saved stream keys are sent in addition to YouTube.").font(.caption).foregroundStyle(Theme.muted)
                    }.padding(.top, 4)
                }
            }
            if let e = error {
                VStack(alignment: .leading, spacing: 4) {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.program).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(starting)
                Button { start() } label: {
                    Label(starting ? "Starting…" : (error != nil ? "Retry" : "Go Live"), systemImage: "dot.radiowaves.left.and.right")
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.program)
                .disabled(starting || (option == .adminYouTube && !youtubeReady))
            }
        }
        .padding(20).frame(width: 480)
        .onAppear { if !youtubeReady { option = .recordOnly }; alsoRecord = model.recordOn }
        .onChange(of: youtubeReady) { _, ready in if ready { option = .adminYouTube } }
        .sheet(isPresented: $showConnect) { ABGConnectDialog().environment(model) }
        .sheet(isPresented: $showMatches) { ABGMatchPicker().environment(model) }
    }

    @ViewBuilder private func optionRow<C: View>(_ o: GoLiveOption, title: String, icon: String, enabled: Bool, @ViewBuilder content: () -> C) -> some View {
        let sel = option == o
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: sel ? "largecircle.fill.circle" : "circle").font(.system(size: 16)).foregroundStyle(enabled ? (sel ? Theme.accent : Theme.muted) : Theme.faint)
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).font(Theme.Font.heading).foregroundStyle(enabled ? Theme.text : Theme.faint)
                content().font(Theme.Font.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(sel ? Theme.accent.opacity(0.12) : Theme.panelHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(sel ? Theme.accent : Theme.stroke, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if enabled && !starting { option = o; error = nil } }
        .accessibilityElement(children: .contain)
    }

    private func start() {
        starting = true; error = nil
        let opt = option, rec = alsoRecord, extra = Array(advanced.intersection(Set(model.destinations.map(\.id))))
        Task {
            do { try await model.startShow(opt, alsoRecord: rec, otherDestinationIDs: extra); dismiss() }
            catch { self.error = ABGController.message2(error) }
            starting = false
        }
    }
}

extension ABGController {
    /// any error -> operator-facing sentence (ABGError wording, otherwise the localized description)
    nonisolated static func message2(_ e: Error) -> String { (e as? ABGError)?.errorDescription ?? e.localizedDescription }
}
