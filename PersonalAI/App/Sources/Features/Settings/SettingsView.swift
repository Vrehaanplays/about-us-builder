import SwiftUI
import PersonalAICore

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var p
    @State private var ledger: [NetworkLedgerEntry] = []

    var body: some View {
        @Bindable var s = app.settings
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Privacy & settings")
                    guarantee
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Chat").font(PBFont.section)
                        Toggle("Use my history and notes in answers", isOn: $s.useArchiveInChat).font(PBFont.body)
                        Toggle("Show where answers come from", isOn: $s.showRetrievalDetails).font(PBFont.body)
                        Toggle("Learn notes from my conversations", isOn: $s.learnMemoriesAutomatically).font(PBFont.body)
                        Text("Only things you state are saved, always with your exact words as proof. You can correct or delete any note.").font(PBFont.meta).foregroundStyle(p.sub)
                        VStack(alignment: .leading) {
                            Text("Context size").font(PBFont.bodyHeavy)
                            Picker("Context size", selection: $s.contextCap) {
                                Text("Auto").tag(0); Text("4k").tag(4096); Text("8k").tag(8192); Text("16k").tag(16_384); Text("32k").tag(32_768)
                            }.pickerStyle(.segmented)
                            Text(s.contextCap == 0 ? "Auto picks the largest size that fits memory, battery and heat for each question." : "A ceiling. The app may still use less when memory is tight.").font(PBFont.meta).foregroundStyle(p.sub)
                        }
                        VStack(alignment: .leading) {
                            Text("Creativity \(String(format: "%.1f", s.temperature))").font(PBFont.bodyHeavy)
                            Slider(value: $s.temperature, in: 0...1.2, step: 0.1)
                        }
                    }.card()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Background work").font(PBFont.section)
                        Toggle("Index only while charging", isOn: $s.indexOnlyWhileCharging).font(PBFont.body)
                            .onChange(of: s.indexOnlyWhileCharging) { _, v in app.gate.update(onlyCharging: v) }
                        Toggle("Load the last model at launch", isOn: $s.autoLoadModelOnLaunch).font(PBFont.body)
                    }.card()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Network").font(PBFont.section)
                        Toggle("Allow downloading models", isOn: $s.allowModelDownloads).font(PBFont.body)
                        Text("Downloads contact huggingface.co only, to fetch model files. No message, note, photo or file name is ever included in a request.").font(PBFont.meta).foregroundStyle(p.sub)
                        HStack { Text("Remote AI processing").font(PBFont.bodyHeavy); Spacer(); Sticker(text: "Not in this build", tilt: 3, fill: PB.violet) }
                        Text("There is no cloud option. If one is ever added it will be off by default, labelled on every answer, and need your explicit approval.").font(PBFont.meta).foregroundStyle(p.sub)
                    }.card()
                    ledgerCard
                    about
                }
                .padding(.horizontal, PB.margin).padding(.top, 8).padding(.bottom, 32)
            }
            .scene().toolbar(.hidden, for: .navigationBar)
            .onAppear { ledger = NetworkLedger.shared.all.reversed() }
        }
    }

    private var guarantee: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your conversations never leave this iPhone.").font(PBFont.heavy(24, relativeTo: .title2))
            Text("Answers, search, memory and photo reading all run on this device. The only network traffic is downloading model files, listed below.").font(PBFont.body)
        }
        .foregroundStyle(PB.ink).frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(PB.lime))
    }

    private var ledgerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Every network request this session").font(PBFont.section)
            if ledger.isEmpty { Text("None so far.").font(PBFont.body).foregroundStyle(p.sub) }
            ForEach(ledger.prefix(30)) { e in
                HStack(alignment: .top) {
                    VStack(alignment: .leading) { Text(e.host).font(PBFont.bodyHeavy); Text(e.purpose).font(PBFont.meta).foregroundStyle(p.sub).lineLimit(2) }
                    Spacer()
                    Text(e.at.formatted(date: .omitted, time: .shortened)).font(PBFont.meta).foregroundStyle(p.sub)
                }
            }
            Button { ledger = NetworkLedger.shared.all.reversed() } label: { Text("Refresh") }.font(PBFont.meta).underline()
        }.frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About this build").font(PBFont.section)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")) · \(DeviceInfo.machine) · iOS \(DeviceInfo.osVersion)").font(PBFont.meta).foregroundStyle(p.sub)
            Text("Speed and memory figures are measured on your device in Models → Measure this iPhone. Typefaces: Bricolage Grotesque (SIL OFL).").font(PBFont.meta).foregroundStyle(p.sub)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
