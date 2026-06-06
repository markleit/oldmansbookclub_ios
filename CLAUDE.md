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

- **Saved Messages UX rework** — currently a row tap forwards immediately to the current chat. Replace with explicit per-row forward button + destination chat/book picker so users can choose the target and avoid accidental forwards.
- **Secrets out of `appsettings.Development.json`** — currently SQL/SignalR/Blob/Notification Hub/APNs/JWT secrets sit in plaintext on disk (gitignored, but one accidental `git add -A` from disaster). Migrate dev secrets to `dotnet user-secrets`; production reads from Azure Key Vault via managed identity. Requires creating the Key Vault, populating it, and granting the App Service identity Key Vault Secrets User.
- **Forced re-sign-in after idle** — users reporting they have to log back in after some idle period. Should be silently refreshing via `/auth/refresh`. Two likely causes to investigate: (1) tokens issued before Group C deploy (2026-06-04) never had a refresh token paired, so the first 401 falls through to sign-out — expected once per user only; (2) genuine bug in `APIClient.attemptRefresh` (refresh endpoint failure, refresh token not persisted, race with SignalR connection failure). Reproduce with a clean post-Group-C sign-in, leave idle 1+ hour, then try any action; check whether `TokenStore.shared.refreshToken` is non-nil and what the `/auth/refresh` call returns.
- **Smarter local message caching** — current `CacheService` stores messages with SAS URLs from the last fetch. Re-entering the chat after offline shows broken images because cached SAS expires. Consider: cache by plain URL + regenerate SAS on display; OR cache the rendered image bytes; OR shorten the SAS-URL lifetime in cache to match actual blob read SAS. Investigate, propose, implement.
- **Auto-import + chapter structure in book chat** — when a book is added (currently via Google Books search → title/author/cover), also pull its chapter / table-of-contents structure and surface it in the book's chat. Open design questions: chapter list source (Google Books volumeInfo doesn't carry TOC consistently — may need an alternative like Open Library, parsed EPUB metadata, or a manual editor for the club admin); chat UX (chapter sections, chapter-tagged messages, jump-to-chapter navigation, current-chapter indicator); DB schema (new Chapters table linked to Book; optional ChapterId on Message). Likely starts with a manual "add chapters" admin UI before automation.
- **Discussion-subject labels** — surface what each part of the chat is about. Auto where possible (LLM-extracted topics from recent message windows, e.g. "Character development of Sam", "Plot twist in Chapter 3", "Pacing critique") with optional manual override. Open design questions: granularity (label individual messages, label threads, label time ranges); UI (subject chips at the top of clusters, filter-by-subject view, jump-to-next-subject); cost/latency model (server-side batch summarization vs on-device — and which LLM); whether labels are first-class entities (DB table, can be edited / merged / deleted) or transient computed view; co-existence with the chapter structure backlog item (chapter is a coarse axis, subject is finer-grained — likely independent dimensions of the same conversation).
- **Chat scroll position preservation** — previously attempted via `ScrollAnchorStore` + `LazyVStack.onAppear` tracking but the position-detection was unreliable (LazyVStack render buffer is a superset of the visible viewport, `proxy.scrollTo(anchor:)` behavior was inconsistent). Revisit with iOS 17+ `ScrollPosition` / `scrollPosition(id:)` for precise viewport tracking and deterministic scroll restoration. Goal: restore exact scroll position on chat re-entry; "↓ N new" pill when scrolled away from bottom; notification tap always jumps to newest.
