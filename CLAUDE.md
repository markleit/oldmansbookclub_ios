# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Old Man's Book Club** — iOS SwiftUI app + ASP.NET Core 9 API. Single club, multiple books, per-book discussion threads with real-time chat.

- **iOS deployment target:** iOS 16.0+
- **Bundle ID:** `com.example.oldmansbookclub` (placeholder — needs replacing before distribution)
- **API:** Deployed to Azure App Service (Norway East, VS subscription)
- **API base URL:** configured in `APIClient.swift` (production) and `appsettings.Development.json` (local)

## Build

### iOS

Requires macOS with Xcode installed.

```bash
brew install xcodegen
xcodegen generate        # regenerate .xcodeproj from project.yml
open OldMansBookClub.xcodeproj
```

CI builds via GitHub Actions on push to `main` and PRs — installs XcodeGen, generates project, builds for iOS simulator.

### API

```bash
cd API
dotnet run
```

Requires a SQL Server connection string and Azure credentials in `appsettings.Development.json` (not committed).

## Architecture

### iOS (SwiftUI + MVVM)

- `App/OldMansBookClubApp.swift` — `@main` entry point, injects `AuthViewModel` as environment object
- `App/ContentView.swift` — root `TabView` (Library / Profile tabs)
- `App/Models/Models.swift` — `Club`, `Book`, `Message`, `User` as `Codable` + `Identifiable` structs
- `App/ViewModels/` — `ObservableObject` classes with `@Published` properties
- `App/Views/` — SwiftUI views
- `App/Services/APIClient.swift` — singleton HTTP client; base URL points to Azure, snake_case ↔ camelCase conversion, ISO8601 date decoding
- `App/Services/ChatService.swift` — SignalR client for real-time chat
- `App/Services/TokenStore.swift` — JWT token persistence (Keychain)

### API (ASP.NET Core 10)

- `API/Program.cs` — wires up EF Core (SQL Server), Azure SignalR, JWT auth, Swagger
- `API/Controllers/` — `AuthController`, `ClubsController`, `BooksController`, `NotificationsController`, `MediaController`
- `API/Hubs/ChatHub.cs` — SignalR hub for real-time messaging
- `API/Models/Entities.cs` — EF Core entities: `User`, `Club`, `Membership`, `Book`, `Message`
- `API/Models/Dtos.cs` — request/response DTOs
- `API/Data/AppDbContext.cs` — EF Core context
- `API/Services/` — `AppleTokenValidator`, `BlobService` (Azure Blob Storage), `NotificationService` (APNs push)
- `API/Migrations/` — EF Core migrations; migrations run automatically on startup (background task, 5s delay)

## Auth

Sign in with Apple → Apple identity token sent to `/auth/apple` → API validates token, returns JWT → stored in Keychain via `TokenStore`. JWT passed as `Authorization: Bearer` header on all authenticated requests, and via `?access_token=` query param for SignalR WebSocket connections.

## JSON serialization

The API uses `JsonNamingPolicy.SnakeCaseLower` — all JSON keys are snake_case in both directions. The iOS `APIClient` encodes with `.convertToSnakeCase` and decodes with `.convertFromSnakeCase` to match.

## Simulator / local dev setup

The iOS app uses `#if targetEnvironment(simulator)` to point at `http://localhost:5235` instead of Azure. The login screen shows a **Dev Login (Simulator)** button (compile-time only, not in release builds) that hits `POST /auth/dev-login` — only available when the API runs in Development mode.

To run locally:
1. `cd API && dotnet run` — requires `appsettings.Development.json` (not in repo)
2. Build and run in Xcode simulator
3. Tap "Dev Login (Simulator)"

Azure SQL firewall must allow your dev machine's IP — add a rule via `az sql server firewall-rule create` if your IP changes.

`NSAllowsLocalNetworking: true` is set in the app plist (via `project.yml`) to allow HTTP to localhost in the simulator.

## Key configuration (not in repo)

`API/appsettings.Development.json` — gitignored, contains:
- `ConnectionStrings:DefaultConnection` — Azure SQL Server
- `Azure:SignalRConnectionString` — Azure SignalR Service
- `Jwt:Secret`, `Jwt:Issuer`, `Jwt:Audience`
- Azure Blob Storage connection string
- APNs credentials

## Known gaps / next up

- **BUG: long audio msg + immediate backgrounding → stuck unsendable message** — Repro: send a long voice message, then immediately background the app. Result: one copy sends successfully, a second copy is left in a failed state and will NOT send on retry either. Two symptoms to untangle: (1) a duplicate is being created (likely the optimistic item plus a re-enqueue, or the upload completing server-side while the client thinks it failed), and (2) the failed item is permanently stuck — retry does not recover it. Likely interaction between `MediaSendQueue` persistence/echo-timeout and the app suspending mid-upload (URLSession task killed on background, or the SignalR invoke racing the echo timeout). Investigate: does the successful copy correspond to the server echo arriving after the client already marked the optimistic item failed? Is the stuck item's `uploadedMediaUrl` already populated (upload succeeded, only the SignalR send failed) so retry should rebroadcast rather than re-upload? Check idempotency via `clientId` (`TryRebroadcastExistingAsync`) — the dupe suggests the clientId isn't being reused on retry. Consider a background `URLSession` for media uploads so backgrounding doesn't kill the transfer.
- **Saved Messages UX rework** — currently a row tap forwards immediately to the current chat. Replace with explicit per-row forward button + destination chat/book picker so users can choose the target and avoid accidental forwards.
- **Secrets out of `appsettings.Development.json`** — currently SQL/SignalR/Blob/Notification Hub/APNs/JWT secrets sit in plaintext on disk (gitignored, but one accidental `git add -A` from disaster). Migrate dev secrets to `dotnet user-secrets`; production reads from Azure Key Vault via managed identity. Requires creating the Key Vault, populating it, and granting the App Service identity Key Vault Secrets User.
- **Forced re-sign-in after idle** — users reporting they have to log back in after some idle period. Should be silently refreshing via `/auth/refresh`. Two likely causes to investigate: (1) tokens issued before Group C deploy (2026-06-04) never had a refresh token paired, so the first 401 falls through to sign-out — expected once per user only; (2) genuine bug in `APIClient.attemptRefresh` (refresh endpoint failure, refresh token not persisted, race with SignalR connection failure). Reproduce with a clean post-Group-C sign-in, leave idle 1+ hour, then try any action; check whether `TokenStore.shared.refreshToken` is non-nil and what the `/auth/refresh` call returns.
- **Smarter local message caching** — current `CacheService` stores messages with SAS URLs from the last fetch. Re-entering the chat after offline shows broken images because cached SAS expires. Consider: cache by plain URL + regenerate SAS on display; OR cache the rendered image bytes; OR shorten the SAS-URL lifetime in cache to match actual blob read SAS. Investigate, propose, implement.
- **Auto-import + chapter structure in book chat** — when a book is added (currently via Google Books search → title/author/cover), also pull its chapter / table-of-contents structure and surface it in the book's chat. Open design questions: chapter list source (Google Books volumeInfo doesn't carry TOC consistently — may need an alternative like Open Library, parsed EPUB metadata, or a manual editor for the club admin); chat UX (chapter sections, chapter-tagged messages, jump-to-chapter navigation, current-chapter indicator); DB schema (new Chapters table linked to Book; optional ChapterId on Message). Likely starts with a manual "add chapters" admin UI before automation.
- **Discussion-subject labels** — surface what each part of the chat is about. Auto where possible (LLM-extracted topics from recent message windows, e.g. "Character development of Sam", "Plot twist in Chapter 3", "Pacing critique") with optional manual override. Open design questions: granularity (label individual messages, label threads, label time ranges); UI (subject chips at the top of clusters, filter-by-subject view, jump-to-next-subject); cost/latency model (server-side batch summarization vs on-device — and which LLM); whether labels are first-class entities (DB table, can be edited / merged / deleted) or transient computed view; co-existence with the chapter structure backlog item (chapter is a coarse axis, subject is finer-grained — likely independent dimensions of the same conversation).
- **Apple Watch companion + CarPlay** — multi-platform expansion. Watch: send quick text or voice messages, glance at recent activity, push notification handoff. CarPlay: read-aloud incoming messages, voice replies. Big feature area; needs its own design document.
- **Max message size limits** — voice 15 min (auto-stop with countdown), video 5 min duration + 100 MB file size (client pre-upload check + `AVAssetExportSession` compression if oversized), photos already handled via `resizedForUpload` (1024px / JPEG 0.7). Server-side: enforce blob size limit in the SignalR hub before creating the message so a misbehaving client can't bypass the client check.
- **Offline / no-service UX** — current behavior is a cached banner and silent send failures. Needs a proper design pass: what to show when iOS reports no network vs. server unreachable vs. flaky cell; how to queue + surface pending sends (queue is already there for media, but text isn't queued); when and how to retry; per-message retry indicators that are intuitive without being noisy.
- **Threaded messages** — reply to a specific message and render the result as a thread (parent + replies indented or in a sheet). Server-side: new `ParentMessageId` column on `Message`; iOS: long-press → Reply; thread rendering UI. Consider whether a thread is a "child collection" or a "subset of the same chat with a header".
- **Saved Messages indexing & auto title/label** — the saved-message list is currently a flat reverse-chronological view. Add: search across saved bodies/transcripts, group by source book/chat or by topic, auto-generated summaries or titles for long voice messages, time-decayed sorting. Related to but distinct from the "rework forwarding UX" item — this one is about the *browsing/find* experience, not the action UX.
- **Chat scroll position preservation** — previously attempted via `ScrollAnchorStore` + `LazyVStack.onAppear` tracking but the position-detection was unreliable (LazyVStack render buffer is a superset of the visible viewport, `proxy.scrollTo(anchor:)` behavior was inconsistent). Revisit with iOS 17+ `ScrollPosition` / `scrollPosition(id:)` for precise viewport tracking and deterministic scroll restoration. Goal: restore exact scroll position on chat re-entry; "↓ N new" pill when scrolled away from bottom; notification tap always jumps to newest.

### Open items from the 2026-06-04 full code review

The full review (3 Critical, 10 High, 19 Medium, 8 Low + roadmap) had its Critical tier and ~half the High tier closed in the Group A/B/C work (1 hr JWT + refresh tokens, demo/dev-login no longer grant admin, hub text-length + per-user rate limit, ChatService→actor, synchronous startup migrations + `/health/ready`, deleted-message `SenderId` nulled, blob URL host pinned, club-admin checks on book mutations, `CacheService`→Caches dir, `ImageCache` cost limit, media retry cap). The findings below are the ones **still open** (the source doc `docs/CODE_REVIEW_2026-06-04.md` was folded into this list and removed).

**Security (open):**
- **`AdminController` has no class-level `[Authorize]`** (H8) — authorization relies on scattered inline `IsAdminAsync()` checks; one missed action is a hole (e.g. `seed-messages` is reachable unauthenticated and gated only by an `X-Seed-Key` header). Add `[Authorize]` at the class and `[AllowAnonymous]` only where intended.
- **`ClubsController.AddMember` is open to any club member** (H9 remainder) — a regular member can mass-add accounts. The book mutations were locked down in Group A; `AddMember` was not. Require club-admin.
- **7-day read SAS** (M2) — a media URL handed to a client keeps working for 7 days after the user is removed/blocked or the message is deleted (SAS can't be individually revoked). Cut read-SAS validity to ~1 hr.
- **SignalR auth via `?access_token=` query** (M19) — token lands in App Service / IIS request logs. Move to a header or accept + document the risk.
- **`/notifications/register` doesn't validate token format** — accepts any string up to 512 chars. Enforce 64-hex APNs format.
- **Upload SAS has no Content-Type or size restriction** — client claims `audio/mp4` but anything can be PUT; pair with the "Max message size limits" item for the size half.

**Reliability / scale (open):**
- **APNs fan-out blocks the hub method** (H2) — sender's `invoke()` doesn't return until N per-member APNs round-trips finish; send latency scales with club size. Offload to a hosted `BackgroundService` + `Channel<T>` (note: `Task.Run` inside the hub is wrong — the Scoped `db` is disposed when the method returns, so the worker needs its own scope).
- **Single `DeviceToken` column per user** (H6) — multi-device users only get push on the last-registered device; no pruning on APNs `410 Unregistered` / `BadDeviceToken`. Move to a `UserDevices` table (`(UserId, DeviceToken)` unique), deactivate on `Unregistered`. Azure Notification Hubs is already configured-but-unused and is a candidate to take this over.
- **No connection-level membership cache in `ChatHub`** (H10) — every send re-queries `Users.FindAsync` + `Books.FindAsync` + `Memberships.AnyAsync` (~3 DB round-trips/message). Cache `(userId, clubIds)` in `Context.Items` on `OnConnectedAsync`.
- **Missing `Messages(SenderId)` index** — account deletion table-scans messages. (The `Messages(ClientId)` index was added in Group B.)
- **Transactional gaps** — `AuthController.SignInWithApple` does up to 5 sequential `SaveChangesAsync` (orphan-user risk if it fails midway); `DeleteMyAccount` / admin `DeleteUser` run 7-8 `ExecuteDeleteAsync` not wrapped in a transaction (partial-delete risk). Wrap each in `BeginTransactionAsync`.
- **`AppleTokenValidator` refetches Apple's JWKs on every login** — cache the key set.
- **Observability** — no Application Insights / structured logging / metrics / alerting; `NotificationService` logs success at `Warning` level (floods the channel). Wire App Insights + drop success logs to `Information`.
- **Blob hygiene** — no lifecycle policy or orphaned-upload GC (retried uploads leak blobs forever); blob names aren't date-prefixed, so containers >10k blobs list slowly. Add `{clubId}/{yyyy/MM/dd}/{guid}` naming + a lifecycle rule.
- **No test target** — zero unit/UI/integration tests. Singletons make mocking hard; injecting an `APIClientProtocol` would unlock view-model tests (start with `BookViewModel` dedup logic).

**Maintainability / cleanup (open, lower priority):**
- **`BookViewModel` carries ~8 responsibilities**; large view files (`BookDetailView`, `MessageInputView`, `AdminView`) should be split.
- **`APIClient` has 20+ ad-hoc `URLRequest` builders** bypassing the `get/post/patch` helpers — unify into one generic `request<R: Decodable>`; also drop the vestigial extra ISO8601 date-formatter variants.
- **`pendingByBody` text dedup races on identical consecutive sends** (M1) — the second "hi" overwrites the first's pending entry, leaving an unresolved optimistic bubble. Key by a per-message clientId like voice does.
- **Schema niceties** — `Book.Status` is a free-form string (→ enum/tinyint); `Message.BookId` is nullable but always required; `User.Email` has no uniqueness constraint; `Membership.Id` is an artificial PK over the natural `(UserId, ClubId)`.
- **Misc Low** — `NavigationView` (deprecated) in `BookDetailView_Previews`; duplicate book-cache mechanism (`UserDefaults` in `LibraryViewModel` vs `CacheService` for messages); `formatElapsed` has no hour rollover; `flushPendingVoice` has no concurrent-flush guard (foreground transition + SignalR reconnect can overlap).
