import Prism
import PrismEmblem
import SwiftUI

/// What a query river asks, as its editor has it: a form over the
/// query's own lines. What the form has no place for is kept as written.
struct QuerySpec: Equatable {
    enum Sort: String, CaseIterable, Identifiable {
        case newestChanged = "-modified", oldestChanged = "modified", newestCreated = "-created", oldestCreated = "created", title = "title"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .newestChanged: return "Newest Changed"
            case .oldestChanged: return "Oldest Changed"
            case .newestCreated: return "Newest Created"
            case .oldestCreated: return "Oldest Created"
            case .title: return "Title"
            }
        }
    }

    enum Want: String, CaseIterable, Identifiable {
        case any, only, not
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// The kinds a note can be asked to be, or not to be: what `is:` takes.
    static let kinds: [(key: String, name: String)] = [
        ("inbox", "In the Inbox"), ("pinned", "Pinned"), ("task", "To-Dos"), ("wiki", "Wiki"), ("note", "Notes"), ("day", "Days"), ("week", "Weeks"),
    ]

    var sort = Sort.newestChanged
    var kinds: [String: Want] = [:]
    var tags: [String] = []
    var notTags: [String] = []
    var linksTo = ""
    var saying = ""
    var limit: Int?
    /// Lines the form has no place for.
    var other: [String] = []

    init() {}

    /// Reads a query's body.
    init(body: String) {
        for line in body.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                other.append(line)
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let listed = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            switch key {
            case "sort": if let known = Sort(rawValue: value.lowercased()) { sort = known } else { other.append(line) }
            case "tag": tags.append(contentsOf: listed)
            case "not tag": notTags.append(contentsOf: listed)
            case "is": for kind in listed { kinds[kind.lowercased()] = .only }
            case "is not": for kind in listed { kinds[kind.lowercased()] = .not }
            case "links to" where linksTo.isEmpty: linksTo = value
            case "text" where saying.isEmpty: saying = value
            case "limit": limit = Int(value)
            default: other.append(line)
            }
        }
    }

    /// The query's body: a clause a line.
    var body: String {
        var lines: [String] = []
        for tag in tags { lines.append("tag: \(tag)") }
        for tag in notTags { lines.append("not tag: \(tag)") }
        // In the order they are listed, so that the same form writes the same lines.
        let known = Self.kinds.map(\.key)
        for key in known + kinds.keys.filter({ !known.contains($0) }).sorted() {
            switch kinds[key] {
            case .only: lines.append("is: \(key)")
            case .not: lines.append("is not: \(key)")
            default: break
            }
        }
        if !linksTo.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("links to: \(linksTo.trimmingCharacters(in: .whitespaces))") }
        if !saying.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("text: \(saying.trimmingCharacters(in: .whitespaces))") }
        lines.append(contentsOf: other)
        lines.append("sort: \(sort.rawValue)")
        if let limit, limit > 0 { lines.append("limit: \(limit)") }
        return lines.joined(separator: "\n")
    }

    /// What it finds, in a few words.
    var summary: String {
        var parts: [String] = []
        if !tags.isEmpty { parts.append("Tagged " + tags.joined(separator: ", ")) }
        let name = { (key: String) in Self.kinds.first { $0.key == key }?.name ?? key.capitalized }
        let only = kinds.filter { $0.value == .only }.keys.sorted().map(name)
        let not = kinds.filter { $0.value == .not }.keys.sorted().map(name)
        if !only.isEmpty { parts.append(only.joined(separator: ", ")) }
        if !not.isEmpty { parts.append("Not " + not.joined(separator: ", ")) }
        if !notTags.isEmpty { parts.append("Not tagged " + notTags.joined(separator: ", ")) }
        if !linksTo.isEmpty { parts.append("Linking to \(linksTo)") }
        if !saying.isEmpty { parts.append("Saying “\(saying)”") }
        if parts.isEmpty { parts.append("All notes") }
        parts.append(sort.label)
        return parts.joined(separator: " · ")
    }
}

#if os(macOS)
/// Over a query river's cards: what it finds, said in words, a click
/// away from its settings.
struct QueryRiverHeader: View {
    let store: GraphStore
    let river: River
    @State private var isHovered = false

    var body: some View {
        Button { store.queryAsk = .edit(river) } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 13, weight: .medium)).foregroundStyle(river.emblem.color?.color ?? Color.inkSecondary)
                Text(QuerySpec(body: river.query ?? "").summary).font(.callout).foregroundStyle(Color.inkSecondary).lineLimit(1)
                Spacer(minLength: 8)
                if river.foundTotal > river.found.count + river.hidden.count {
                    Text("\(river.found.count) of \(river.foundTotal)").font(.caption).monospacedDigit().foregroundStyle(Color.inkFaint)
                } else {
                    Text("\(river.all.count)").font(.caption).monospacedDigit().foregroundStyle(Color.inkFaint)
                }
                Text("Edit").font(.callout.weight(.medium)).foregroundStyle(Color.inkAccent)
            }
            .padding(.leading, Measures.margin)
            .padding(.trailing, Measures.cardTrailing)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Measures.cardRadius, style: .continuous).fill(Color.inkPaper.opacity(isHovered ? 1 : 0.7)))
            .contentShape(RoundedRectangle(cornerRadius: Measures.cardRadius))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Edit what the river finds, and how it orders it")
    }
}

#endif

/// A query river's settings: its name, icon and colour; how it sorts;
/// what it finds, from where, and what not.
struct QueryRiverEditor: View {
    let store: GraphStore
    let ask: GraphStore.QueryAsk
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon: String?
    @State private var color: String?
    @State private var spec = QuerySpec()
    @State private var choosesLook = false
    @State private var allTags: [TagCount] = []
    @State private var limitText = ""

    private var river: River? {
        if case .edit(let river) = ask { return river }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Button { choosesLook = true } label: { EmblemView(Emblem(title: name.isEmpty ? "Query" : name, icon: icon, color: color), size: 28) }
                            .buttonStyle(.plain)
                            .popover(isPresented: $choosesLook, arrowEdge: .bottom) { EmblemPicker(title: name.isEmpty ? "Query" : name, icon: $icon, color: $color) }
                            .help("Choose an icon and a colour")
                        TextField("Title", text: $name, prompt: Text("Most Recent")).labelsHidden()
                    }
                }
                Section {
                    Picker("Sort", selection: $spec.sort) { ForEach(QuerySpec.Sort.allCases) { Text($0.label).tag($0) } }
                }
                Section("Kinds of Notes") {
                    ForEach(QuerySpec.kinds, id: \.key) { kind in
                        Picker(kind.name, selection: Binding(get: { spec.kinds[kind.key] ?? .any }, set: { spec.kinds[kind.key] = $0 == .any ? nil : $0 })) {
                            ForEach(QuerySpec.Want.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section {
                    tags("Tagged", $spec.tags)
                    tags("Excluding Tags", $spec.notTags)
                    TextField("Linking To", text: $spec.linksTo, prompt: Text("A note's name"))
                    TextField("Saying", text: $spec.saying, prompt: Text("Words it has"))
                    TextField("At Most", text: $limitText, prompt: Text("\(GraphStore.foundLimit)"))
                } header: {
                    Text("From")
                } footer: {
                    Text("Only: notes of every kind marked so. Not: no note of any kind marked so. Tagged: with every tag listed.")
                }
                if !spec.other.isEmpty {
                    Section("Also Asked") {
                        Text(spec.other.joined(separator: "\n")).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Section {
                    LabeledContent("Finds", value: finds)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(river == nil ? "Create" : "Done") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        #if os(macOS)
        .frame(width: 500, height: 680)
        #endif
        .onAppear(perform: start)
        .onChange(of: limitText) { _, text in spec.limit = Int(text.trimmingCharacters(in: .whitespaces)) }
    }

    /// Tags, as written — and a menu of those there are, to add from.
    private func tags(_ title: String, _ chosen: Binding<[String]>) -> some View {
        HStack {
            TextField(title, text: Binding(get: { chosen.wrappedValue.joined(separator: ", ") }, set: { chosen.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }), prompt: Text("None"))
            Menu {
                ForEach(allTags.prefix(40), id: \.tag) { item in
                    let has = chosen.wrappedValue.contains { $0.caseInsensitiveCompare(item.tag) == .orderedSame }
                    Button {
                        if has { chosen.wrappedValue.removeAll { $0.caseInsensitiveCompare(item.tag) == .orderedSame } } else { chosen.wrappedValue.append(item.tag) }
                    } label: { Label("\(item.tag)  (\(item.pages))", systemImage: has ? "checkmark" : "tag") }
                }
            } label: { Image(systemName: "tag") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose from the tags there are")
        }
    }

    private var finds: String {
        let found = store.count(spec.body)
        return "\(found) \(found == 1 ? "note" : "notes")"
    }

    private func start() {
        allTags = (try? store.engine.tags()) ?? []
        guard let river else { return }
        name = river.name ?? ""
        icon = river.icon
        color = river.color
        spec = QuerySpec(body: river.query ?? "sort: -modified")
        limitText = spec.limit.map(String.init) ?? ""
    }

    private func finish() {
        let name = name.trimmingCharacters(in: .whitespaces)
        if let river {
            river.query = spec.body
            river.icon = icon
            river.color = color
            if river.name != name { store.rename(river, to: name) } else { store.rememberRivers() }
            store.find(for: river)
        } else {
            store.newQueryRiver(name: name, query: spec.body, icon: icon, color: color)
        }
        dismiss()
    }
}
