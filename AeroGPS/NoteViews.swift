import SwiftUI

/// Identifies the note edited in a sheet.
struct NoteSheet: Identifiable {
    let id = UUID()
    let tripID: UUID
    let note: TripNote
    let isNew: Bool
}

extension NoteKind {
    var color: Color {
        switch self {
        case .generic: return .blue
        case .fuel:    return .orange
        case .food:    return .pink
        }
    }
}

/// "Add note" menu: pick the type, then the form opens (the type can still be changed there).
struct AddNoteMenu<Content: View>: View {
    let add: (NoteKind) -> Void
    @ViewBuilder let label: () -> Content

    var body: some View {
        Menu {
            ForEach(NoteKind.allCases) { k in
                Button { add(k) } label: { Label(k.name, systemImage: k.icon) }
            }
        } label: {
            label()
        }
    }
}

struct NoteRow: View {
    let note: TripNote

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: note.kind.icon)
                .foregroundColor(note.kind.color)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.headline).font(.subheadline).lineLimit(3)
                if let d = note.detail {
                    Text(d).font(.caption).foregroundColor(.secondary).lineLimit(3)
                }
                HStack(spacing: 6) {
                    Text(note.date, style: .time)
                    if !note.hasPosition { Text("· no position") }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

/// Add or edit one note.
struct NoteEditView: View {
    @EnvironmentObject private var store: TripStore
    @Environment(\.dismiss) private var dismiss

    let tripID: UUID
    let isNew: Bool
    @State private var note: TripNote
    // Number fields are edited as text so "42,5" and "42.5" both work.
    @State private var amountText: String
    @State private var priceText: String
    @State private var confirmDelete = false
    @FocusState private var focusedField: Bool

    init(sheet: NoteSheet) {
        tripID = sheet.tripID
        isNew = sheet.isNew
        _note = State(initialValue: sheet.note)
        _amountText = State(initialValue: sheet.note.amount.map { Fmt.decimal($0) } ?? "")
        _priceText = State(initialValue: sheet.note.price.map { String(format: "%.2f", $0) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $note.kind) {
                        ForEach(NoteKind.allCases) { k in
                            Text(k.name).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch note.kind {
                case .fuel:    fuelSection
                case .food:    foodSection
                case .generic: EmptyView()
                }

                Section(note.kind == .generic ? "Note" : "Comment") {
                    TextField(note.kind == .generic ? "Write anything…" : "Optional", text: $note.text, axis: .vertical)
                        .lineLimit(note.kind == .generic ? 4...12 : 2...6)
                        .focused($focusedField)
                }

                Section {
                    DatePicker("Time", selection: $note.date)
                    if let lat = note.lat, let lon = note.lon {
                        LabeledContent("Position", value: String(format: "%.5f, %.5f", lat, lon))
                        if let alt = note.alt {
                            LabeledContent("Altitude", value: "\(Fmt.group(alt)) m")
                        }
                    } else {
                        LabeledContent("Position", value: "none")
                    }
                } footer: {
                    if !note.hasPosition {
                        Text("Notes get the GPS position when added while recording.")
                    }
                }

                if !isNew {
                    Section {
                        Button("Delete note", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isNew ? "New note" : "Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog("Delete this note?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete note", role: .destructive) {
                    store.deleteNote(note.id, in: tripID)
                    dismiss()
                }
            }
            .onAppear {
                if isNew && note.kind == .generic { focusedField = true }
            }
            .onChange(of: note.kind) { kind in
                // Switched type in the form: pre-fill what the new type needs.
                if kind == .fuel && note.fuelType.isEmpty { note.fuelType = NoteDefaults.fuelType }
                if kind != .generic && note.currency.isEmpty { note.currency = NoteDefaults.currency }
            }
        }
    }

    // MARK: - Type-specific fields

    private var fuelSection: some View {
        Section("Fueling") {
            Picker("Fuel", selection: $note.fuelType) {
                ForEach(TripNote.fuelTypes, id: \.self) { Text($0).tag($0) }
                if !note.fuelType.isEmpty && !TripNote.fuelTypes.contains(note.fuelType) {
                    Text(note.fuelType).tag(note.fuelType)
                }
            }
            numberField(note.unit == "kWh" ? "Energy" : "Amount", text: $amountText, unit: note.unit)
            numberField("Total price", text: $priceText, unit: nil)
            currencyField
            if let a = Fmt.parseNumber(amountText), a > 0, let p = Fmt.parseNumber(priceText) {
                LabeledContent("Price per \(note.unit)", value: Fmt.money(p / a, note.currency, decimals: 3))
            }
        }
    }

    private var foodSection: some View {
        Section("Food") {
            TextField("What did you eat?", text: $note.food, axis: .vertical)
                .lineLimit(1...4)
            numberField("Price", text: $priceText, unit: nil)
            currencyField
        }
    }

    private func numberField(_ label: String, text: Binding<String>, unit: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
            if let unit { Text(unit).foregroundColor(.secondary) }
        }
    }

    private var currencyField: some View {
        HStack {
            Text("Currency")
            Spacer()
            TextField("EUR", text: $note.currency)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
        }
    }

    // MARK: - Save

    private func save() {
        var n = note
        n.text = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
        n.food = n.food.trimmingCharacters(in: .whitespacesAndNewlines)
        n.currency = n.currency.trimmingCharacters(in: .whitespaces).uppercased()
        switch n.kind {
        case .fuel:
            n.amount = Fmt.parseNumber(amountText)
            n.price = Fmt.parseNumber(priceText)
            n.food = ""
        case .food:
            n.price = Fmt.parseNumber(priceText)
            n.amount = nil
            n.fuelType = ""
        case .generic:
            n.price = nil
            n.amount = nil
            n.fuelType = ""
            n.food = ""
        }
        if n.price == nil { n.currency = n.kind == .generic ? "" : n.currency }
        // Pre-fill the next note with what was used now.
        if n.price != nil && !n.currency.isEmpty { NoteDefaults.currency = n.currency }
        if n.kind == .fuel && !n.fuelType.isEmpty { NoteDefaults.fuelType = n.fuelType }
        store.saveNote(n, in: tripID)
    }
}
