import Foundation

/// #204 PR 10 — sends the share sheet's messages the way the app sends its own. Each is written to
/// the shared inbox (the app takes it into its outbox and sees it through) and its upload handed to
/// iOS's background transfer — so the sheet closes at once, and the message goes even if the phone
/// locks or the app is never opened. It used to upload with the sheet up, and a dropped connection
/// meant a "try again" the user had to wait for.
enum ShareSender {
    static func send(_ steps: [SharePlan.Step], photos: [Data], to book: ShareBook, api: ShareAPI) async {
        guard let inbox = ShareInbox.defaultDirectory() else { return }

        // The plan's order is the tap order (a caption first, then each photo), a millisecond apart.
        let tapped = Date()
        var entries: [ShareInbox.Entry] = []
        for (index, step) in steps.enumerated() {
            let sentAt = tapped.addingTimeInterval(Double(index) / 1000)
            let saved: ShareInbox.Entry?
            switch step {
            case .text(let body):
                saved = try? ShareInbox.add(.init(id: UUID(), bookId: book.id, clubId: book.clubId, kind: .text,
                                                  sentAt: sentAt, body: body), photo: nil, in: inbox)
            case .photo(let n):
                saved = try? ShareInbox.add(.init(id: UUID(), bookId: book.id, clubId: book.clubId, kind: .photo,
                                                  sentAt: sentAt), photo: photos[n], in: inbox)
            }
            if let saved { entries.append(saved) }
        }

        // Without a token right now (it needs refreshing and there's no signal) they stay in the
        // inbox unhanded: the app sends them when it next runs.
        guard let token = try? await api.signIn.accessToken() else { return }
        let config = URLSessionConfiguration.background(withIdentifier: ShareInbox.sessionIdentifier)
        config.sharedContainerIdentifier = SharedContainer.appGroupId
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true   // the app hears the results
        let session = URLSession(configuration: config)
        for var entry in entries {
            guard let built = try? ShareInbox.request(for: entry, in: inbox, baseURL: api.baseURL, token: token,
                                                      deviceId: api.deviceToken) else { continue }
            let task = session.uploadTask(with: built.request, fromFile: built.bodyFile)
            task.taskDescription = ShareInbox.taskDescription(for: entry)
            task.resume()
            entry.handedToIOS = true
            try? ShareInbox.save(entry, in: inbox)
        }
    }
}
