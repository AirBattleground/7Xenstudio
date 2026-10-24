// Inspector section for the Team Status board layer: data source (Manual / JSON URL / Mock), manual team editor,
// URL polling + field mapping, sort order, the strip under the header (social handle <-> match title).
import SwiftUI

struct TeamBoardInspector: View {
    var model: SceneEditorModel
    var layerID: String
    var spec: TeamBoardSpec

    private func set(_ label: String, coalesce: String? = nil, _ f: @escaping (inout TeamBoardSpec) -> Void) {
        model.update(layerID, label, coalesce: coalesce) { l in if case .teamBoard(var s) = l.kind { f(&s); l.kind = .teamBoard(s) } }
    }
    private func bind<T>(_ kp: WritableKeyPath<TeamBoardSpec, T>, _ label: String) -> Binding<T> {
        Binding(get: { spec[keyPath: kp] }, set: { v in set(label, coalesce: "tb\(kp)") { $0[keyPath: kp] = v } })
    }
    private func mapBind(_ kp: WritableKeyPath<TeamBoardMapping, String>) -> Binding<String> {
        Binding(get: { spec.mapping[keyPath: kp] }, set: { v in set("Board mapping", coalesce: "tbm\(kp)") { $0.mapping[keyPath: kp] = v } })
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorSection("Team status board", icon: "list.number") {
                FieldRow(label: "Data") {
                    Picker("", selection: bind(\.source, "Board data source")) {
                        Text("AirBattleground match").tag(TeamBoardSourceKind.airbattleground)
                        Text("Manual").tag(TeamBoardSourceKind.manual); Text("Custom JSON URL").tag(TeamBoardSourceKind.json); Text("Mock").tag(TeamBoardSourceKind.mock)
                    }.labelsHidden().controlSize(.small)
                }
                FieldRow(label: "Rows") {
                    Text("\(TeamBoardHub.shared.data(for: spec).teams.count) teams").font(Theme.Font.mono(11)).foregroundStyle(Theme.muted)
                    Spacer()
                }
                Toggle("Sort by points", isOn: bind(\.sortByPoints, "Board sort")).toggleStyle(.switch).controlSize(.mini)
                    .font(Theme.Font.caption).foregroundStyle(Theme.muted)
                Toggle("Auto-scroll when teams overflow", isOn: bind(\.autoScroll, "Board auto-scroll")).toggleStyle(.switch).controlSize(.mini)
                    .font(Theme.Font.caption).foregroundStyle(Theme.muted)
                if spec.autoScroll {
                    FieldRow(label: "Scroll speed") {
                        Text("Slow").font(Theme.Font.caption).foregroundStyle(Theme.faint)
                        Slider(value: bind(\.scrollSpeed, "Board scroll speed"), in: 0.5...1.0).controlSize(.small).tint(Theme.accent)
                        Text("Normal").font(Theme.Font.caption).foregroundStyle(Theme.faint)
                    }
                }
                Text("One row per team in the match (1-64). The panel always fills the layer's full height; few teams get taller rows and empty styled rows below. When the teams don't fit, the rows scroll slowly down and back up under the fixed header (3 s pause at each end); with auto-scroll off they shrink to fit. Teams with status 0 are shown greyed out. Sort off = slot order (# = slot); on = by TOT. PTS., then FIN. (# = position).")
                    .font(Theme.Font.caption).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }
            switch spec.source {
            case .airbattleground: abgSection
            case .manual: manualSection
            case .json: jsonSection
            case .mock: mockSection
            }
            EditorSection("Header strip", icon: "rectangle.2.swap") {
                FieldRow(label: "Handle") { TextField("airbattleground", text: bind(\.handle, "Board handle")).textFieldStyle(.roundedBorder).controlSize(.small) }
                FieldRow(label: "Match title") { TextField("{{matchTitle}}", text: bind(\.subtitle, "Board title")).textFieldStyle(.roundedBorder).controlSize(.small) }
                SliderRow(label: "Switch every", value: bind(\.carouselInterval, "Carousel interval"), range: 2...20, decimals: 0)
                Text("The strip under the logo cross-fades between the social handle (with the Instagram / YouTube / web icons) and the match title (seconds). {{matchTitle}} comes from the AirBattleground match picked in the app; empty = the title from the data.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: manual

    var manualSection: some View {
        EditorSection("Teams", icon: "person.3", trailing: AnyView(HStack(spacing: 8) {
            Button { set("Add team") { s in if s.manualTeams.count < TeamBoardSpec.maxTeams { let n = s.manualTeams.count + 1; s.manualTeams.append(.init(id: UUID().uuidString, name: "TEAM \(n)", status: 4)) } } } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).foregroundStyle(Theme.accent).help("Add a team")
            Menu {
                Button("All teams alive (4)") { set("Reset statuses") { s in for i in s.manualTeams.indices { s.manualTeams[i].status = 4; s.manualTeams[i].players = nil } } }
                Button("16 teams") { set("16 teams") { $0.manualTeams = Self.resized($0.manualTeams, 16) } }
                Button("20 teams") { set("20 teams") { $0.manualTeams = Self.resized($0.manualTeams, 20) } }
                Button("25 teams") { set("25 teams") { $0.manualTeams = Self.resized($0.manualTeams, 25) } }
                Button("32 teams") { set("32 teams") { $0.manualTeams = Self.resized($0.manualTeams, 32) } }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
        })) {
            ForEach(Array(spec.manualTeams.enumerated()), id: \.element.id) { i, t in
                HStack(spacing: 6) {
                    Text("\(i + 1)").font(Theme.Font.mono(10.5)).foregroundStyle(Theme.faint).frame(width: 18, alignment: .trailing)
                    TextField("Team", text: Binding(get: { t.name }, set: { v in set("Team name", coalesce: "tbn\(t.id)") { s in if let k = s.manualTeams.firstIndex(where: { $0.id == t.id }) { s.manualTeams[k].name = v } } }))
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                    intField("FIN", t, t.finishes, help: "Finishes (kills); empty = -") { s, v in s.finishes = v }
                    intField("PTS", t, t.points, help: "Total points; empty = -") { s, v in s.points = v }
                    Stepper(value: Binding(get: { t.status }, set: { v in set("Team status") { s in if let k = s.manualTeams.firstIndex(where: { $0.id == t.id }) { s.manualTeams[k].status = v; s.manualTeams[k].players = nil } } }), in: 0...4) {
                        Text("\(t.status)").font(Theme.Font.mono(11)).foregroundStyle(t.status == 0 ? Theme.faint : Theme.text).frame(width: 12)
                    }.controlSize(.small).help("Players alive (0 = eliminated)")
                    Button { set("Remove team") { s in s.manualTeams.removeAll { $0.id == t.id } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(Theme.faint).help("Remove team")
                }
            }
            Text("FIN = finishes, PTS = total points (empty shows -). Status = players still alive (0-4); 0 greys the row out. Changes go on air when the scene is saved.")
                .font(Theme.Font.caption).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }
    }
    /// Small optional-number field of a manual team (empty = unknown).
    func intField(_ placeholder: String, _ t: TeamBoardData.Team, _ value: Int?, help: String, _ apply: @escaping (inout TeamBoardData.Team, Int?) -> Void) -> some View {
        TextField(placeholder, text: Binding(get: { value.map(String.init) ?? "" }, set: { v in
            let digits = v.filter(\.isNumber)
            let n = digits.isEmpty ? nil : Int(digits.prefix(5))
            set("Team \(placeholder)", coalesce: "tb\(placeholder)\(t.id)") { s in if let k = s.manualTeams.firstIndex(where: { $0.id == t.id }) { apply(&s.manualTeams[k], n) } }
        }))
        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 38).multilineTextAlignment(.center).help(help)
    }
    static func resized(_ teams: [TeamBoardData.Team], _ n: Int) -> [TeamBoardData.Team] {
        var t = Array(teams.prefix(n))
        while t.count < n { t.append(.init(id: UUID().uuidString, name: "TEAM \(t.count + 1)", status: 4)) }
        return t
    }

    // MARK: AirBattleground

    var abgSection: some View {
        EditorSection("AirBattleground match", icon: "dot.radiowaves.left.and.right") {
            Text("Live team status of the match picked in the app (AirBattleground chip). The match manager keeps it up to date on AirBattleground's Match Center - read-only here.")
                .font(Theme.Font.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            statusLine
            Text("Polled every 3 s. If AirBattleground stops answering, the last good data stays on air and a small orange dot appears after 15 s.")
                .font(Theme.Font.caption).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }
    }
    var statusLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let st = TeamBoardHub.shared.status(for: spec)
            Group {
                if let e = st.error { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                else if let ok = st.ok { Label("Updated \(Int(Date().timeIntervalSince(ok)))s ago", systemImage: "checkmark.circle").foregroundStyle(Theme.ok) }
                else { Label("Waiting for the first answer…", systemImage: "clock").foregroundStyle(Theme.faint) }
            }.font(Theme.Font.caption).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: JSON

    var jsonSection: some View {
        EditorSection("JSON URL", icon: "network") {
            TextField("https://… match center JSON", text: bind(\.url, "Board URL")).textFieldStyle(.roundedBorder).controlSize(.small)
            SliderRow(label: "Poll every", value: bind(\.pollInterval, "Poll interval"), range: 1...30, decimals: 0)
            FieldRow(label: "Header") { TextField("Authorization: Bearer …", text: bind(\.header, "Board header")).textFieldStyle(.roundedBorder).controlSize(.small) }
            statusLine
            DisclosureGroup("Field mapping") {
                VStack(spacing: 4) {
                    mapRow("Teams array", \.teamsPath, "teams")
                    mapRow("Match title", \.titlePath, "match.title")
                    mapRow("Name", \.nameField, "name")
                    mapRow("Status", \.statusField, "status")
                    mapRow("Players", \.playersField, "players")
                    mapRow("Player state", \.playerStateField, "state")
                    mapRow("Logo", \.logoField, "logo")
                    mapRow("Slot (rank)", \.rankField, "slot")
                    mapRow("FIN.", \.finishesField, "kills")
                    mapRow("TOT. PTS.", \.pointsField, "totalPoints")
                    mapRow("Standings", \.summaryPath, "summary.teams")
                    Text("Dot paths, e.g. data.teams or team.name. Default = the AirBattleground live shape: { \"match\": { \"title\" }, \"teams\": [ { \"slot\", \"name\", \"status\": 0-4, \"kills\", \"totalPoints\", \"players\": [ { \"state\": \"alive|knocked|eliminated\" } ], \"logo\" } ] }. FIN. / TOT. PTS. missing on a team: taken from the standings entry with the same slot (else name).")
                        .font(Theme.Font.caption).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 4)
            }.font(Theme.Font.caption).foregroundStyle(Theme.muted)
        }
    }
    func mapRow(_ label: String, _ kp: WritableKeyPath<TeamBoardMapping, String>, _ placeholder: String) -> some View {
        FieldRow(label: label, labelWidth: 84) { TextField(placeholder, text: mapBind(kp)).textFieldStyle(.roundedBorder).controlSize(.small) }
    }

    // MARK: mock

    var mockSection: some View {
        EditorSection("Mock data", icon: "theatermasks") {
            FieldRow(label: "Teams") {
                Stepper(value: bind(\.mockTeams, "Mock teams"), in: 1...TeamBoardSpec.maxTeams) { Text("\(spec.mockTeams)").font(Theme.Font.mono(11)) }.controlSize(.small)
                Spacer()
            }
            Text("Sample teams whose players get knocked and eliminated every few seconds - for rehearsals and testing.")
                .font(Theme.Font.caption).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }
    }
}
