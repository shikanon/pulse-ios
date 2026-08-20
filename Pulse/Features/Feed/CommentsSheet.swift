import SwiftUI

struct CommentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let app: InteractiveApp
    @State private var draft = ""
    @State private var score = 5
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("What people are saying").font(.headline)
                        if isLoading {
                            ProgressView("Loading comments…").frame(maxWidth: .infinity).padding(.vertical, 36)
                        } else if model.comments(for: app.id).isEmpty {
                            ContentUnavailableView("Be the first to comment", systemImage: "bubble.right", description: Text("Leave a note or a score for this interactive app."))
                                .frame(maxWidth: .infinity).padding(.vertical, 36)
                        } else {
                            ForEach(model.comments(for: app.id)) { comment in CommentRow(comment: comment) }
                        }
                    }.padding(20)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Your take").font(.subheadline.weight(.semibold))
                        Spacer()
                        ScorePicker(score: $score)
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField("Write a comment…", text: $draft, axis: .vertical)
                            .lineLimit(1...4).padding(11).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                        Button(action: submit) { Image(systemName: "arrow.up").font(.headline).frame(width: 40, height: 40) }
                            .buttonStyle(.borderedProminent).tint(.pulseLime).foregroundStyle(.black).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                    }
                    if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(Color.pulseCoral) }
                }.padding(16)
            }
            .navigationTitle("Comments · \(app.comments)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task {
                do { try await model.loadComments(for: app.id); errorMessage = nil }
                catch { errorMessage = error.localizedDescription }
                isLoading = false
            }
        }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        Task {
            do { try await model.addComment(to: app.id, body: text, score: score); draft = ""; errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
            isSubmitting = false
        }
    }
}

private struct CommentRow: View {
    let comment: AppComment
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text("@\(comment.author)").font(.subheadline.weight(.semibold)); Spacer(); Label("\(comment.score)", systemImage: "star.fill").font(.caption.weight(.bold)).foregroundStyle(.yellow) }
            Text(comment.body).font(.subheadline).foregroundStyle(.primary.opacity(0.86))
        }.padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct ScorePicker: View {
    @Binding var score: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                Button { score = value } label: { Image(systemName: value <= score ? "star.fill" : "star").foregroundStyle(value <= score ? .yellow : .secondary) }
                    .accessibilityLabel("Rate \(value) out of 5")
            }
        }
    }
}
