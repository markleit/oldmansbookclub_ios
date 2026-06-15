import SwiftUI
import SafariServices
import Speech
import AVFoundation

// Admin / club-admin feedback: submit (with optional voice dictation) and browse
// existing items, backed by GitHub issues via our API.
struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [APIClient.FeedbackDto] = []
    @State private var state = "open"          // "open" | "closed"
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCompose = false
    @State private var safariItem: SafariItem?
    @State private var showSubmittedToast = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Button {
                    showCompose = true
                } label: {
                    Label("Submit Feedback", systemImage: "plus.circle.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .padding([.horizontal, .top])

                Picker("", selection: $state) {
                    Text("Open").tag("open")
                    Text("Resolved").tag("closed")
                }
                .pickerStyle(.segmented)
                .padding()

                List {
                    if isLoading && items.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .listRowSeparator(.hidden)
                    } else if items.isEmpty {
                        Text(state == "open" ? "No open feedback." : "No resolved feedback.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(items) { item in
                            Button {
                                if let url = URL(string: item.htmlUrl) { safariItem = SafariItem(url: url) }
                            } label: {
                                row(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await load() }
            }
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task(id: state) { await load() }
            .sheet(isPresented: $showCompose) {
                FeedbackComposeView { created in
                    // Optimistic insert — GitHub's filtered list lags a second or two
                    // after creation, so a refetch right now would miss it. Show the
                    // returned item immediately; pull-to-refresh reconciles later.
                    if state == "open", !items.contains(where: { $0.number == created.number }) {
                        items.insert(created, at: 0)
                    }
                    withAnimation { showSubmittedToast = true }
                }
            }
            .sheet(item: $safariItem) { SafariView(url: $0.url) }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .overlay(alignment: .top) {
                if showSubmittedToast {
                    Label("Feedback submitted", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.green, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation { showSubmittedToast = false }
                        }
                }
            }
        }
    }

    private func row(_ item: APIClient.FeedbackDto) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.state == "closed" ? "checkmark.circle.fill" : "circle")
                .foregroundColor(item.state == "closed" ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline).lineLimit(2)
                Text("#\(item.number) · \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { items = try await APIClient.shared.getFeedback(state: state) }
        catch { errorMessage = "Couldn't load feedback." }
    }
}

struct FeedbackComposeView: View {
    let onSubmitted: (APIClient.FeedbackDto) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var text = ""
    @State private var isRecording = false
    @State private var isTranscribing = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var recorder = AudioRecorder()

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !text.trimmingCharacters(in: .whitespaces).isEmpty
            && !isSubmitting && !isRecording && !isTranscribing
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Short summary", text: $title)
                }
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                    HStack(spacing: 8) {
                        Button {
                            Task { await toggleRecording() }
                        } label: {
                            Label(isRecording ? "Stop" : "Dictate",
                                  systemImage: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        }
                        .disabled(isTranscribing || isSubmitting)
                        if isTranscribing {
                            ProgressView()
                            Text("Transcribing…").font(.caption).foregroundColor(.secondary)
                        } else if isRecording {
                            Text("Recording…").font(.caption).foregroundColor(.red)
                        }
                    }
                } header: {
                    Text("Description")
                } footer: {
                    Text("Type, or tap Dictate to record and transcribe your description.")
                }
            }
            .navigationTitle("New Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting { ProgressView() }
                    else { Button("Submit") { Task { await submit() } }.disabled(!canSubmit) }
                }
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func toggleRecording() async {
        if isRecording {
            isRecording = false
            guard let (url, _) = recorder.stop() else { return }
            await transcribe(url)
            return
        }
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { c in
                AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
            }
        }
        guard granted else { errorMessage = "Microphone access is needed to dictate."; return }
        do { try recorder.start(); isRecording = true }
        catch { errorMessage = "Couldn't start recording." }
    }

    private func transcribe(_ url: URL) async {
        isTranscribing = true
        defer { isTranscribing = false; try? FileManager.default.removeItem(at: url) }

        let status = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized, let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            errorMessage = "Speech recognition is unavailable."; return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        let result = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error { finished = true; cont.resume(throwing: error) }
                else if let result, result.isFinal { finished = true; cont.resume(returning: result) }
            }
        }
        if let t = result?.bestTranscription.formattedString, !t.isEmpty {
            await MainActor.run {
                text = text.isEmpty ? t : text + " " + t
                // Auto-fill the title from the dictation if the user hasn't typed one.
                if title.trimmingCharacters(in: .whitespaces).isEmpty {
                    title = Self.deriveTitle(from: t)
                }
            }
        }
    }

    // A concise title from dictated text: the first sentence, capped (word-aware) to
    // a reasonable length. The user can still edit it.
    private static func deriveTitle(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSentence = trimmed.split(whereSeparator: { ".!?".contains($0) })
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? trimmed
        let maxLen = 60
        guard firstSentence.count > maxLen else { return firstSentence }
        let prefix = firstSentence.prefix(maxLen)
        let clipped = prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? String(prefix)
        return clipped + "…"
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        do {
            let created = try await APIClient.shared.submitFeedback(
                title: title.trimmingCharacters(in: .whitespaces),
                body: text.trimmingCharacters(in: .whitespaces),
                appVersion: "\(short) (\(build))")
            await onSubmitted(created)
            dismiss()
        } catch {
            errorMessage = "Couldn't submit feedback. Please try again."
        }
    }
}

struct SafariItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
