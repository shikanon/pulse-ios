import SwiftUI

struct SaveWorkButton: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionModel.self) private var session
    let work: InteractiveApp
    @State private var signingIn = false
    @State private var saving = false
    @State private var error: String?
    private var saved: Bool { model.savedWorks.contains { $0.id == work.id } }
    var body: some View {
        Button {
            guard session.canPerformMemberActions else { signingIn = true; return }
            saving = true
            Task { do { try await model.toggleSaved(work) } catch { self.error = "Couldn’t update your saved works. Please try again." }; saving = false }
        } label: {
            Image(systemName: saved ? "bookmark.fill" : "bookmark").foregroundStyle(saved ? Color.pulseLime : .white).frame(minWidth: 44, minHeight: 44)
        }.disabled(saving || model.isOfflineReadOnly)
            .accessibilityLabel(saved ? "Remove from saved" : "Save this work")
            .accessibilityIdentifier("work.save")
            .sheet(isPresented: $signingIn) { AuthenticationRequiredView(title: "Save works to play again", detail: "Sign in to keep your saved works across devices.") }
            .onChange(of: session.canResumeMemberActions) { _, canResume in
                if canResume && signingIn { signingIn = false; Task { do { try await model.toggleSaved(work) } catch { self.error = "Couldn’t save this work." } } }
            }
            .alert("Saved works", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}
struct PlayCollectionView: View {
    @Environment(AppModel.self) private var model
    @State private var kind = "saved"
    var body: some View {
        VStack {
            Picker("Your play library", selection: $kind) { Text("Saved").tag("saved"); Text("Recently played").tag("recent") }.pickerStyle(.segmented).padding()
            if let error = model.collectionError {
                ContentUnavailableView { Label("Library unavailable", systemImage: "wifi.exclamationmark") } description: { Text(error) } actions: { Button("Try again") { Task { await model.loadCollections() } } }
            } else if works.isEmpty {
                ContentUnavailableView(kind == "saved" ? "Save something worth replaying" : "Your next favorite starts here", systemImage: "bookmark", description: Text(kind == "saved" ? "Tap the bookmark on a work to find it here." : "Works appear after a completed round or 20 seconds of active play."))
            } else {
                List(works) { work in
                    HStack {
                        Button {
                            guard let slug = work.publicSlug else { return }
                            model.queueDeepLink(.publicWork(slug: slug))
                            Task { await model.resolvePendingDeepLink() }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(work.title).font(.headline)
                                Text("@\(work.creator) · \(work.theme)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        }.buttonStyle(.plain).accessibilityLabel("Play \(work.title)")
                        SaveWorkButton(work: work).buttonStyle(.borderless)
                    }
                }.listStyle(.plain).refreshable { await model.loadCollections() }
            }
        }.navigationTitle("Play again").task { await model.loadCollections() }
    }
    private var works: [InteractiveApp] { kind == "recent" ? model.recentWorks : model.savedWorks }
}

struct GrowthConsentControl: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PulseGrowthPreferences.consentKey) private var consent = false
    @State private var pending = false
    @State private var error: String?
    var body: some View {
        Menu {
            Button(consent ? "Stop usage analytics & erase activity" : "Allow usage analytics") {
                if consent {
                    let identity = PulseGrowthPreferences.identity
                    pending = true
                    Task {
                        do {
                            try await model.api.forgetGrowth(identity)
                            consent = false
                            UserDefaults.standard.removeObject(forKey: PulseGrowthPreferences.deviceKey)
                        } catch { self.error = "Couldn’t erase activity yet. Please retry when connected." }
                        pending = false
                    }
                } else {
                    consent = true
                    Task { await model.api.growthVisit() }
                }
            }.disabled(pending)
            Text("Optional first-party visits and play activity measure DAU and return visits. No advertising ID. Account and device audiences stay separate.")
        } label: { Image(systemName: consent ? "chart.bar.fill" : "chart.bar").frame(width: 44, height: 40) }
            .accessibilityLabel("Usage analytics: \(consent ? "on" : "off")")
            .alert("Usage analytics", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}
