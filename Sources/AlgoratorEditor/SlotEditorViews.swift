import SwiftUI
import AlgoratorCore

/// A literal being typed in place, over its slot.
struct InlineEdit: Equatable {
    var slot: SlotLayout
    var edit: LiteralEdit
}

/// A multi-line literal being edited in a popover that points at its slot.
struct LongTextRequest: Equatable {
    var edit: LiteralEdit
    /// The slot's frame, in canvas coordinates.
    var frame: CGRect
}

/// The multi-line editor: Return inserts a newline, Done (or clicking away) commits, Esc cancels.
@MainActor
struct LongTextPopover: View {
    @Binding var text: String
    var commit: () -> Void
    var cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 380, minHeight: 150)
                .focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            HStack {
                Text("{name} inserts a variable where the slot is a template").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Done", action: commit).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(10)
        .onExitCommand(perform: cancel)
        .onAppear { focused = true }
    }
}

/// The text field laid over a slot while its literal is typed.
@MainActor
struct InlineField: View {
    @Binding var text: String
    var width: CGFloat
    var height: CGFloat
    var fontSize: CGFloat
    var commit: () -> Void
    var cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize))
            .foregroundStyle(BlockRenderer.fieldText)
            .padding(.horizontal, 7)
            .frame(width: width, height: height)
            .background(Capsule().fill(.white))
            .overlay(Capsule().stroke(Color.accentColor, lineWidth: 2))
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onAppear { focused = true }
    }
}

/// A slot or binding whose value is picked from a popover.
struct PickerRequest: Identifiable, Equatable {
    enum Kind: Equatable {
        case options([String])
        case reference(kind: String)
        /// The name of the variable a `set` block writes.
        case variable
        case script
        case date(editor: SlotEditor, start: Date)
        case binding(output: String, current: String)
    }

    let id = UUID()
    var kind: Kind
    var blockID: String
    /// The slot name, or the output name for a binding.
    var slot: String
    /// Where the popover points, in canvas coordinates.
    var frame: CGRect
}

/// The popover behind dropdowns, reference pickers, variable and script pickers, and date/time pickers.
@MainActor
struct PickerPopover: View {
    enum Choice {
        case input(Input)
        case binding(String)
    }

    var request: PickerRequest
    var script: Script
    var document: Document
    var references: ReferenceProvider?
    var choose: (Choice) -> Void

    @State private var search = ""
    @State private var name = ""
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch request.kind {
            case .options(let options):
                rows(options.map { ($0, Choice.input(.literal(.text($0)))) })

            case .reference(let kind):
                TextField("Search \(kind)s", text: $search).textFieldStyle(.roundedBorder)
                let candidates = references?.candidates(kind: kind, matching: search) ?? []
                if candidates.isEmpty {
                    Text(references == nil ? "No picker is available for \(kind)s." : "Nothing found.")
                        .foregroundStyle(.secondary)
                }
                rows(candidates.map { ($0.label, Choice.input(.literal(.reference(Reference(kind: kind, id: $0.id))))) })

            case .variable:
                rows(script.variableNames.map { ($0, Choice.input(.literal(.text($0)))) })
                newName("New variable") { .input(.literal(.text($0))) }

            case .binding(let output, let current):
                Text("Store “\(output)” in").font(.caption).foregroundStyle(.secondary)
                rows(Array(Set(script.variableNames + [output])).sorted().map { ($0, Choice.binding($0)) })
                newName("New variable") { .binding($0) }
                if !current.isEmpty {
                    Divider()
                    Button("Don’t store it") { choose(.binding("")) }.buttonStyle(.plain).foregroundStyle(.red)
                }

            case .script:
                rows(document.scripts.map { ($0.name, Choice.input(.literal(.text($0.id)))) })

            case .date(let editor, let start):
                Group {
                    if editor == .time {
                        DatePicker("", selection: $date, displayedComponents: components(editor)).datePickerStyle(.stepperField)
                    } else {
                        DatePicker("", selection: $date, displayedComponents: components(editor)).datePickerStyle(.graphical)
                    }
                }
                .labelsHidden()
                .onAppear { date = start }
                HStack {
                    Spacer()
                    Button("Set") { choose(.input(SlotEditing.input(from: date, editor: editor))) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(10)
        .frame(minWidth: 180, maxWidth: 320)
    }

    private func components(_ editor: SlotEditor) -> DatePickerComponents {
        switch editor {
        case .date: return .date
        case .time: return .hourAndMinute
        default: return [.date, .hourAndMinute]
        }
    }

    private func rows(_ items: [(String, Choice)]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button {
                        choose(item.1)
                    } label: {
                        Text(item.0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func newName(_ prompt: String, _ make: @escaping (String) -> Choice) -> some View {
        HStack {
            TextField(prompt, text: $name).textFieldStyle(.roundedBorder).onSubmit { submit(make) }
            Button("Use") { submit(make) }.disabled(trimmedName.isEmpty)
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private func submit(_ make: (String) -> Choice) {
        if !trimmedName.isEmpty { choose(make(trimmedName)) }
    }
}

/// The form behind "Edit Script…": the entry block's data (name, parameters, declared outputs).
@MainActor
struct ScriptSettingsView: View {
    @State private var draft: Script
    private let referenceKinds: [String]
    private let canDelete: Bool
    private let done: (Script) -> Void
    private let delete: () -> Void

    init(script: Script, referenceKinds: [String], canDelete: Bool, done: @escaping (Script) -> Void, delete: @escaping () -> Void) {
        self._draft = State(initialValue: script)
        self.referenceKinds = referenceKinds
        self.canDelete = canDelete
        self.done = done
        self.delete = delete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder)
            section("Parameters", $draft.parameters, newName: "parameter")
            section("Outputs", $draft.outputs, newName: "output")
            HStack {
                if canDelete {
                    Button("Delete Script", role: .destructive, action: delete)
                }
                Spacer()
                Button("Done") { done(cleaned) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    /// Rows without a name are dropped; a reference without a kind gets the first known one.
    private var cleaned: Script {
        var script = draft
        script.name = draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : draft.name
        func clean(_ list: [Param]) -> [Param] {
            list.compactMap { item in
                var item = item
                item.name = item.name.trimmingCharacters(in: .whitespaces)
                if item.type != .reference { item.referenceKind = nil } else if item.referenceKind == nil {
                    item.referenceKind = referenceKinds.first ?? ""
                }
                return item.name.isEmpty ? nil : item
            }
        }
        script.parameters = clean(draft.parameters)
        script.outputs = clean(draft.outputs)
        return script
    }

    private func section(_ title: String, _ list: Binding<[Param]>, newName: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(list.wrappedValue.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("name", text: list[index].name).textFieldStyle(.roundedBorder)
                    Picker("", selection: list[index].type) {
                        ForEach(ValueType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 104)
                    if list.wrappedValue[index].type == .reference {
                        Picker("", selection: Binding(get: { list.wrappedValue[index].referenceKind ?? referenceKinds.first ?? "" },
                                                      set: { list.wrappedValue[index].referenceKind = $0 })) {
                            ForEach(referenceKinds, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                    Button {
                        list.wrappedValue.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                list.wrappedValue.append(Param(name: "", type: .text))
            } label: {
                Label("Add \(newName)", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
        }
    }
}
