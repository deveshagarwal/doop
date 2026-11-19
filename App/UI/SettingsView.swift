import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var claudeKey = ""
    @State private var maxHR = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Apple Health", value: model.hasAppleHealthData ? "Connected" : "Not connected")
                    if !model.hasAppleHealthData {
                        Button("Connect Apple Health") { Task { await model.connectAppleHealth() } }
                    }
                    LabeledContent("Newest heart rate", value: Fmt.relative(model.snapshot.newestSample["appleHealth"]))
                    LabeledContent("Last sync", value: Fmt.relative(model.snapshot.lastSync["appleHealth"]))
                    Button(model.syncing ? "Syncing…" : "Sync now") { Task { await model.sync() } }.disabled(model.syncing)
                } header: { Text("Data") } footer: {
                    Text("In the Google Health app turn on Connections → Apps and services → Apple Health. \"Newest heart rate\" shows how far behind the band → Google Health → Apple Health chain is running.")
                }

                Section {
                    if model.isGoogleConnected {
                        LabeledContent("Status", value: "Connected")
                        LabeledContent("Newest HRV night", value: Fmt.relative(model.snapshot.newestSample["google"]))
                        Button("Reconnect") { Task { await model.connectGoogle(clientID: model.settings.googleClientID) } }
                        Button("Disconnect", role: .destructive) { model.disconnectGoogle() }
                    } else {
                        TextField("iOS client ID (…apps.googleusercontent.com)", text: $clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote)
                        Button("Connect Google Health") { Task { await model.connectGoogle(clientID: clientID) } }
                            .disabled(clientID.isEmpty)
                    }
                } header: { Text("HRV via Google Health (optional)") } footer: {
                    Text("Apple Health doesn't receive HRV from Fitbit, and HRV is the biggest input to recovery. One-time setup: create a Google Cloud project, enable the Google Health API, add yourself as a test user, add the three googlehealth read scopes, and create an iOS OAuth client with this app's bundle ID. See SETUP.md. Google expires personal-app sign-ins every 7 days, so you'll tap Reconnect weekly.")
                }

                Section {
                    SecureField(model.hasClaudeKey ? "Key saved. Paste to replace" : "sk-ant-…", text: $claudeKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save key") { model.setClaudeKey(claudeKey); claudeKey = "" }.disabled(claudeKey.isEmpty)
                    if model.hasClaudeKey { Button("Remove key", role: .destructive) { model.setClaudeKey("") } }
                } header: { Text("Coach (Claude)") } footer: {
                    Text("Stored in the Keychain. Only summarized daily numbers are sent, and only when you ask the coach something. Uses \(ClaudeClient.model).")
                }

                Section("Profile") {
                    Stepper("Age \(model.settings.age)", value: Binding(get: { model.settings.age }, set: { v in model.updateSettings { $0.age = v } }), in: 14...90)
                    Picker("Sex", selection: Binding(get: { model.settings.sex }, set: { v in model.updateSettings { $0.sex = v } })) {
                        Text("Male").tag(BiologicalSex.male)
                        Text("Female").tag(BiologicalSex.female)
                        Text("Unspecified").tag(BiologicalSex.unspecified)
                    }
                    HStack {
                        Text("Max HR")
                        TextField("\(Int(model.settings.maxHR)) (estimated)", text: $maxHR)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .onSubmit { model.updateSettings { $0.maxHROverride = Double(maxHR) } }
                    }
                    Stepper(String(format: "Base sleep need %.1fh", model.settings.baseSleepNeedHours),
                            value: Binding(get: { model.settings.baseSleepNeedHours }, set: { v in model.updateSettings { $0.baseSleepNeedHours = v } }),
                            in: 6...10, step: 0.25)
                }

                Section("Notifications") {
                    Toggle("Illness alerts", isOn: Binding(get: { model.settings.notifyIllness }, set: { v in model.updateSettings { $0.notifyIllness = v } }))
                    Toggle("Morning recovery", isOn: Binding(get: { model.settings.notifyRecovery }, set: { v in model.updateSettings { $0.notifyRecovery = v } }))
                }

                Section {
                    Toggle("Demo mode", isOn: Binding(get: { model.settings.demoMode }, set: { v in model.updateSettings { $0.demoMode = v } }))
                } footer: { Text("90 days of generated data so you can explore every screen. Your real data is untouched.") }

                if !model.syncLog.isEmpty {
                    Section("Last sync log") {
                        ForEach(model.syncLog) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(e.source) · \(e.metric)").font(.caption.weight(.semibold))
                                Text(e.detail).font(.caption2).foregroundStyle(e.isError ? Theme.red : Theme.secondary)
                            }
                        }
                    }
                }

                Section {
                    Text("Not a medical device. Scores are estimates from published methods, scored against your own baselines. Google Health API code adapted from Pulse (Apache 2.0).")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { maxHR = model.settings.maxHROverride.map { "\(Int($0))" } ?? "" }
        }
        .preferredColorScheme(.dark)
    }
}
