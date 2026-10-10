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
| Chat | `App/Services/ChatService.swift` | SignalR real-time connection |
| Auth state | `App/Services/TokenStore.swift` | JWT in Keychain; display name/role in UserDefaults |
| Share extension | `ShareExtension/` (target `OldMansBookClubShare`) | "Share to OMBC" from any app's share sheet — photos (up to 10), one link, or text → a chosen book chat (#178). Own small REST client (`ShareAPI.swift`); no video yet |
| Shared with the extension | `Shared/` | Compiled into both targets. `SharedContainer` (App Group `group.com.markleit.oldmansbookclub[.dev]` for the DEBUG host + APNs token; the JWT is read in place via the app's own keychain group), `SharePlan` (pure send-order / chat-grouping logic, unit-tested) |

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
| `UnreadCalculator` | Unread-count formula (voice tracked independently of the read marker until heard); shared by the books list and push badge counts |
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
| `application/json` | Text; video (`media_url` from `/media/upload-url` + a blob PUT); forwards (`forward_message_id`); every pre-2.2 client | `SendMessageRequest` |
| `audio/mp4` / `image/jpeg` — the file itself | Voice and photo in **one request** (`client_id`, `duration_seconds`, `parent_message_id`, `device_id` in the query) | The server stores the blob and creates the message, so the app can hand the whole send to iOS's background transfer. Every refusal happens before the bytes are stored. Video isn't accepted this way: up to 100 MB is too much to proxy through App Service (~230 s request limit). |

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
| `club-media` | Private (SAS) | Voice messages, chat photos |
| `avatars` | Public | Profile avatar images |

Upload flow: iOS requests a SAS upload URL from the API → uploads directly to blob storage → sends the blob URL via SignalR message.

Read access for `club-media` uses time-limited user delegation SAS URLs (10 min upload, 7 day read).

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
