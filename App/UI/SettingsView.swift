import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var maxHR = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    source("Apple Health", model.hasAppleHealthData, detail: "newest " + Fmt.relative(model.snapshot.newestSample["appleHealth"]))
                    if !model.hasAppleHealthData { Button("Connect Apple Health") { Task { await model.connectAppleHealth() } } }
                    source("Omada weight", model.snapshot.newestSample["weight"] != nil, detail: model.snapshot.newestSample["weight"].map { "last " + Fmt.relative($0) } ?? "via Apple Health")
                    source("Meals", model.hasMealData, detail: model.snapshot.newestSample["meals"].map { "last " + Fmt.relative($0) } ?? "optional · any food app that writes to Apple Health")
                    source("Calendar", model.calendarConnected, detail: model.calendarConnected ? "late meetings, busy days" : "")
                    if !model.calendarConnected { Button("Connect Calendar") { Task { await model.connectCalendar() } } }
                    source("Weather", model.weather.status == .authorizedWhenInUse, detail: "hot nights · approximate location")
                    if model.weather.status != .authorizedWhenInUse { Button("Allow approximate location") { model.connectWeather() } }
                    Button(model.syncing ? "Syncing…" : "Sync now") { Task { await model.sync() } }.disabled(model.syncing)
                } header: { Text("Sources") } footer: {
                    Text("Everything is read-only and stays on this phone. Omada and food apps arrive through Apple Health: in Omada, Settings → Health Integration → Share with Health App. In Google Health: Connections → Apps and services → Apple Health.")
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
                        Button("Connect Google Health") { Task { await model.connectGoogle(clientID: clientID) } }.disabled(clientID.isEmpty)
                    }
                } header: { Text("HRV via Google Health (optional)") } footer: {
                    Text("Apple Health doesn't receive HRV from Fitbit, and HRV is the biggest input to recovery. One-time setup is in SETUP.md. If Google ever ends the sign-in, DOOP opens the renewal by itself the next time you open the app.")
                }

                Section {
                    if let f = model.analysis.forecast {
                        LabeledContent("Trained on", value: "\(f.trainedOn) nights")
                        LabeledContent("Forecast error", value: String(format: "±%.1f points", f.backtestError))
                        LabeledContent("vs. \"same as today\"", value: String(format: "%.0f%% better", f.beatsNaiveBy * 100))
                    } else {
                        Text("The forecast trains after about 3 weeks of nights.").foregroundStyle(.secondary)
                    }
                    LabeledContent("Last run", value: model.analysis.computedAt.formatted(date: .omitted, time: .shortened))
                } header: { Text("On-device models") } footer: {
                    Text("Every model trains and runs on this phone whenever new data arrives. The error is measured by predicting each recent day from only the days before it. On 51 people in the LifeSnaps research dataset the same forecast was ±9.9 points, 21% better than \"same as today\".")
                }

                Section("Profile") {
                    Stepper("Age \(model.settings.age)", value: Binding(get: { model.settings.age }, set: { v in model.updateSettings { $0.age = v } }), in: 14...90)
                    Picker("Sex", selection: Binding(get: { model.settings.sex }, set: { v in model.updateSettings { $0.sex = v } })) {
                        Text("Male").tag(BiologicalSex.male); Text("Female").tag(BiologicalSex.female); Text("Unspecified").tag(BiologicalSex.unspecified)
                    }
                    HStack {
                        Text("Max HR")
                        TextField("\(Int(model.settings.maxHR)) (estimated)", text: $maxHR).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .onSubmit { model.updateSettings { $0.maxHROverride = Double(maxHR) } }
                    }
                    Picker("Height", selection: Binding(get: { model.settings.heightCm.map { ($0 / 2.54 * 2).rounded() / 2 } ?? 0 },
                                                        set: { v in model.updateSettings { $0.heightCm = v == 0 ? nil : v * 2.54 } })) {
                        Text("Not set").tag(0.0)
                        ForEach(Array(stride(from: 54.0, through: 84.0, by: 0.5)), id: \.self) { inches in
                            Text("\(Int(inches) / 12)′ \(String(format: "%g", inches.truncatingRemainder(dividingBy: 12)))″").tag(inches)
                        }
                    }
                    Picker("Weight goal", selection: Binding(get: { model.settings.goalRateKgPerWeek ?? 0 }, set: { v in model.updateSettings { $0.goalRateKgPerWeek = v == 0 ? nil : v } })) {
                        ForEach([-1.0, -0.75, -0.5, -0.25, 0, 0.25], id: \.self) { r in
                            Text(r == 0 ? "No target" : String(format: "%+.2g kg/week", r)).tag(r)
                        }
                    }
                    Stepper(String(format: "Base sleep need %.1fh", model.settings.baseSleepNeedHours),
                            value: Binding(get: { model.settings.baseSleepNeedHours }, set: { v in model.updateSettings { $0.baseSleepNeedHours = v } }), in: 6...10, step: 0.25)
                }

                Section("Notifications") {
                    Toggle("Morning recovery + one question", isOn: Binding(get: { model.settings.notifyRecovery }, set: { v in model.updateSettings { $0.notifyRecovery = v } }))
                    Toggle("Illness watch", isOn: Binding(get: { model.settings.notifyIllness }, set: { v in model.updateSettings { $0.notifyIllness = v } }))
                    Toggle("Bedtime nudge", isOn: Binding(get: { model.settings.notifyBedtime }, set: { v in model.updateSettings { $0.notifyBedtime = v } }))
                }

                Section {
                    Toggle("Demo mode", isOn: Binding(get: { model.settings.demoMode }, set: { v in model.updateSettings { $0.demoMode = v } }))
                } footer: { Text("90 days of generated data so you can explore every screen. Your real data is untouched.") }

                if !model.syncLog.isEmpty {
                    Section("Last sync") {
                        ForEach(model.syncLog) { e in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(e.source) · \(e.metric)").font(.caption.weight(.semibold))
                                Text(e.detail).font(.caption2).foregroundStyle(e.isError ? Ember.ember : .secondary)
                            }
                        }
                    }
                }

                Section {
                    Text("Unofficial parody, not affiliated with or endorsed by WHOOP, Inc., Google, Fitbit or Apple. Not a medical device. Scores are estimates from published methods, scored against your own baselines. Google Health API code adapted from Pulse (Apache 2.0).").font(.caption).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Ember.ink)
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                maxHR = model.settings.maxHROverride.map { "\(Int($0))" } ?? ""
                clientID = model.settings.googleClientID
            }
        }
        .preferredColorScheme(.dark)
        .tint(Ember.ember)
    }

    private func source(_ name: String, _ on: Bool, detail: String) -> some View {
        HStack {
            Circle().fill(on ? Ember.ember : Ember.bone3).frame(width: 7, height: 7).shadow(color: on ? Ember.ember : .clear, radius: 3)
            Text(name)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
