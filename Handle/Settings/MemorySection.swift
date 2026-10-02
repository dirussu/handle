import SwiftUI
import AppKit

/// The memory inspector — every remembered fact, add/delete/wipe. Facts enter
/// memory only explicitly (chat "remember that…" or the field here), so this
/// list IS the whole memory: nothing hidden, nothing model-extracted.
struct MemorySection: View {
    @State private var facts: [MemoryFact] = []
    @State private var draft = ""
    @State private var confirmWipe = false

    var body: some View {
        Section {
            if facts.isEmpty {
                SettingsEmptyState(
                    icon: "brain",
                    title: "Nothing remembered yet",
                    hint: "Say \u{201C}remember that \u{2026}\u{201D} in chat, or add a fact below.")
            } else {
                ForEach(facts) { fact in
                    HStack(spacing: 8) {
                        Text(fact.content)
                            .font(.body)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            Task {
                                await MemoryStore.shared.delete(id: fact.id)
                                await reload()
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .handleIconHover()
                        .help("Forget this")
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Add a fact", text: $draft, prompt: Text("Add a fact, e.g. Mary = mary@acme.com"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()   // placeholder INSIDE the field, not a wrapping left label
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(.handleSolid)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !facts.isEmpty {
                Button(confirmWipe ? "Really forget everything? Click again" : "Forget All") {
                    if confirmWipe {
                        Task {
                            await MemoryStore.shared.wipe()
                            confirmWipe = false
                            await reload()
                        }
                    } else {
                        confirmWipe = true
                    }
                }
                .buttonStyle(.handleSolid)
                .tint(confirmWipe ? .red : nil)
            }
        } header: {
            SettingsHeader(icon: "brain", title: "Memory")
        } footer: {
            Text("Stored locally in memory.db — relevant facts join each turn's prompt, nothing leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await reload() }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            _ = await MemoryStore.shared.remember(text)
            draft = ""
            await reload()
        }
    }

    private func reload() async {
        facts = await MemoryStore.shared.all()
    }
}
