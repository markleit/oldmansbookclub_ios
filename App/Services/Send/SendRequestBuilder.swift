import Foundation

// #204 — the HTTP request for each step of a send, built as plain data so it's unit-tested
// (SendRequestBuilderTests) against the API's contract: snake_case JSON for text, forwards and
// media-by-URL; the file itself as the body for voice and photo (PR 1's one-request send); a blob
// PUT for video's upload. Every message carries `client_id` (dedup) and `sent_at` (tap time).
enum SendRequestBuilder {

    /// What one step of a send is.
    enum Step: Hashable {
        /// Create the message. `bodyFile` nil means the body is `jsonBody` (written to a file by
        /// the engine for a background task); non-nil means upload that media file as the body.
        case post
        /// Upload a video's bytes to its blob (the SAS upload link) before posting it.
        case blobUpload(mediaUrl: String)
    }

    struct Built: Equatable {
        var request: URLRequest
        /// JSON to send as the body, if any.
        var jsonBody: Data?
        /// A media file to upload as the body, if any.
        var bodyFile: URL?
    }

    static let sentAtFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The request that creates `item` on the server.
    static func post(_ item: SendItem, baseURL: URL, token: String, deviceId: String?, fileURL: URL?) -> Built {
        let path = baseURL.appendingPathComponent("books/\(item.bookId.uuidString.lowercased())/messages")
        let sentAt = sentAtFormatter.string(from: item.sentAt)

        // Voice and photo not yet uploaded: the file is the body, everything else in the query.
        if (item.kind == .voice || item.kind == .photo), item.mediaUrl == nil, let fileURL {
            var components = URLComponents(url: path, resolvingAgainstBaseURL: false)!
            var query = [URLQueryItem(name: "client_id", value: item.id.uuidString.lowercased()),
                         URLQueryItem(name: "sent_at", value: sentAt)]
            if item.kind == .voice { query.append(URLQueryItem(name: "duration_seconds", value: String(item.durationSeconds ?? 0))) }
            if let parent = item.parentMessageId { query.append(URLQueryItem(name: "parent_message_id", value: parent.uuidString.lowercased())) }
            if let deviceId { query.append(URLQueryItem(name: "device_id", value: deviceId)) }
            components.queryItems = query
            var request = authorized(URLRequest(url: components.url!), token: token)
            request.setValue(item.kind == .voice ? "audio/mp4" : "image/jpeg", forHTTPHeaderField: "Content-Type")
            return Built(request: request, jsonBody: nil, bodyFile: fileURL)
        }

        // Everything else is JSON: text, forwards, and media whose blob is already uploaded.
        var json: [String: Any] = [
            "type": item.messageType.rawValue,
            "client_id": item.id.uuidString.lowercased(),
            "sent_at": sentAt,
        ]
        if let body = item.body { json["body"] = body }
        if let mediaUrl = item.mediaUrl { json["media_url"] = mediaUrl }
        if let duration = item.durationSeconds { json["duration_seconds"] = duration }
        if let parent = item.parentMessageId { json["parent_message_id"] = parent.uuidString.lowercased() }
        if let forward = item.forwardMessageId { json["forward_message_id"] = forward.uuidString.lowercased() }
        if let deviceId { json["device_id"] = deviceId }
        var request = authorized(URLRequest(url: path), token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return Built(request: request, jsonBody: try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
                     bodyFile: nil)
    }

    /// The blob upload for a video (SAS link from /media/upload-url — no Authorization header).
    static func blobUpload(uploadUrl: URL, fileURL: URL, contentType: String) -> Built {
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int {
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        }
        return Built(request: request, jsonBody: nil, bodyFile: fileURL)
    }

    private static func authorized(_ request: URLRequest, token: String) -> URLRequest {
        var request = request
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
