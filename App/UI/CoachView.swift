import SwiftUI

struct CoachView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var showSettings = false
    @FocusState private var focused: Bool

    private let suggestions = [
        CoachContext.morningBriefPrompt,
        "Why was my recovery low today?",
        "Should I train hard today or take it easy?",
        "What's hurting my sleep the most lately?",
        "Am I getting sick?",
        "Plan my training for the next 7 days.",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.hasClaudeKey {
                    EmptyState(symbol: "key", title: "Add your Claude API key",
                               message: "The coach uses Claude. Your key stays in this phone's Keychain, and only summarized numbers are sent when you ask something.")
                    Button("Open Settings") { showSettings = true }.buttonStyle(.borderedProminent).tint(Theme.green)
                    Spacer()
                } else {
                    messages
                    composer
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Coach")
            .toolbar {
                if !model.chat.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { Button("Clear") { model.clearChat() }.disabled(model.coachStreaming) }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.chat.isEmpty {
                        Text("Ask anything about your recovery, sleep or training. The coach sees your last two weeks, your baselines and your journal patterns.")
                            .font(.subheadline).foregroundStyle(Theme.secondary).padding(.bottom, 4)
                        ForEach(suggestions, id: \.self) { s in
                            Button { send(s) } label: {
                                Text(s).font(.subheadline).multilineTextAlignment(.leading)
                                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    ForEach(model.chat) { m in Bubble(message: m, streaming: model.coachStreaming && m.id == model.chat.last?.id).id(m.id) }
                }
                .padding(16)
            }
            .onChange(of: model.chat.last?.text) { _, _ in
                if let id = model.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask your coach", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
            Button { send(input) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || model.coachStreaming)
            .tint(Theme.green)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.background)
    }

    private func send(_ text: String) {
        input = ""
        focused = false
        Task { await model.ask(text) }
    }
}

struct Bubble: View {
    let message: ChatMessage
    let streaming: Bool

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Group {
                if message.text.isEmpty && streaming {
                    ProgressView().controlSize(.small).padding(6)
                } else {
                    Text(LocalizedStringKey(message.text)).textSelection(.enabled)
                }
            }
            .font(.subheadline)
            .padding(12)
            .background(message.role == .user ? Theme.green.opacity(0.22) : Theme.card, in: RoundedRectangle(cornerRadius: 16))
            if message.role == .assistant { Spacer(minLength: 20) }
        }
    }
}
