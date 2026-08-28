import SwiftUI

struct CommentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(SessionModel.self) private var session
    let app: InteractiveApp
    @State private var draft = ""
    @State private var score = 5
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var commentIdempotencyKey: String?
    @State private var errorMessage: String?
    @State private var reportComment: AppComment?
    @State private var commentToDelete: AppComment?
    @State private var authorToBlock: String?
    @State private var pendingBlockAuthor: String?
    @State private var isCommunityGuidelinesPresented = false
    @State private var safetyError: String?
    @State private var requiresAuthentication = false
    @State private var pendingCommentIntent: PendingCommentIntent?
    @FocusState private var isCommentFieldFocused: Bool

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
                            ForEach(model.comments(for: app.id)) { comment in
                                CommentRow(
                                    comment: comment,
                                    isOwnComment: comment.author == (session.user?.username ?? model.creatorName),
                                    report: { reportComment = comment },
                                    block: { authorToBlock = comment.author },
                                    delete: { commentToDelete = comment },
                                    guidelines: { isCommunityGuidelinesPresented = true }
                                )
                            }
                            if model.canLoadMoreComments(for: app.id) {
                                Button(action: loadMoreComments) {
                                    Group {
                                        if model.isLoadingMoreComments(for: app.id) {
                                            ProgressView("Loading more comments…")
                                        } else {
                                            Label("Load more comments", systemImage: "arrow.down.circle")
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(model.isLoadingMoreComments(for: app.id))
                                .accessibilityIdentifier("community.comments.load-more")
                            }
                        }
                    }.padding(20)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(session.canPerformMemberActions ? "Your take" : "Draft your comment")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        ScorePicker(score: $score)
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField("Write a comment…", text: $draft, axis: .vertical)
                            .lineLimit(1...4).padding(11).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                            .focused($isCommentFieldFocused)
                            .accessibilityLabel("Write a comment")
                            .accessibilityIdentifier("community.comment.input")
                        Button(action: submit) {
                            Image(systemName: session.canPerformMemberActions ? "arrow.up" : "person.crop.circle.badge.plus")
                                .font(.headline)
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.pulseLime)
                        .foregroundStyle(.black)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                        .accessibilityLabel(session.canPerformMemberActions ? "Post comment" : "Sign in to post comment")
                        .accessibilityIdentifier("community.comment.submit")
                    }
                    if !session.canPerformMemberActions {
                        Text("Your draft stays on this screen until you sign in. It will not be posted automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(Color.pulseCoral) }
                }
                .padding(16)
            }
            .navigationTitle("Comments · \(app.comments)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task {
                do { try await model.loadComments(for: app.id); errorMessage = nil }
                catch { errorMessage = error.localizedDescription }
                isLoading = false
            }
            .onChange(of: draft) { _, _ in commentIdempotencyKey = nil }
            .onChange(of: score) { _, _ in commentIdempotencyKey = nil }
            .onChange(of: session.user?.id) { oldUserID, newUserID in
                // A member draft must never cross a sign-out or account switch.
                // The only exception is the anonymous intent currently returning
                // from this sheet's own authentication prompt.
                guard oldUserID != newUserID, pendingCommentIntent == nil else { return }
                draft = ""
                score = 5
                commentIdempotencyKey = nil
            }
            .sheet(item: $reportComment) { comment in
                ReportComposerSheet(targetType: "comment", targetID: comment.id.uuidString.lowercased(), targetTitle: "Comment by @\(comment.author)")
            }
            .sheet(isPresented: $requiresAuthentication) {
                AuthenticationRequiredView(title: "Join the conversation", detail: "Sign in to leave comments and manage safety controls across your devices.")
            }
            .sheet(isPresented: $isCommunityGuidelinesPresented) {
                CommunityGuidelinesSheet()
            }
            .confirmationDialog("Delete your comment?", isPresented: Binding(get: { commentToDelete != nil }, set: { if !$0 { commentToDelete = nil } }), titleVisibility: .visible) {
                Button("Delete comment", role: .destructive) { deleteComment() }
            } message: {
                Text("This removes the comment from other people’s Pulse surfaces. This action cannot be undone.")
            }
            .confirmationDialog("Block @\(authorToBlock ?? "this creator")?", isPresented: Binding(get: { authorToBlock != nil }, set: { if !$0 { authorToBlock = nil } }), titleVisibility: .visible) {
                Button("Block user", role: .destructive) { blockAuthor() }
            } message: {
                Text("Their works and comments will no longer appear for you.")
            }
            .alert("Couldn’t complete that safety action", isPresented: Binding(get: { safetyError != nil }, set: { if !$0 { safetyError = nil } })) {
                Button("OK", role: .cancel) { safetyError = nil }
            } message: {
                Text(safetyError ?? "Please try again.")
            }
            .onChange(of: session.canResumeMemberActions) { _, canResume in
                guard canResume else { return }
                if let intent = pendingCommentIntent, intent.workID == app.id {
                    draft = intent.body
                    score = intent.score
                    commentIdempotencyKey = intent.idempotencyKey
                    pendingCommentIntent = nil
                    requiresAuthentication = false
                }
                if let author = pendingBlockAuthor {
                    pendingBlockAuthor = nil
                    requiresAuthentication = false
                    authorToBlock = author
                }
            }
            .onChange(of: requiresAuthentication) { wasPresented, isPresented in
                if wasPresented, !isPresented, !session.canPerformMemberActions {
                    pendingBlockAuthor = nil
                }
            }
        }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSubmitting else { return }
        let idempotencyKey = commentIdempotencyKey ?? UUID().uuidString
        commentIdempotencyKey = idempotencyKey
        guard session.canPerformMemberActions else {
            pendingCommentIntent = PendingCommentIntent(
                workID: app.id,
                body: text,
                score: score,
                idempotencyKey: idempotencyKey
            )
            requiresAuthentication = true
            return
        }
        isSubmitting = true
        Task {
            do {
                try await model.addComment(to: app.id, body: text, score: score, idempotencyKey: idempotencyKey)
                if draft == text { draft = "" }
                commentIdempotencyKey = nil
                errorMessage = nil
            }
            catch {
                if let apiError = error as? PulseAPIError,
                   let validationMessage = apiError.validationMessage(for: ["body", "score"]) {
                    errorMessage = validationMessage
                    if apiError.hasValidationIssue(for: "body") { isCommentFieldFocused = true }
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            isSubmitting = false
        }
    }

    private func deleteComment() {
        guard let comment = commentToDelete else { return }
        commentToDelete = nil
        Task {
            do { try await model.deleteComment(from: app.id, commentID: comment.id) }
            catch { safetyError = error.localizedDescription }
        }
    }

    private func loadMoreComments() {
        guard !model.isLoadingMoreComments(for: app.id) else { return }
        Task {
            do {
                try await model.loadMoreComments(for: app.id)
                errorMessage = nil
            } catch {
                errorMessage = "Couldn’t load more comments. Your current discussion is still available."
            }
        }
    }

    private func blockAuthor() {
        guard let author = authorToBlock else { return }
        authorToBlock = nil
        guard session.canPerformMemberActions else {
            pendingBlockAuthor = author
            requiresAuthentication = true
            return
        }
        Task {
            do { try await model.block(username: author) }
            catch { safetyError = error.localizedDescription }
        }
    }
}

private struct CommentRow: View {
    let comment: AppComment
    let isOwnComment: Bool
    let report: () -> Void
    let block: () -> Void
    let delete: () -> Void
    let guidelines: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("@\(comment.author)").font(.subheadline.weight(.semibold))
                Spacer()
                Label("\(comment.score)", systemImage: "star.fill").font(.caption.weight(.bold)).foregroundStyle(.yellow)
                Menu {
                    if isOwnComment {
                        Button("Delete comment", systemImage: "trash", role: .destructive) { delete() }
                    } else {
                        Button("Report comment", systemImage: "flag") { report() }
                        Button("Block @\(comment.author)", systemImage: "hand.raised", role: .destructive) { block() }
                    }
                    Button("Community guidelines", systemImage: "checklist") { guidelines() }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 30)
                }
                .accessibilityLabel("Safety options for comment by @\(comment.author)")
            }
            if comment.isHiddenFromOthers {
                Label("Not visible to others", systemImage: "eye.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.pulseCoral)
                    .accessibilityHint("Your comment is not visible to other people in this conversation")
                    .accessibilityIdentifier("community.comment.hidden-status")
                Text("This comment is no longer visible in the conversation. It remains here only for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Review Community guidelines", systemImage: "checklist", action: guidelines)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .accessibilityHint("Opens the rules for participating safely in Pulse")
            }
            Text(comment.body).font(.subheadline).foregroundStyle(.primary.opacity(0.86))
        }
        .padding(14)
        .background(comment.isHiddenFromOthers ? Color.pulseCoral.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 17))
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct ScorePicker: View {
    @Binding var score: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { value in
                Button { score = value } label: { Image(systemName: value <= score ? "star.fill" : "star").foregroundStyle(value <= score ? .yellow : .secondary) }
                    .accessibilityLabel("Rate \(value) out of 5")
                    .accessibilityValue(value == score ? "Selected" : "Not selected")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your rating")
        .accessibilityValue("\(score) out of 5")
        .accessibilityHint("Choose a rating from 1 to 5 stars")
    }
}
