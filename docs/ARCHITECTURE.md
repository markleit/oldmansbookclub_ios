# Architecture

Old Man's Book Club is an iOS app backed by an ASP.NET Core API. This document describes the system structure, data flow, and infrastructure.

## Overview

```
iPhone (SwiftUI)
    │
    ├── HTTPS/REST ──────────► ASP.NET Core API (Azure App Service)
    │                               │
    └── WebSocket (SignalR) ────────┤
                                    ├── Azure SQL (data)
                                    ├── Azure Blob Storage (media/avatars)
                                    └── Azure SignalR Service (real-time)
```

## iOS App

**Language/framework:** Swift, SwiftUI, iOS 16+  
**Project generation:** XcodeGen (`project.yml` → `xcodegen generate`)  
**Pattern:** MVVM — `ObservableObject` ViewModels with `@Published` state, injected as environment objects

### Key layers

| Layer | Location | Purpose |
|-------|----------|---------|
| Views | `App/Views/` | SwiftUI screens |
| ViewModels | `App/ViewModels/` | Business logic, API calls, published state |
| Models | `App/Models/Models.swift` | `Codable` + `Identifiable` structs |
| API client | `App/Services/APIClient.swift` | Singleton HTTP client, snake_case ↔ camelCase |
| Chat | `App/Services/ChatService.swift` | SignalR real-time connection (receive only — sending is the SendEngine's) |
| Sending | `App/Services/Send/` | `SendEngine` — app-wide, fire-and-forget sending (#204); see **Sending (iOS)** below |
| Auth state | `App/Services/TokenStore.swift` | JWT in Keychain; display name/role in UserDefaults |
| Share extension | `ShareExtension/` (target `OldMansBookClubShare`) | "Share to OMBC" from any app's share sheet — photos (up to 10), one link, or text → a chosen book chat (#178). Own small REST client (`ShareAPI.swift`); no video yet |
| Shared with the extension | `Shared/` | Compiled into both targets. `SharedContainer` (App Group `group.com.markleit.oldmansbookclub[.dev]` for the DEBUG host + APNs token; the JWT is read in place via the app's own keychain group), `SharePlan` (pure send-order / chat-grouping logic, unit-tested), `SignInSession` (#204: refreshes the one-hour access token for the extension and writes it back to the shared keychain item; refresh tokens aren't rotated, so the app and extension can both refresh safely) |

### Sending (iOS)

Every message the user sends goes through `SendEngine` (#204), never through a screen. Tapping
Send saves it to the `Outbox` on disk (the App Group container) and returns; from there the
engine sends it as soon as possible whatever happens next — leaving the chat, background, lock,
no signal, server down, the app killed by iOS (a force-quit is the one case only reopening fixes).

| Piece | Does |
|---|---|
| `Outbox` | Every unsent message + its media file; strictly increasing tap times (`sent_at`); takes over 2.1's queues once (`migrateLegacy`) |
| `SendItem` | One message: kind, content, status (queued / inFlight / waiting / refused), attempts, first-failure time, refusal reason |
| `SendPolicy`, `RetryClock` | The rules, as pure functions: classify a response (delivered, renew token, 429 wait, offline, transient, refused); which messages get a carrier now; ONE retry clock for the whole queue — 1, 2, 4, 8, 15, 30 s then every 60 s, ±20%, no limit; while backing off only the oldest is retried directly, as a probe |
| `SendRequestBuilder` | The request per step: the file itself as the body for voice/photo (one request), JSON for text/forwards/media-by-URL; for video, its reservation and then a blob PUT |
| `SendTransport` | `URLSessionSendTransport`: one background URLSession (iOS carries it while the app sleeps, relaunches the app with the result), created off the main thread, + a direct path. Text also goes directly at once; voice/photo directly if iOS's copy hasn't landed after 3 s. Server dedups by `client_id` |
| `VideoPreparation`, `VideoSlots` | A picked video is checked and compressed in the composer before Send; its upload goes to a slot fetched in advance (3 per club, kept fresh while online) — so a video, too, is complete at the tap |
| `SendEngine` | Applies all of it; triggers: launch, foreground, leaving the foreground, network back/lost, any API success, chat open, Send now; confirmations to the chat (and the chat cache when no chat is open) |

**Design v2 (#204): every unsent message always has its carrier with iOS.** The carrier is one
complete request in the background URLSession, handed over at the tap while the app is in front
(so iOS doesn't treat it as discretionary) and carrying the **week-long send token**
(`TokenStore.sendToken`, see Authentication), so it can wait days for the network and still
arrive authorized. iOS sends it when it can — app suspended, phone locked — and when is iOS's
choice: usually seconds, sometimes a minute or more (energy and data budgets). A video's carrier
is its upload to an upload slot fetched in advance (or, with none left, a reservation made then),
carrying the message's details: the server creates the message when the upload lands, so nothing
after the tap needs the app. The video is compressed in the composer before Send, so it's complete
at the tap — offline too. A carrier that fails for a passing reason is replaced at once,
held by iOS (`earliestBeginDate`) until the retry clock is due — the same rule with the app open
or suspended. So leaving the foreground hands nothing over; it only keeps the app awake for a
carrier still being built (a token being renewed, a video compressing or reserving). The fast
path: while the app is open, everything also goes directly, and failing messages are retried
directly on the clock. A message with no carrier yet (signed out; a video offline with no slot
left) waits on the clock and for the app.

The chat (`BookViewModel`) draws `SendEngine.items` for its book as pending bubbles and inserts
confirmed messages; its own `messages` are server-confirmed only. Bubbles show **sending**
(spinner), **waiting** (clock — it'll go by itself; Send now / Delete) or **refused** (red, the
server's reason; Copy / Delete). Every step is in the send log (`SendLog`, attached to Feedback).

DEBUG-only launch arguments shorten the timings for tests: `-sendWaitingAfter`, `-sendTimingScale`,
`-sendDirectNudge`, `-sendReminderAfter`.

### Navigation structure

```
RootView (auth gate)
├── LoginView
├── ClubSetupView (new users — create or join)
├── PendingApprovalView (join request submitted)
└── ContentView (TabView — authenticated)
    ├── LibraryView  (books + chat)
    ├── ProfileView  (settings, account deletion)
    └── AdminView    (requests / members / reports — role-gated)
```

### URL routing

`App/Services/ServerEnvironment.swift` resolves the API host. In RELEASE it compiles to the
production literal (`https://oldmansbookclub-api.azurewebsites.net`) with no lookup or storage
read. In DEBUG it's a runtime value read from `UserDefaults` (editable from Settings → "Server
(Debug)"), defaulting to `localhost:5235` on the simulator and production on a device — so a
device build can be pointed at a laptop or a staging slot without a rebuild. Both `APIClient` and
`ChatService` go through this same resolution; see [`docs/TESTING.md`](TESTING.md) for the full
preset list and the `.dev`-app isolation this enables.

---

## API

**Framework:** ASP.NET Core 10  
**Runtime:** Linux container on Azure App Service (West US 3)  
**Database ORM:** EF Core with SQL Server — migrations run automatically on startup (5 s delay)

### Controllers

| Controller | Route | Purpose |
|------------|-------|---------|
| `AuthController` | `/auth` | Sign in with Apple, demo/dev login, token refresh, account deletion |
| `UsersController` | `/users` | Own profile, blocking |
| `ClubsController` | `/clubs` | Club CRUD, public listing, membership |
| `BooksController` | `/books` | Book CRUD per club, reorder, unread counts |
| `MessagesController` | `/messages`, `/books/{id}/messages` | Send/list/save/report messages, transcripts |
| `ChatHub` | SignalR (`/hubs/chat`) | Real-time messaging |
| `MediaController` | `/media` | SAS URL generation for blob uploads |
| `StorageEventsController` | `/storage/events` | Azure Event Grid webhook: a reserved video's file landed → create its message (#204) |
| `NotificationsController` | `/notifications` | APNs device token registration |
| `AdminController` | `/admin` | Join requests, member management, reports, user deletion |
| `FeedbackController` | `/feedback` | In-app feedback → GitHub issues (admin-only) |
| `DiagnosticsController` | `/diagnostics` | MetricKit crash/hang reports → deduped GitHub issues (#100) |

### Services

| Service | Purpose |
|---------|---------|
| `AppleTokenValidator` | Validates Sign in with Apple identity tokens; exchanges authorization code for refresh token; revokes token on account deletion |
| `BlobService` | Generates upload/read SAS URLs for Azure Blob Storage; stores voice/photo files sent as a request body |
| `MessageSendService` | Validation, persistence, and broadcast for a sent message — shared by `ChatHub` and `MessagesController` |
| `UnreadCalculator` | Unread-count formula: others' messages that *arrived* after the read marker's message arrived (#204: `ReceivedAt`, not `SentAt`), plus voice tracked independently until heard; shared by the books list and push badge counts |
| `HubRateLimiter` | Per-user, in-memory, fixed-window send limit (30/min) for both the REST send and the legacy hub sends; reports how long until the window resets (→ `Retry-After`) |
| `RateLimitPolicies` | HTTP rate-limit partitions: `auth` per IP (10/min), `media` upload links per user (30/min). Authentication runs before the limiter so the user is known |
| `NotificationService` | Sends APNs push notifications (join requests, approvals, new messages) |
| `NotificationDispatch` | Hands new-message push fan-out off to a background worker so a sender's hub call returns immediately |
| `GitHubService` | Thin wrapper over the GitHub Issues REST API — backs Feedback and Diagnostics reporting |

### JSON convention

All JSON keys are `snake_case` in both directions (`JsonNamingPolicy.SnakeCaseLower` on the API; `.convertToSnakeCase` / `.convertFromSnakeCase` on iOS).

---

## Authentication

```
iOS                          API                        Apple
 │                            │                           │
 ├─ Sign in with Apple ───────────────────────────────►  │
 │  (identityToken +          │                           │
 │   authorizationCode)       │                           │
 │                            ├─ Validate identity token ►│
 │                            │◄─ Apple subject ID ───────│
 │                            │                           │
 │                            ├─ Exchange auth code ─────►│
 │                            │◄─ refresh token ──────────│
 │                            │  (stored on User record)  │
 │                            │                           │
 │◄─ JWT (1 hr) + refresh ────│                           │
 │   token (90-day)           │                           │
 │                            │                           │
 │  (all subsequent requests use Bearer JWT)              │
```

On account deletion, the stored refresh token is revoked via `https://appleid.apple.com/auth/revoke` so the app no longer appears under the user's Apple ID settings.

The API JWT is short-lived (1 hour; `Jwt:AccessTokenMinutes` overrides it, for testing token
expiry on a dev server); the opaque refresh token (`/auth/refresh`) is what's actually
long-lived (90 days, sliding — refreshing extends it). Refresh tokens are **not** rotated on use:
the same token stays valid indefinitely as long as it's used within its window. This is
deliberate — rotating (revoke-and-reissue on every refresh) means a refresh whose response never
reaches the client (e.g. a background/push-woken refresh iOS suspends mid-flight) leaves the
server having revoked a token the client still holds, forcing a sign-out on the next attempt. Only
the token's hash (SHA-256) is persisted, so a DB compromise doesn't expose live sessions. Trade-off:
no reuse-detection for a stolen refresh token — accepted for this app's threat model.

**Send token (#204 design v2).** Sign-in and refresh also return `send_token`: a JWT with
`scope: send`, valid 7 days (`Jwt:SendTokenMinutes` overrides it), carrying the id of the refresh
token it came with (`sid`). The app attaches it to a message it hands to iOS's background transfer,
so a message waiting days for the network can't arrive with an expired access token. It's
accepted only by endpoints marked `[AcceptsSendToken]` (the two sends and the video reservation)
and only while that refresh token is live, so signing out ends it at once
(`SendToken.ValidateAsync`, on `JwtBearerEvents.OnTokenValidated`). Access tokens carry no scope
and behave as before, so older clients are unaffected.

### User states

```
New user → needs_club_setup
              ├── create club → approved immediately (IsAdmin on club)
              └── join request → pending_approval
                                    ├── approved → signed in
                                    └── declined → request_declined
                                                      └── try different club → needs_club_setup
```

### Roles

- `User.IsAdmin` — global admin; full access to all clubs, users, reports
- `Membership.IsClubAdmin` — club admin; manages join requests and members for their club only

---

## Real-time Chat

Messages are **sent** over REST and **received** over SignalR. In production SignalR goes through
Azure SignalR Service (Managed Identity connection); in local Development `ChatHub` runs in-process
(`AddSignalR()` with no Azure backplane) — see [`docs/TESTING.md`](TESTING.md) for what that does
and doesn't change about test coverage.

```
iOS sender                    API (MessagesController →          iOS receivers
                                   MessageSendService)
    │                                   │                               │
    ├─ POST /books/{id}/messages ──────►│                               │
    │                                   ├─ Dedup by (sender, client_id)  │
    │                                   ├─ Rate limit (30/min/user)     │
    │                                   ├─ Validate (approved, member)  │
    │                                   ├─ Save to SQL                  │
    │                                   ├─ Broadcast (SignalR) ─────────►│
    │                                   ├─ Queue push (APNs)            │
    │◄─ 200 MessageDto (= confirmation) │                               │
```

`POST /books/{id}/messages` takes two body formats, chosen by `Content-Type` (#204):

| Body | Used for | Notes |
|---|---|---|
| `application/json` | Text; video (`media_url` from a reservation or `/media/upload-url`, after a blob PUT); forwards (`forward_message_id`); every pre-2.2 client | `SendMessageRequest` |
| `audio/mp4` / `image/jpeg` — the file itself | Voice and photo in **one request** (`client_id`, `duration_seconds`, `parent_message_id`, `device_id` in the query) | The server stores the blob and creates the message, so the app can hand the whole send to iOS's background transfer. Every refusal happens before the bytes are stored. Video isn't accepted this way: up to 100 MB is too much to proxy through App Service (~230 s request limit). |

**Video without the app (#204 design v2).** A video is too big to pass through App Service, so
its file goes straight to storage. The app first reserves the message —
`POST /books/{id}/messages/video` with `client_id`, `parent_message_id`, `device_id`, `sent_at` —
and gets a create-only upload link valid as long as the send token (or, if a copy of this send
already got through, the message and no link). Every refusal (membership, rate limit) happens
here, before a byte is uploaded. When the blob lands, Event Grid posts a `BlobCreated` event to
`/storage/events`; the server checks the file really is in storage and creates the message exactly
as the app's post would (tap time, reply, push), then drops the reservation (`PendingVideos`). The
app may still post the video itself when it's running; whichever comes first creates the message,
deduplicated by `client_id`.

**Upload slots** (`POST /media/video-slots?clubId=&count=`) are the same thing fetched in advance,
so a video sent with no network can be handed to iOS at the tap: each a create-only link to a new
blob, good for 7 days, at most 10 unexpired per user. A slot has no message yet — the app sends the
message's details with the upload as blob metadata (`x-ms-meta-bookid`, `clientid`, `sentat`,
`parentid`, `deviceid`), and the server creates the message from them when the blob lands, after
checking the book is in the slot's club (and, when saving, that the sender is a member). Slots
fetched with the send token belong to its sign-in: signing out drops what they'd create. Older clients use `/media/upload-url` and post; their uploads have no
reservation, so their events are ignored.

**Two times per message (#204).** `sent_at` is when the sender tapped Send: 2.2+ clients stamp it
(JSON field or query param), and the server clamps it to `[received − 7 days, received]` (older
clients send none, so it equals arrival). It orders the chat, so a message held up by an outage
lands where it was said. `received_at` is when the server got it, and drives everything about "is
this new to you": unread counts, the read marker ("only advances" means a later arrival), push
counts. `GET /books/{id}/messages?include_late=true` also returns **late arrivals**: messages that
arrived in the last 7 days more than 2 minutes after their `sent_at` and fall below the newest
page. It's opt-in because a 2.1-or-older client pages backwards from the oldest message it holds;
handed one far older than its page, its next page would skip the gap.

A re-send with a `client_id` the server already has returns the existing message, stores nothing and
is not counted against the rate limit. Over the limit, the answer is **429 + `Retry-After`** with the
usual `{error}` body (older clients just show the message). The legacy hub send methods, including
`ForwardMessage`, remain for 2.1-and-older clients.

SignalR connections authenticate via `?access_token=<JWT>` query parameter (WebSocket upgrade can't carry Authorization headers).

---

## Push Notifications (APNs)

The API sends notifications directly to APNs using HTTP/2 with a provider token (JWT signed with an ES256 key).

- **Debug builds:** `aps-environment = development` → APNs sandbox
- **Release/TestFlight/App Store:** `aps-environment = production` → APNs production

The API tries production first; on `BadDeviceToken` it retries on the sandbox endpoint. HTTP/2 keep-alive pings (every 90 s) prevent idle connection drops.

### Notification types

| Type | Trigger | Recipients |
|------|---------|------------|
| `join_request` | User requests to join a club | All club admins |
| `join_approved` | Admin approves join request | Requesting user |
| `join_declined` | Admin declines join request | Requesting user |
| New message | Message sent in book chat | All club members except sender |

---

## Data Model (simplified)

```
User
 ├── Memberships (many) ──► Club
 ├── JoinRequests (many) ──► Club
 └── Messages (many) ──► Book ──► Club

BlockedUsers (UserId ↔ BlockedId)
Reports (ReporterId → Message)
SavedMessages (UserId → Message)
```

---

## Media Storage

All user-generated media is stored in Azure Blob Storage (`oldmansbookclubstore`).

| Container | Access | Content |
|-----------|--------|---------|
| `club-media` | Private (SAS) | Voice messages, chat photos, videos |
| `avatars` | Public | Profile avatar images |

Upload flows (#204): voice and photo go as the body of the send itself (the server stores the
blob). A video goes straight to blob storage on a reservation's create-only upload link (~7 days),
and the server creates its message when storage reports the file landed (see Real-time Chat).
Older clients get a 60-minute write link from `/media/upload-url` and post the blob URL.

Read access for `club-media` uses time-limited user delegation SAS URLs (7 day read).

**Event Grid subscription (production, one-time setup).** The "file landed" report comes from an
Event Grid system topic on `oldmansbookclubstore` (East US — the topic must be in the storage
account's region), subscribed to `BlobCreated` for `club-media/*.mp4` and delivered to the API's
`/storage/events`. The endpoint must be deployed first: creating the subscription runs Event Grid's
validation handshake against it.

```bash
az provider register --namespace Microsoft.EventGrid   # once per subscription
az eventgrid system-topic create -g oldmansbookclub-rg -n oldmansbookclubstore-events -l eastus \
  --topic-type microsoft.storage.storageaccounts \
  --source $(az storage account show -n oldmansbookclubstore --query id -o tsv)
az eventgrid system-topic event-subscription create -g oldmansbookclub-rg \
  --system-topic-name oldmansbookclubstore-events -n reserved-videos \
  --endpoint https://oldmansbookclub-api.azurewebsites.net/storage/events \
  --included-event-types Microsoft.Storage.BlobCreated \
  --subject-begins-with /blobServices/default/containers/club-media/ --subject-ends-with .mp4
```

Dev has no subscription (a laptop isn't reachable from Event Grid): there a video completes by the
app's own post, and the API tests post events to `/storage/events` directly.

---

## CI/CD

| Workflow | Trigger | Action |
|----------|---------|--------|
| `test.yml` | Push to `main` / PR — **blocking** | API integration tests (real SQL Server via Testcontainers) + iOS unit tests + hermetic UI tests. See [`docs/TESTING.md`](TESTING.md) for what each lane covers |
| `deploy-api.yml` | Push to `main` with changes in `API/**` | Waits for that commit's "API integration" job to pass (#204), then dotnet publish → zip → Azure Web App deploy (~2 min) → waits for `/health/ready`. A manual run skips the wait |
| `ci.yml` | Push to `main` / PR | XcodeGen → build for iOS simulator |
| `backup.yml` | Daily 3 AM UTC | Export Azure SQL to BACPAC in blob storage (30-day retention) |

---

## Local Development

Build steps live in [`CLAUDE.md`](../CLAUDE.md#build); the isolated dev backend
(`bookclubdb-dev`), the `.dev` device app, the scenario matrix, and the automated test lanes are
covered in full in [`docs/TESTING.md`](TESTING.md) — this doc doesn't duplicate either.

> **Note:** After every `xcodegen generate`, re-select the signing team in Xcode → target → Signing & Capabilities.
