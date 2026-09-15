import SwiftUI
import CoreImage
import UIKit

/// Host controls stay outside generated code. A challenge cannot silently fall
/// back to a different artifact or an unseeded round when session creation fails.
struct PlayableWorkView: View {
    @Environment(AppModel.self) private var model
    let work: InteractiveApp
    let url: URL
    let isActive: Bool
    let accessibilityIdentifier: String
    let telemetryScreen: String
    var showsResultControls = true
    var onInteraction: (() -> Void)? = nil
    var incomingChallenge: PulseChallenge? = nil
    @State private var play = PulsePlayController()
    @State private var replayToken = UUID()
    @State private var sharing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if play.loading {
                ProgressView("Preparing play…").tint(.pulseLime).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            } else if incomingChallenge != nil && play.session == nil {
                ContentUnavailableView {
                    Label("Challenge unavailable", systemImage: "flag.slash")
                } description: { Text("This challenge may have expired or the work may have changed.") } actions: {
                    Button("Try again") { replayToken = UUID() }
                }
            } else {
                ArtifactPlayerView(url: url, isActive: isActive && !sharing,
                    title: work.title, interactionSummary: work.theme,
                    accessibilityIdentifier: accessibilityIdentifier, telemetryScreen: telemetryScreen,
                    playSeed: play.session?.seed,
                    onPlayMessage: { play.receive($0, api: model.api) },
                    onInteraction: onInteraction)
                    .id(play.session?.id ?? "untracked")
                if showsResultControls, let score = play.session?.score {
                    VStack(spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Your result: \(score)").font(.headline)
                                if let incomingChallenge { Text("Challenge score: \(incomingChallenge.score)").font(.caption) }
                            }
                            Spacer()
                            Button("Play again") { replayToken = UUID() }.buttonStyle(.bordered)
                            Button("Share result") {
                                Task {
                                    if play.challenge == nil { await play.retryChallenge(api: model.api) }
                                    sharing = play.challenge != nil
                                }
                            }.buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black)
                        }
                        if let error = play.error { Text(error).font(.caption).foregroundStyle(Color.pulseCoral) }
                    }.padding(14).background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 16)).padding(8)
                    .accessibilityIdentifier("play.result")
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if let incomingChallenge, play.session?.completed != true {
                Text("Same challenge · target \(incomingChallenge.score)")
                    .font(.caption.bold()).padding(8).background(.black.opacity(0.85), in: Capsule()).padding(8).allowsHitTesting(false)
            }
        }
        .task(id: replayToken) { await play.start(api: model.api, work: work, challengeID: incomingChallenge?.id) }
        .sheet(isPresented: $sharing) {
            if let challenge = play.challenge { ResultShareSheet(work: work, challenge: challenge) }
        }
    }
}

struct ResultShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let work: InteractiveApp
    let challenge: PulseChallenge
    @State private var image: Image?
    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("PULSE / SAME CHALLENGE").font(.caption.bold()).foregroundStyle(Color.pulseLime)
            Text(work.title).font(.title.bold()).lineLimit(3)
            Text("\(challenge.score)").font(.system(size: 68, weight: .heavy, design: .rounded))
            Text("Can you beat my score?").font(.headline)
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("by @\(work.creator)").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    Text("Scan to play this challenge").font(.caption).foregroundStyle(Color.pulseLime)
                }
                Spacer()
                if let qrImage { Image(uiImage: qrImage).interpolation(.none).resizable().frame(width: 86, height: 86).padding(6).background(.white) }
            }
            Text("Player-reported score · same version & seed").font(.caption2).foregroundStyle(.white.opacity(0.6))
        }.padding(28).frame(width: 330, alignment: .leading).foregroundStyle(.white).background(Color(red: 0.05, green: 0.06, blue: 0.06))
    }
    private var qrImage: UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(challenge.url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    resultCard.clipShape(RoundedRectangle(cornerRadius: 22))
                    ShareLink(item: challenge.url, message: Text("I scored \(challenge.score) in \(work.title). Play the same challenge!")) {
                        Label("Share challenge link", systemImage: "square.and.arrow.up")
                    }.buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black)
                    if let image {
                        ShareLink(item: image, preview: SharePreview("\(work.title) · \(challenge.score)", image: image)) { Label("Share result card", systemImage: "photo") }
                            .buttonStyle(.bordered)
                    }
                    Text("The link opens the same published version and seed. It expires in 30 days or when this version becomes unavailable.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("Your result")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
                .task { let renderer = ImageRenderer(content: resultCard); renderer.scale = 2; if let rendered = renderer.uiImage { image = Image(uiImage: rendered) } }
        }
    }
}
