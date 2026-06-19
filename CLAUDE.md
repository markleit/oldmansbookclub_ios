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
- `GitHub` — PAT + owner/repo for the in-app Feedback feature and the dev backlog (server-only; never ships in the app)

## Known gaps / next up

The dev backlog now lives in **GitHub Issues** (`markleit/oldmansbookclub_ios`) — that's the source of truth, with labels `bug` / `enhancement` / `perf` / `tech-debt`. This slim index keeps the list in AI context each session; fetch full notes with `gh issue view <N>`. (The in-app Feedback view filters by the `feedback` label, so these dev labels stay out of the user-facing list.) **Security items are deliberately NOT filed as public issues (the repo is public) — they live inline below.**

**Features / enhancements**
- #12 — Edit text messages
- #13 — Predownload messages on notification arrival (foreground audio prefetch shipped 1.4.1 via `AudioCache`; message/thumbnail prefetch + background-wake remain)
- #14 — Saved Messages UX rework (explicit forward + destination picker)
- #15 — Smarter local message caching (image SAS expiry; audio half done in 1.4.1)
- #16 — Auto-import + chapter structure in book chat
- #17 — Discussion-subject labels
- #18 — Apple Watch companion + CarPlay
- #19 — Max message size limits (voice/video/photo; size half pairs with the upload-SAS security item)
- #20 — Offline / no-service UX
- #21 — Threaded messages
- #22 — Saved Messages indexing & auto title/label
- #23 — Chat scroll position preservation

**Bugs**
- #11 — Recording mic open/close tone misbehaves on CarPlay (`AudioCue`)
- #25 — Single `DeviceToken` per user → `UserDevices` table (H6; root cause of the self-notification bug)
- #28 — Transactional gaps in multi-step writes (`SignInWithApple`, account deletion)
- #35 — `pendingByBody` text dedup race on identical consecutive sends (M1)

**Perf**
- #9 — Voice-bubble rendering: re-render storm + per-bubble `GeometryReader` + `visibleMessages` recompute
- #24 — APNs fan-out blocks the hub method (H2)
- #26 — No connection-level membership cache in `ChatHub` (H10)
- #27 — Missing `Messages(SenderId)` index
- #29 — `AppleTokenValidator` refetches Apple's JWKs on every login

**Tech debt**
- #30 — Observability: App Insights + structured logging
- #31 — Blob hygiene: lifecycle policy + date-prefixed naming
- #32 — No test target
- #33 — `BookViewModel` ~8 responsibilities; split large views (`BookDetailView`, `MessageInputView`, `AdminView`)
- #34 — `APIClient`: unify 20+ ad-hoc `URLRequest` builders
- #36 — Schema niceties (`Book.Status` enum, `Message.BookId` non-null, `User.Email` uniqueness, `Membership` natural PK)
- #37 — Misc Low cleanup (`NavigationView` in previews, duplicate book cache, `formatElapsed` rollover, `flushPendingVoice` guard)

### Security backlog (kept private — NOT filed as public GitHub issues)

The repo is public, so these stay here only. Still-open items from the 2026-06-04 review plus the secrets migration:

- **`AdminController` has no class-level `[Authorize]`** (H8) — authorization relies on scattered inline `IsAdminAsync()` checks; one missed action is a hole (e.g. `seed-messages` is reachable unauthenticated and gated only by an `X-Seed-Key` header). Add `[Authorize]` at the class and `[AllowAnonymous]` only where intended.
- **`ClubsController.AddMember` is open to any club member** (H9 remainder) — a regular member can mass-add accounts. The book mutations were locked down in Group A; `AddMember` was not. Require club-admin.
- **7-day read SAS** (M2) — a media URL handed to a client keeps working for 7 days after the user is removed/blocked or the message is deleted (SAS can't be individually revoked). Cut read-SAS validity to ~1 hr.
- **SignalR auth via `?access_token=` query** (M19) — token lands in App Service / IIS request logs. Move to a header or accept + document the risk.
- **`/notifications/register` doesn't validate token format** — accepts any string up to 512 chars. Enforce 64-hex APNs format.
- **Upload SAS has no Content-Type or size restriction** — client claims `audio/mp4` but anything can be PUT; pair with the "Max message size limits" item (#19) for the size half.
- **Secrets out of `appsettings.Development.json`** — currently SQL/SignalR/Blob/Notification Hub/APNs/JWT/GitHub secrets sit in plaintext on disk (gitignored, but one accidental `git add -A` from disaster). Migrate dev secrets to `dotnet user-secrets`; production reads from Azure Key Vault via managed identity. Requires creating the Key Vault, populating it, and granting the App Service identity Key Vault Secrets User. (The GitHub PAT added for the Feedback feature should be rotated and moved here too.)

### Context from the 2026-06-04 full code review

The full review (3 Critical, 10 High, 19 Medium, 8 Low + roadmap) had its Critical tier and ~half the High tier closed in the Group A/B/C work (1 hr JWT + refresh tokens, demo/dev-login no longer grant admin, hub text-length + per-user rate limit, ChatService→actor, synchronous startup migrations + `/health/ready`, deleted-message `SenderId` nulled, blob URL host pinned, club-admin checks on book mutations, `CacheService`→Caches dir, `ImageCache` cost limit, media retry cap). The still-open findings were migrated to GitHub Issues above (reliability/scale → #24–#32, maintainability → #33–#37) except the security items, which are kept inline above. The source doc `docs/CODE_REVIEW_2026-06-04.md` was folded into this list and removed.
