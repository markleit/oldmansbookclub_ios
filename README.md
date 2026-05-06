# Old Man's Book Club

iOS app and ASP.NET Core API for a private book club — members browse a shared library of books, open per-book discussion threads, and chat in real time with text, voice, and photo messages.

## Features

- Sign in with Apple (JWT-based auth, token stored in Keychain)
- Book library with cover art sourced from the Google Books API
- Per-book chat threads with paginated message history
- Real-time messaging over Azure SignalR (text, voice, photo)
- Voice message recording and playback with duration display
- Photo messages uploaded directly to Azure Blob Storage via SAS URLs
- User profiles with custom nickname and avatar (uploaded to Blob Storage)
- Push notifications via APNs when new messages arrive
- Book status lifecycle: future / current / past
- Custom compact tab bar (Library, Profile)
- Simulator dev-login bypass for local development

## Tech Stack

### iOS
- Swift, SwiftUI (iOS 16.0+)
- MVVM architecture (`ObservableObject` / `@Published`)
- [dotnet/signalr-client-swift](https://github.com/dotnet/signalr-client-swift) for real-time chat
- `URLSession` for all REST calls
- `UNUserNotificationCenter` + `UIApplication.registerForRemoteNotifications` for push

### API
- ASP.NET Core 9, C#
- Entity Framework Core with Azure SQL (SQL Server provider)
- Azure SignalR Service (managed SignalR hub)
- Azure Blob Storage (media and avatar storage)
- APNs HTTP/2 push notifications
- JWT Bearer authentication
- Swagger / OpenAPI (Development only)

## Architecture

### System diagram

```
┌─────────────────────────────────────────────────────┐
│  iOS App (SwiftUI)                                  │
│                                                     │
│  LoginView ──► POST /auth/apple ──────────────────► │──┐
│                                                     │  │
│  LibraryView / BookDetailView                       │  │
│    │                                                │  │
│    ├─ REST (URLSession) ──► APIClient ──────────── ─│──┤
│    │                                                │  │
│    └─ WebSocket (SignalR) ──► ChatService ─────────►│──┤
│                                                     │  │
│  ProfileView ──► PUT (SAS URL direct upload) ──────►│──┤
└─────────────────────────────────────────────────────┘  │
                                                         │
         ┌───────────────────────────────────────────────┘
         ▼
┌─────────────────────────┐     ┌──────────────────────┐
│  ASP.NET Core API       │     │  Azure SignalR        │
│  (Azure App Service)    │◄───►│  Service             │
│                         │     └──────────────────────┘
│  /auth/*                │
│  /clubs, /books         │     ┌──────────────────────┐
│  /users/me              │◄───►│  Azure SQL Database  │
│  /media/upload-url      │     └──────────────────────┘
│  /notifications/register│
│  /hubs/chat (SignalR)   │     ┌──────────────────────┐
│                         │◄───►│  Azure Blob Storage  │
└─────────────────────────┘     │  (media + avatars)   │
         │                      └──────────────────────┘
         │
         ▼                      ┌──────────────────────┐
  APNs (push)  ────────────────►│  iOS device          │
                                └──────────────────────┘
```

### Two components

```
oldmansbookclub_ios/
  App/    — iOS SwiftUI application
  API/    — ASP.NET Core REST API + SignalR hub
```

### Authentication

1. User taps "Sign in with Apple" on `LoginView`.
2. Apple identity token + display name sent to `POST /auth/apple`.
3. `AppleTokenValidator` verifies the token with Apple's public keys.
4. API issues a signed JWT; iOS stores it in Keychain via `TokenStore`.
5. Every subsequent REST request sends `Authorization: Bearer <token>`.
6. SignalR WebSocket connections send the token as `?access_token=<token>` query param (the JWT middleware reads it for hub connections).

### Real-time chat

`ChatService` (singleton) wraps the SignalR Swift client. On entering a book's chat view:
1. `connect(bookId:)` opens a WebSocket to `/hubs/chat`.
2. Client invokes `JoinBook` hub method — server adds the connection to a SignalR group for that book.
3. Incoming `NewMessage` events are dispatched to `onMessageReceived` and appended to the view model on `MainActor`.
4. Outgoing messages are sent via hub methods (`SendTextMessage`, `SendPhotoMessage`, `SendVoiceMessage`) rather than REST, so all connected clients receive them immediately.

### Media upload flow

1. Client calls `POST /media/upload-url?clubId=<id>` (or `/media/avatar-upload-url`).
2. API generates a short-lived Azure Blob Storage SAS URL and returns it alongside the permanent `mediaUrl`.
3. Client `PUT`s the raw bytes directly to the SAS URL with the appropriate `Content-Type` and `x-ms-blob-type: BlockBlob` headers — no data passes through the API server.
4. Client sends the permanent `mediaUrl` in the chat message payload.

### JSON serialization

API uses `JsonNamingPolicy.SnakeCaseLower` throughout. `APIClient` mirrors this with `.convertToSnakeCase` encoding and `.convertFromSnakeCase` decoding, so no manual key mapping is needed.

## Architectural Decisions

### 1. Azure SignalR Service over self-hosted WebSockets

**Decision:** Use the managed Azure SignalR Service rather than running WebSocket connections directly on the API process.

**Why:** Azure App Service on the free/shared tiers has strict connection limits and no sticky sessions, which breaks stateful WebSocket servers. Azure SignalR offloads connection state entirely — the API just calls `Clients.Group(...).SendAsync(...)` and the service handles fan-out to all connected clients. The hub code stays simple and the API process stays stateless.

**Where this would be wrong:** Self-hosted apps (VMs, containers with a load balancer you control) where you can configure sticky sessions. Azure SignalR adds cost and a network hop; raw WebSockets are fine there.

### 2. SAS URLs for media upload — client uploads directly to Blob Storage

**Decision:** The API generates a short-lived Azure Blob Storage SAS URL and returns it to the client. The client PUTs bytes directly to Blob Storage; no media data passes through the API server.

**Why:** Routing multi-megabyte audio and photo uploads through an App Service instance would consume instance memory and egress bandwidth for work the storage layer handles natively. SAS URLs are scoped to a single blob with a short TTL (few minutes), so the client can't write anywhere outside the intended path.

**Where this would be wrong:** If you need server-side processing (transcoding, content moderation) before the file is stored. Then you want the data to land on the server first, or use a storage event trigger into a processing pipeline.

### 3. SQL (relational) over a document store

**Decision:** Azure SQL with EF Core rather than Cosmos DB or a document database.

**Why:** The data is naturally relational — users belong to clubs, books belong to clubs, messages belong to books and reference users. Enforcing these relationships at the database layer prevents orphaned records without application-level cleanup logic. EF Core migrations give an auditable schema history. For a small club app the query patterns are simple and SQL is a better fit than paying for Cosmos RU capacity.

**Where this would be wrong:** Very high write throughput (thousands of messages per second across many clubs) where SQL contention becomes a bottleneck, or if you need multi-region active-active writes. A document store with partition-per-club would scale further horizontally.

### 4. Push notifications only to offline users

**Decision:** When a new message arrives, APNs push is sent only to club members who are not currently connected to the SignalR group for that book.

**Why:** A user with the book open already receives the message via the `NewMessage` SignalR event in real time. Sending them a push notification too causes a redundant badge + sound while they're actively reading. The hub tracks active viewers in a `ConcurrentDictionary` and excludes them from the APNs token query.

**Where this would be wrong:** Multi-device scenarios where a user has the app open on one device but wants a notification on another. The current implementation keys on user ID, not device, so any active connection suppresses all their pushes. Worth revisiting if multi-device support is added.

## Repo Structure

```
.
├── project.yml                  # XcodeGen spec — source of truth for the Xcode project
├── OldMansBookClub.xcodeproj/   # Generated by XcodeGen (do not edit by hand)
├── App/
│   ├── OldMansBookClubApp.swift # @main entry point; AuthViewModel injected as environment object
│   ├── ContentView.swift        # Root TabView (Library / Profile)
│   ├── AppDelegate.swift        # APNs device token registration
│   ├── Info.plist
│   ├── Models/
│   │   └── Models.swift         # Club, Book, Message, User — Codable + Identifiable
│   ├── ViewModels/
│   │   ├── AuthViewModel.swift
│   │   ├── LibraryViewModel.swift
│   │   ├── BookViewModel.swift
│   │   └── ProfileViewModel.swift
│   ├── Views/
│   │   ├── LoginView.swift
│   │   ├── LibraryView.swift
│   │   ├── BookDetailView.swift
│   │   ├── AddBookView.swift
│   │   ├── MessageInputView.swift
│   │   └── ProfileView.swift
│   └── Services/
│       ├── APIClient.swift      # Singleton HTTP client; base URL switches on simulator target
│       ├── ChatService.swift    # SignalR connection management
│       ├── TokenStore.swift     # Keychain-backed JWT persistence
│       └── AudioRecorder.swift  # AVFoundation voice recording
└── API/
    ├── Program.cs               # App bootstrap: EF Core, SignalR, JWT, Swagger
    ├── BookClubApi.csproj
    ├── Controllers/
    │   ├── AuthController.cs    # POST /auth/apple, POST /auth/dev-login
    │   ├── ClubsController.cs
    │   ├── BooksController.cs   # CRUD + status + messages
    │   ├── MediaController.cs   # SAS URL generation
    │   ├── NotificationsController.cs
    │   └── UsersController.cs   # PATCH /users/me
    ├── Hubs/
    │   └── ChatHub.cs           # SignalR hub: JoinBook, SendTextMessage, SendPhotoMessage, SendVoiceMessage
    ├── Models/
    │   ├── Entities.cs          # EF Core entities: User, Club, Membership, Book, Message
    │   └── Dtos.cs              # Request/response records
    ├── Data/
    │   └── AppDbContext.cs
    ├── Services/
    │   ├── AppleTokenValidator.cs
    │   ├── BlobService.cs
    │   └── NotificationService.cs
    └── Migrations/
```

## Local Dev Setup

### API

Prerequisites: .NET 9 SDK, access to the Azure resources (or a local SQL Server).

```bash
cd API
dotnet run
```

The API listens on `http://localhost:5235` by default (see `Properties/launchSettings.json`).

`appsettings.Development.json` is gitignored. Retrieve current values from Azure:

```bash
az login
az webapp config appsettings list \
  --name oldmansbookclub-api \
  --resource-group <rg> \
  --output table
```

Then create `API/appsettings.Development.json` with the keys listed in the [Key Config](#key-config) section below.

Azure SQL has a firewall allowlist. If your IP is not already allowed:

```bash
az sql server firewall-rule create \
  --resource-group <rg> \
  --server <server-name> \
  --name My-Dev-IP \
  --start-ip-address <your-ip> \
  --end-ip-address <your-ip>
```

### iOS (simulator)

Prerequisites: macOS with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate          # regenerates OldMansBookClub.xcodeproj from project.yml
open OldMansBookClub.xcodeproj
```

Build and run the `OldMansBookClub` scheme on any iOS simulator.

The app detects `#if targetEnvironment(simulator)` at compile time and points `APIClient` and `ChatService` at `http://localhost:5235` instead of the Azure endpoint. `NSAllowsLocalNetworking` is enabled in the app plist so HTTP to localhost is permitted.

On the login screen a **Dev Login (Simulator)** button appears (simulator builds only). Tapping it calls `POST /auth/dev-login` — an endpoint that only exists when the API runs in `Development` mode — and logs in without requiring a real Apple account.

### CI

GitHub Actions runs on push to `main` and on pull requests:
- `.github/workflows/ci.yml` — installs XcodeGen, generates the project, builds for iOS simulator.
- `.github/workflows/deploy-api.yml` — builds and deploys the API to Azure App Service.

## Key Config

`API/appsettings.Development.json` — not committed, must be created locally:

```json
{
  "ConnectionStrings": {
    "DefaultConnection": "<Azure SQL connection string>"
  },
  "Azure": {
    "SignalRConnectionString": "<Azure SignalR Service connection string>",
    "BlobStorageConnectionString": "<Azure Storage connection string>"
  },
  "Jwt": {
    "Secret": "<signing key>",
    "Issuer": "<issuer>",
    "Audience": "<audience>"
  },
  "Apns": {
    "TeamId": "<Apple Team ID>",
    "KeyId": "<APNs key ID>",
    "PrivateKey": "<p8 key contents>",
    "BundleId": "com.example.oldmansbookclub"
  }
}
```

### Azure resources required

- Azure SQL Database (SQL Server)
- Azure SignalR Service
- Azure Blob Storage account (container for media, container for avatars)
- Azure App Service (API hosting)
- APNs key (.p8) from Apple Developer portal

## Deployment

The API is deployed to Azure App Service (Norway East, Visual Studio subscription) at `https://oldmansbookclub-api.azurewebsites.net`.

Deployment is triggered by the `deploy-api.yml` workflow on push to `main`.

EF Core migrations run automatically in a background task 5 seconds after the app starts, so the health probe at `GET /health` can succeed before migrations complete. Migration failures are logged but do not crash the process.

The bundle ID `com.example.oldmansbookclub` is a placeholder — replace it in `project.yml` and re-run `xcodegen generate` before submitting to the App Store.
