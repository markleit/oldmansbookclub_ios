# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Old Man's Book Club** — iOS SwiftUI app + ASP.NET Core 10 API. Single club, multiple books, per-book discussion threads with real-time chat.

- **iOS deployment target:** iOS 16.0+
- **Bundle ID:** `com.markleit.oldmansbookclub`
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

iOS is SwiftUI + MVVM under `App/` (`Models/`, `ViewModels/`, `Views/`, `Services/`); the API is
ASP.NET Core under `API/` (`Controllers/`, `Hubs/`, `Models/`, `Data/`, `Services/`). Read the tree
for specifics — only the non-obvious bits are worth recording here:

- `App/Services/ServerEnvironment.swift` — resolves the API host. In DEBUG it is a runtime value
  (Settings → "Server (Debug)"), so a device can be pointed at a laptop or a staging slot; in
  RELEASE it compiles to the production literal. Both `APIClient` and `ChatService` MUST go
  through it — if only one switches, chat silently keeps talking to prod (#120, done)
- `App/Services/APIClient.swift` — singleton HTTP client; base URL comes from `ServerEnvironment`
- `App/Services/ChatService.swift` — SignalR client, an actor
- `App/Services/TokenStore.swift` — JWT persistence in the Keychain
- `API/Migrations/` — migrations run automatically on API startup. Local dev points at
  `bookclubdb-dev`, an isolated database (#120, done) — see `docs/DEV_TEST_ENVIRONMENTS.md`

## Auth

Sign in with Apple → Apple identity token sent to `/auth/apple` → API validates token, returns JWT → stored in Keychain via `TokenStore`. JWT passed as `Authorization: Bearer` header on all authenticated requests, and via `?access_token=` query param for SignalR WebSocket connections.

## JSON serialization

The API uses `JsonNamingPolicy.SnakeCaseLower` — all JSON keys are snake_case in both directions. The iOS `APIClient` encodes with `.convertToSnakeCase` and decodes with `.convertFromSnakeCase` to match.

## Dev & test environments

**See `docs/DEV_TEST_ENVIRONMENTS.md` — the canonical reference** for how the
API host is configured (runtime in DEBUG, hardcoded in RELEASE), how the
`.dev` device app is isolated from the App Store app, the isolated dev
backend (`bookclubdb-dev`, in-process SignalR, dev storage, no-op APNs — #120,
done), the simulator/device scenario matrix, and the completed Azure region
move. Don't duplicate that content here or in memory — update the doc and
link to it.

Quick start: `cd API && dotnet run`, build+run in the simulator, tap "Dev
Login (Debug)" on the login screen. Azure SQL firewall must allow your dev
machine's egress IP (`az sql server firewall-rule create` if it changes).

## Key configuration (not in repo)

`API/appsettings.Development.json` — gitignored, contains:
- `ConnectionStrings:DefaultConnection` — Azure SQL Server
- `Azure:SignalRConnectionString` — Azure SignalR Service
- `Jwt:Secret`, `Jwt:Issuer`, `Jwt:Audience`
- Azure Blob Storage connection string
- APNs credentials
- `GitHub` — PAT + owner/repo for the in-app Feedback feature and the dev backlog (server-only; never ships in the app)

## Known gaps / next up

The dev backlog now lives in **GitHub Issues** (`markleit/oldmansbookclub_ios`) — that's the source of truth, with labels `bug` / `enhancement` / `perf` / `tech-debt`. This slim index is a SNAPSHOT (2026-08-22) to keep the list in AI context; it goes stale as issues close — re-derive with `gh issue list` when it matters, and fetch full notes with `gh issue view <N>`. (The in-app Feedback view filters by the `feedback` label, so these dev labels stay out of the user-facing list.) **Security items are deliberately NOT filed as public issues (the repo is public) — they live inline below.**

**Bugs**
- #25 — Single `DeviceToken` per user → `UserDevices` table (also blocks cross-device badge sync)
- #119 — Unread counts: heard-state divergence (server vs device) — FIXED in 1.9.1, awaiting release
- #121 — Verify on device: does the app recover from a server outage without backgrounding?

**Features / enhancements**
- #14 — Saved Messages UX rework (explicit forward + destination picker)
- #15 — Smarter local message caching (SAS expiry breaks cached images)
- #16 — Auto-import + chapter structure in book chat
- #17 — Discussion-subject labels
- #18 — Apple Watch companion
- #20 — Offline / no-service UX
- #22 — Saved Messages indexing & auto title/label
- #51 — Transcribe-on-send for own voice messages
- #83 — Photo/video viewing & multi-photo sharing (`feedback`)
- #122 — Chat photos cropped to a square (`feedback`) — FIXED in 1.9.1, awaiting release
- #98 — Enhance add-book search quality (metadata accuracy)

**Perf**
- #9 — Voice-bubble rendering: re-render storm + layout

**Tech debt**
- #30 — Observability: App Insights + structured logging
- #31 — Blob hygiene: lifecycle policy + date-prefixed naming
- #32 — No test target
- #33 — `BookViewModel` ~8 responsibilities; split large views
- #34 — `APIClient`: unify 20+ ad-hoc `URLRequest` builders
- #36 — Schema niceties (`Membership` natural PK deferred from 1.9.0)
- #120 — No test environment: local dev ran against the prod DB — CLOSED 2026-08-22 (isolated `bookclubdb-dev` + storage, in-process SignalR, no-op APNs, idempotent seeder; see `docs/DEV_TEST_ENVIRONMENTS.md`)
- #123 — Microsoft.OpenApi advisory + transitive deps unwatched — DONE 2026-08-21 (advisory cleared, lock file added, Dependabot alerts/security updates enabled, NuGet audit now fails the build)

### Security backlog (kept private — NOT filed as public GitHub issues)

The repo is public, so these stay here only. Still-open items from the 2026-06-04 review plus the secrets migration:

- **`AdminController` has no class-level `[Authorize]`** (H8) — authorization relies on scattered inline `IsAdminAsync()` checks; one missed action is a hole (e.g. `seed-messages` is reachable unauthenticated and gated only by an `X-Seed-Key` header). Add `[Authorize]` at the class and `[AllowAnonymous]` only where intended.
- **`ClubsController.AddMember` is open to any club member** (H9 remainder) — a regular member can mass-add accounts. The book mutations were locked down in Group A; `AddMember` was not. Require club-admin.
- **7-day read SAS** (M2) — a media URL handed to a client keeps working for 7 days after the user is removed/blocked or the message is deleted (SAS can't be individually revoked). Cut read-SAS validity to ~1 hr.
- **SignalR auth via `?access_token=` query** (M19) — token lands in App Service / IIS request logs. Move to a header or accept + document the risk.
- **`/notifications/register` doesn't validate token format** — accepts any string up to 512 chars. Enforce 64-hex APNs format.
- **Upload SAS has no Content-Type or size restriction** — client claims `audio/mp4` but anything can be PUT; pair with the "Max message size limits" item (#19) for the size half.
- **Secrets out of `appsettings.Development.json`** — currently SQL/SignalR/Blob/Notification Hub/APNs/JWT/GitHub secrets sit in plaintext on disk (gitignored, but one accidental `git add -A` from disaster). Migrate dev secrets to `dotnet user-secrets`; production reads from Azure Key Vault via managed identity. Requires creating the Key Vault, populating it, and granting the App Service identity Key Vault Secrets User. (The GitHub PAT added for the Feedback feature should be rotated and moved here too.)
