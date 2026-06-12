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

- **BUG: read receipt only shows on the last message** — the "Read by" avatar row appears only on the most recent message, not earlier ones. Current logic renders the receipt where `reads.lastSeenMessageId == message.id` (`VoiceMessageBubble`/`MessageRow` readReceiptRow), so each reader's receipt shows on exactly their last-seen message — when everyone's caught up they all pile on the newest. Clarify intended behavior (receipt on each reader's last-seen msg only, vs. show "read" up through their last-seen on multiple messages) then fix the render condition.
- **Read receipts larger / more visible** — the read-receipt indicator + reader avatars are small and easy to miss; enlarge them (bigger avatars, clearer "Read by" treatment) for at-a-glance visibility. Pairs with the read-receipt bug above.
- **BUG: recording mic open/close tone misbehaves on CarPlay** — the walkie-talkie chirps (`AudioCue`) don't behave correctly when audio is routed through CarPlay. Needs repro detail (tone silent? plays on wrong output? blocks/cuts the recording?). Investigate `AudioCue` session category/route handling under a CarPlay output route, and how it interacts with the recording session.
- **FEATURE: edit text messages** — let a sender edit their own sent text message. Server: add edited body + `EditedAt` to `Message`, a hub broadcast for edits (mirrors delete), and authorization (own message only). iOS: long-press → Edit, inline editor, re-render with an "edited" marker. Decide whether edit history is kept and the edit window (always vs. time-limited).
- **Predownload messages on notification arrival** (planned 2026-06-12; scope = full, Phases 0-3) — Make opening a chat from a push instant by warming the cache `load()` already reads (`CacheService` key `messages_<bookId>`) BEFORE the user opens. Decided scope: prefetch the **recent page (~50)**, **also predownload voice audio** (accept extra blob egress for instant playback), warm photo/video thumbnails into `ImageCache`. Foundations present: push payload already carries `bookId`/`clubId` (`NotificationService.SendNewMessageAsync`); `BookViewModel.load()` renders cache-first. Plan:
  - **Phase 0 — extract shared chat-cache helpers** out of `BookViewModel` (cache read/write/merge/bounding/optimistic-filter) into a reusable `ChatCache` so the prefetcher writes a cache `load()` fully trusts (same key/format/bounding).
  - **Phase 1 — `MessagePrefetcher`** (no UI): `ensureFreshToken` → `getMessages(bookId)` → write via `ChatCache` → warm `ImageCache` for thumbnails → **download voice audio to a NEW disk audio cache** (audio is currently streamed and never cached — needs a small audio-file cache + `AudioPlayerService` checking it before streaming). Idempotent; in-flight dedupe by bookId.
  - **Phase 2 — background wake**: server adds `content-available: 1` to the new-message `aps` block (keep the visible alert); client adds `remote-notification` to `UIBackgroundModes` + implements `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` → parse bookId → prefetch → completion handler.
  - **Phase 3 — tap/foreground acceleration**: also prefetch from `didReceive` (tap) and `willPresent` (arrived while app open but not in that chat).
  - Caveats: silent push is **best-effort** (iOS throttles background wakes — Low Power Mode, budget); degrades gracefully to today's behavior. Cost scales with club × message rate, and prefetching audio raises egress meaningfully (every member's device downloads each voice file). Background token refresh must work headlessly (depends on launch-refresh + non-rotation fixes — both done). The new audio cache also partly addresses the "smarter local message caching" item (cache bytes, not SAS URLs).
- **Saved Messages UX rework** — currently a row tap forwards immediately to the current chat. Replace with explicit per-row forward button + destination chat/book picker so users can choose the target and avoid accidental forwards.
- **Secrets out of `appsettings.Development.json`** — currently SQL/SignalR/Blob/Notification Hub/APNs/JWT secrets sit in plaintext on disk (gitignored, but one accidental `git add -A` from disaster). Migrate dev secrets to `dotnet user-secrets`; production reads from Azure Key Vault via managed identity. Requires creating the Key Vault, populating it, and granting the App Service identity Key Vault Secrets User.
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
  - **Why this matters / what it would let us delete (context from the 2026-06-11 "notifications for my own messages" bug):** the root enabler is that ONE physical device's APNs token gets smeared across MULTIPLE `User` rows — every time that device signs in as a different account (dev-login / demo / test users), `POST /notifications/register` stamps the same token onto that account's `User.DeviceToken`. The chat fan-out (`ChatHub.BroadcastAndNotify`) excludes the sender by `UserId`, but another account that happens to carry the sender's token is `UserId != SenderId`, so it slips through and the sender's own phone gets pushed. There are THREE separate notification paths that have each been patched independently for variants of this, which the structural fix would unify/remove:
    1. `AuthController` join-request/approval push — got `.Distinct()` dedup early on (stops a shared device getting the *same* push twice).
    2. `ChatHub.BroadcastAndNotify` sender exclusion by `UserId` — present since the first backend commit (stops your *own membership* being pushed).
    3. `ChatHub.BroadcastAndNotify` sender **device-token** exclusion + `.Distinct()` — added 2026-06-11 (`aa8eff1`) as a symptom patch (stops your *device* being pushed via another account that shares its token).
  - With a proper `UserDevices` model, a token belongs to a device (not a borrowed list of account rows), fan-out is keyed by device, and patches #1–#3 collapse into "send to each distinct device that isn't the sender's." `Register` should also re-point a token to the current device/user (claim it) rather than leaving stale copies on old accounts.
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
