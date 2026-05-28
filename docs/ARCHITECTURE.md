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

- **Simulator (Debug):** `http://localhost:5235`
- **Device / TestFlight / App Store:** `https://oldmansbookclub-api.azurewebsites.net`

Controlled via `#if targetEnvironment(simulator)` in `APIClient.swift`.

---

## API

**Framework:** ASP.NET Core 10  
**Runtime:** Linux container on Azure App Service (Norway East)  
**Database ORM:** EF Core with SQL Server — migrations run automatically on startup (5 s delay)

### Controllers

| Controller | Route | Purpose |
|------------|-------|---------|
| `AuthController` | `/auth` | Sign in with Apple, demo/dev login, account deletion |
| `ClubsController` | `/clubs` | Club CRUD, public listing, membership |
| `BooksController` | `/books` | Book CRUD per club |
| `ChatHub` | SignalR | Real-time messaging |
| `MediaController` | `/media` | SAS URL generation for blob uploads |
| `NotificationsController` | `/notifications` | APNs device token registration |
| `AdminController` | `/admin` | Join requests, member management, reports |

### Services

| Service | Purpose |
|---------|---------|
| `AppleTokenValidator` | Validates Sign in with Apple identity tokens; exchanges authorization code for refresh token; revokes token on account deletion |
| `BlobService` | Generates upload/read SAS URLs for Azure Blob Storage |
| `NotificationService` | Sends APNs push notifications (join requests, approvals, new messages) |

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
 │◄─ JWT (365-day) ───────────│                           │
 │                            │                           │
 │  (all subsequent requests use Bearer JWT)              │
```

On account deletion, the stored refresh token is revoked via `https://appleid.apple.com/auth/revoke` so the app no longer appears under the user's Apple ID settings.

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

Chat messages are sent and received via Azure SignalR Service (Managed Identity connection).

```
iOS sender                API (ChatHub)              iOS receivers
    │                          │                           │
    ├─ SendMessage ────────────►│                           │
    │                          ├─ Validate (approved,      │
    │                          │   member, not blocked)    │
    │                          ├─ Save to SQL              │
    │                          ├─ Broadcast ───────────────►│
    │◄─ Echo (own message) ────│                           │
```

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
| `deploy-api.yml` | Push to `main` with changes in `API/**` | Dotnet publish → zip → Azure Web App deploy (~2 min) |
| `ci.yml` | Push to `main` / PR | XcodeGen → build for iOS simulator |
| `backup.yml` | Daily 3 AM UTC | Export Azure SQL to BACPAC in blob storage (30-day retention) |

---

## Local Development

### API
```bash
cd API
dotnet run
# Requires API/appsettings.Development.json (not in repo) with:
# - ConnectionStrings:DefaultConnection
# - Azure:SignalRConnectionString
# - Jwt:Secret / Issuer / Audience
# - Apns:KeyId / TeamId / PrivateKey
# - Apple:BundleId
```

### iOS
```bash
brew install xcodegen
xcodegen generate
open OldMansBookClub.xcodeproj
# Build to simulator → tap "Dev Login (Simulator)"
```

> **Note:** After every `xcodegen generate`, re-select the signing team in Xcode → target → Signing & Capabilities.
