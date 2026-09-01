# Dev & test environments (#120 — DONE)

This document describes how OMBC is developed and tested across simulator and
device, and how dev/test traffic is isolated from production. See also
`docs/ARCHITECTURE.md` for the system overview and `CLAUDE.md` for day-to-day
build commands.

## The problem this solves

Historically the API host was compile-time (`#if targetEnvironment(simulator)`
in both `APIClient` and `ChatService`), so a physical device could **only**
reach production. Anything device-only — push, CarPlay, background wake,
outage recovery — could only be exercised against real member data, and a
client change depending on unshipped server behaviour was untestable until
that server change had already deployed to prod.

Separately, local dev used to run against the **production Azure SQL
database** and share production's storage, SignalR, and APNs — because there
was no isolated alternative at all.

These were two independent problems (client wiring vs. server data), tracked
together as #120 and split into two halves, both now done.

## Half B — configurable host (DONE)

`App/Services/ServerEnvironment.swift` resolves the API host at runtime:

- **RELEASE** — compiles to the production literal (`ServerEnvironment.productionURLString`).
  No lookup, no storage read, no way to change it. A shipped build is
  byte-identical to before this existed.
- **DEBUG** — a runtime value, backed by `UserDefaults` (`debugServerBaseURL`),
  editable via `DebugServerControl` — the same UI embedded in both `LoginView`
  (pre-auth) and `SettingsView` → "Server (Debug)" (post-auth).

Both `APIClient` and `ChatService` read the same resolver. **Any new network
caller must too** — pointing only one at a new host silently leaves the other
on production, which is worse than not switching at all.

### Why the control lives on LoginView too

`Settings` is only reachable once signed in. A fresh device install defaults
to production, and production returns 404 for `/auth/dev-login` outside
Development (`AuthController.cs`, `#if !DEBUG return NotFound()`). Sign in
with Apple can't bootstrap it either — the `.dev` bundle id isn't what
`Apple:BundleId` validates server-side. Without a pre-auth copy of the host
control there would be no way to ever reach a local server on a fresh
install. `DebugServerControl` is deliberately Form-agnostic (not `Section`-
specific) so it drops into both a `Form` (Settings) and a plain `VStack`
(LoginView).

### Presets

- **Production** — the hardcoded prod URL.
- **Localhost** — `http://localhost:5235`. Correct for the **simulator only**;
  on a physical device this means the device itself, not the Mac, and fails
  immediately. That's expected, not a bug.
- **Dev Machine** — `ServerEnvironment.devMachineURLString`, the dev Mac's LAN
  IP. Update this constant by hand when the network changes
  (`ipconfig getifaddr en0`) — it's a convenience preset, not a source of
  truth. This is the one to use from a physical device.

Applying a host that differs from the current one signs you out: a JWT is
only valid on the server that minted it, so carrying credentials across a
switch would 401 in a way that looks like an auth bug rather than a
config issue.

## Device isolation — a separate `.dev` app (DONE)

A DEBUG build installs under a **different bundle id**,
`com.markleit.oldmansbookclub.dev`, so it coexists on a device with the real
App Store install instead of replacing it and wiping its container. This is
controlled by a build setting (`OMBC_BUNDLE_SUFFIX` in `project.yml`), not a
hardcoded id.

Consequences of the separate identity:

- **Separate auth.** Sign in with Apple requires the production bundle id, so
  the `.dev` app can only authenticate via **Dev Login** (`AuthViewModel.devLogin()`,
  `#if DEBUG`) against a `dev_*` user (`AuthController.DevLogin`, subject =
  `"dev_" + displayName.lowercased()`).
- **Separate entitlements.** `com.apple.developer.carplay-audio` is a *managed*
  entitlement Apple grants per App ID, and it's only granted to the
  production id. The `.dev` App ID doesn't have it, so Debug signs against
  `App/OldMansBookClub.Debug.entitlements` (identical to the production
  entitlements minus that one key). **Consequence: the `.dev` app cannot test
  CarPlay.** For a CarPlay debug session with the debugger attached, override
  both settings together to build Debug with the real identity:
  ```
  xcodebuild ... OMBC_BUNDLE_SUFFIX="" CODE_SIGN_ENTITLEMENTS=App/OldMansBookClub.entitlements
  ```
- **Separate push token.** A DEBUG build registers a sandbox APNs token
  against whichever user is signed in — now the `dev_*` user, not your real
  account — so it does not disturb push delivery to the App Store app on the
  same device (previously, before this bundle id split, it did: see the #25
  note below).
- **Visually distinct.** Debug gets its own display name suffix (`(DEV)`) and
  its own icon (`App/Assets.xcassets/AppIcon-Debug.appiconset` — a plain red
  border + "DEV" banner over the real icon, deliberately unpolished) so the
  two apps are never confused on a home screen.

## Half A — data isolation (DONE)

Before Half A, the local API was a different front end onto the **same**
backing services as production:

| Service | Local dev used to use | Risk |
|---|---|---|
| Azure SQL (`bookclubdb`) | **Production**, directly | Startup ran EF migrations against prod; test writes were real |
| Azure Blob Storage | Production `oldmansbookclubstore` | Test uploads landed in the real container |
| APNs | Production credentials | A message from a dev/test account pushed real devices |
| Azure SignalR | Shared backplane with prod (deliberate — see `Program.cs`) | A local hub invoke could route to the Azure server instead, or vice versa |

None of that is true anymore — see the table below. GitHub (the Feedback
feature) still uses the production PAT/repo in dev; that wasn't in scope for
Half A and test feedback still files real issues.

**The old standing guardrail — test in "Test Club" only — is no longer load-
bearing for anything pointed at Localhost/Dev Machine**, since that traffic
no longer touches the production database, storage, SignalR, or APNs at all.
It still applies whenever a client is deliberately pointed at the Production
preset (that's the point of that preset — real everything, real audience).

### The key architectural point: this is a config change, not a client change

All four things being isolated here — DB, SignalR, Blob, APNs — are properties
of *which API backend the client is talking to*, invisible to the client
itself. The client already has exactly one relevant knob, shipped in Half B:
`ServerEnvironment`'s Production / Localhost / Dev Machine switch. Half A's
entire job is to make sure what's actually running behind Localhost / Dev
Machine (`API/appsettings.Development.json`, gitignored) points at isolated
resources instead of production ones. **No new client-side switching is
needed** — pointing at Production still gives the real deployed app with real
everything (this is what preserves using the simulator as a prod tester);
pointing at Localhost / Dev Machine gives the fully isolated stack below.

| | Client → "Production" | Client → "Localhost" / "Dev Machine" |
|---|---|---|
| API | Deployed Azure app (West US 3) | Local `dotnet run` |
| DB | `bookclubdb` | `bookclubdb-dev` |
| SignalR | Azure SignalR Service | In-process (`AddSignalR()`, no Azure resource) |
| Blob | `oldmansbookclubstore` | Second real storage account (`oldmansbookclubdev`) |
| APNs | Real, sends | No-op — logs instead of calling Apple |

### Decisions and outcomes (built and verified 2026-08-22)

**1. SignalR — dev switched to in-process `AddSignalR()`, no Azure resource.**
`Program.cs` now branches on `builder.Environment.IsDevelopment()`: production
keeps `.AddAzureSignalR(...)` (needed across multiple App Service instances);
dev gets plain `AddSignalR()`. The shared-backplane design predated Half B —
its own comment explained it existed so a simulator (local) and a physical
device (previously *forced* onto production) could reach each other in real
time, the only way to bridge two different API deployments. Half B removed
that constraint, so in-process SignalR gives full isolation *and* keeps
sim ↔ device real-time, since both now connect to the same local process.
**Verified:** startup log went from several `ServiceConnection...connected`
lines plus a hub-binding line to zero Azure SignalR log output at all; a real
message sent from the simulator produced a persistent local socket
(`OldMansBookClub ↔ BookClubApi, 127.0.0.1:5235`) and landed in `bookclubdb-dev`.

**2. APNs — no-op in dev, real only via the Production preset.**
`NotificationService.SendToAllAsync` — the single choke point all three
public send methods (`SendJoinRequestNotificationAsync`,
`SendJoinResponseNotificationAsync`, `SendNewMessageAsync`) already funneled
through — now checks `Apns:Enabled` (config, default `true`) before doing any
APNs work and returns early if it's `false`. Dev's user-secrets set it
`false`. **Verified:** added a second dev user as a club member with a
real-format (fake) device token, sent a live message, and the log showed
`Apns:Enabled=false — skipping push to 1 device(s)` with no HTTP call to
Apple attempted at all — no delivery line, no network error, nothing sent.

**3. Blob — a second real Azure Storage account, not Azurite.**
Checked `BlobService.cs:91,164`: SAS generation goes through
`GetUserDelegationKeyAsync` (Azure AD user-delegation SAS), which Azurite
doesn't support (account-key SAS only) — using it would mean permanently
forking `BlobService`. Created `oldmansbookclubdev` instead, matching prod's
two containers exactly: `club-media` (private) and `avatars` (`blob` public
access — confirmed prod's account has `allowBlobPublicAccess: true` and
matched it; **new storage accounts default this to `false`**, which silently
no-ops a public container creation with exit code 0 — caught by re-checking
the container rather than trusting the CLI's exit status).

**Correction (2026-09-01):** the account/containers/secret described above
were provisioned, but `BlobService`'s constructor was never actually switched
to use them — it stayed hardcoded to `oldmansbookclubstore` for every
environment, so every "isolated" dev/local media send had in fact been
landing in production blob storage the whole time despite this section
marking the work "verified." Root cause: the IAM role grants
(`Storage Blob Data Contributor` + `Storage Blob Delegator`) needed for
`GetUserDelegationKeyAsync` to work were granted on `oldmansbookclubstore`
only — never on `oldmansbookclubdev` — so switching `BlobService` without
first granting those roles would have 403'd every media send in dev instead
of isolating it. Fixed in `fix/dev-blob-isolation`: role grants added, and
`BlobService`'s constructor now branches on `IHostEnvironment.IsDevelopment()`
the same way `Program.cs`'s SignalR setup does.

**4. Seed data — `/admin/seed-baseline`, not a sanitized snapshot.**
Turned out smaller than scoped: `AuthController.DevLogin` already
auto-creates a club and joins the calling user as club admin the moment
`bookclubdb-dev` has zero clubs, so seeding "users/memberships" was already
solved. The actual gap was books — a fresh DB has none, so Library looks
empty after the first Dev Login. Added `POST /admin/seed-baseline`
(`[AllowAnonymous]` + an `IsDevelopment()` check, same pattern as the
pre-existing `seed-join-request`, so it 404s outright on a Release/production
build regardless of any header) — ensures one book per status
(current/future/past) in whatever club already exists. **Verified
idempotent** by calling it twice: first call created all 3 books, second
created none and left them untouched. The pre-existing `/admin/seed-messages`
(unchanged) still handles dropping sample messages into a book.

### What was built

1. **`bookclubdb-dev`** — second Basic-tier Azure SQL database on the existing
   server. Prod is Azure SQL Database (evergreen PaaS, no fixed version to
   match) and there is no native ARM64 SQL Server engine (Microsoft: container
   images are x86-64-only, Rosetta explicitly unsupported; Azure SQL Edge, the
   old ARM path, retired 2025-09-30) — a second real Azure DB has zero engine
   drift, unlike any local/container option. ~$5/month. **First-ever
   start-from-empty run of the full migration history: all 29 migrations
   applied cleanly, 14 tables, correct schema** — previously only ever
   verified incrementally against prod as each migration shipped.
2. **`oldmansbookclubdev`** storage account, West US 3, with `club-media` and
   `avatars` containers matching production's access levels.
3. **Secrets migration** — `API/appsettings.Development.json` is now just
   logging config; all 18 values (SQL/Storage/SignalR/APNs/JWT/GitHub/etc,
   repointed at the new dev resources where applicable) live in
   `dotnet user-secrets` instead. `BookClubApi.csproj` carries the new
   `UserSecretsId` (the only piece of this that isn't itself a secret, so the
   only piece that needed to land in git). Verified by starting the API with
   the plaintext file stripped down and confirming it still resolved every
   value correctly.
4. **`Program.cs`** SignalR branch, **`NotificationService`** `Apns:Enabled`
   gate, **`AdminController.SeedBaseline`** — see decisions above.

**Not built — deferred, not blocking:** the firewall-upsert script (chasing
the dev machine's rotating egress IP is unchanged from before Half A; it just
no longer carries prod-migration risk if forgotten, so the urgency dropped).
File as a small follow-up if the manual `az sql server firewall-rule create`
step becomes annoying enough.

## Scenario matrix (current, post Half A + Half B + #130)

| # | Client | Host | Data / backend | Account | Status |
|---|---|---|---|---|---|
| 1 | Simulator | Localhost (default) | `bookclubdb-dev`, in-process SignalR, dev storage, no real APNs | "Dev Login (Debug)" / "Simulate…" buttons on `LoginView` — no real Apple ID | Everyday dev — **fully isolated** |
| 2 | Simulator | Production | Real everything | Your real Apple ID, **signed in at the Simulator's OS level first** (Settings app) | Reproduce a prod bug — see gotchas below |
| 3 | Device (`.dev`) | Dev Machine (LAN IP) | `bookclubdb-dev`, isolated | "Dev Login (Debug)" / "Simulate…" buttons — no real Apple ID | **Fully isolated** — device-only features against unshipped server changes, zero prod contact |
| 4 | Device (`.dev`) | Production | Real everything | Your real Apple ID (already signed in at the OS level on a real device, nothing extra to set up) | Device testing against prod without touching the App Store app — see gotchas below |
| 5 | Device, App Store | Production | Real everything | Your real Apple ID | What users have — never disturbed by any of the above |

Scenarios 1 and 3 are the ones Half A changed: they used to share production's
database, storage, SignalR, and APNs; now they touch none of it. 2, 4, and 5
are deliberately real, by pointing at the Production preset — that's what
preserves using the simulator (or a device) as a prod tester.

### Gotchas for scenarios 2 and 4 (Production + DEBUG build)

**Sign In with Apple needs two one-time fixes, both now done (#130):**
Every DEBUG build (simulator or device) compiles with bundle id
`<bundleId>.dev` (the #120 device-isolation split). Production's Apple
Sign-In validation used to check the identity token's audience against only
the real bundle id, so a `.dev`-audience token always 401'd — scenarios 2 and
4 didn't actually work despite being documented here, until:
1. **Server**: `AuthController`/`AppleTokenValidator` now accept both the
   real and `.dev` bundle ids as valid audiences (commit `ed33d49`, deployed
   2026-08-27).
2. **Apple Developer portal** (one-time, manual): the `.dev` App ID's Sign In
   with Apple capability must be **grouped** under the primary App ID
   (`com.markleit.oldmansbookclub`) as its primary App ID. Without this,
   Apple mints a *different* `sub` per bundle id even for the same real
   Apple ID — you'd land on a second, empty account instead of your real
   one. Done 2026-08-27 (Identifiers → primary App ID → Sign In with Apple →
   "Enable as a primary App ID"; `.dev` App ID → Sign In with Apple → "Group
   with an existing primary App ID..." → select the primary).

**A Simulator with no real Apple ID signed in silently fakes it.** If you
tap Sign In with Apple on a Simulator that has no Apple ID configured at the
OS level (Settings app shows no account at the top), iOS doesn't error —
it substitutes Apple's built-in synthetic test identity (name literally
"Simulator", no email) and hands the app a valid-looking token for it. The
server has no way to distinguish this from a real sign-in, so it happily
creates a brand-new, real `User` row for it. This is almost certainly how
the club ended up with multiple "Simulator" member accounts over time — each
one a leftover from a DEBUG-against-Production test run before the
Simulator had a real Apple ID signed in. **Before testing scenario 2, sign
the Simulator into your real Apple ID via Settings first** (same as a
physical device) — otherwise every test run mints another throwaway
account.

**Pushing to yourself from a second device on the same account doesn't
work, and isn't a bug.** `NotificationDispatch` excludes the sender's
`UserId` from the push fan-out entirely (by design — you shouldn't get
pushed your own message). Since there's currently one `DeviceToken` per
*user* (not per device — #25), a sim and a phone signed into the same real
account are, as far as the server's concerned, the same recipient being
excluded — the phone will never get a push for a message the sim (or any
other device on that account) sent, even though the send/receive path
itself (SignalR, DB, in-app display) works fine. Testing push delivery
end-to-end needs either a second real club member to send from, or #25
landing with per-device (not per-account) fan-out exclusion — see the
2026-08-27 comment on #25 for the design discussion (not yet settled).

## Looking ahead: a CI regression / build-acceptance suite

Half A's isolated stack is what makes an automated regression pass possible
without every CI run touching production. This is future work, not yet
scoped in detail, but worth stating the constraints now:

**A GitHub Actions runner is not this dev machine.** `ci.yml` currently only
builds (`xcodebuild ... clean build`, simulator only, no test target — this is
also #32, "No test target"); it doesn't touch the API or a database at all.

**#32 partially done (2026-09-01):** a `OldMansBookClubUITests` XCUITest
target now exists (`UITests/`), driving the app through its accessibility
hierarchy (element identifiers, not screen coordinates — coordinate-based
simulator automation proved unreliable for anything beyond a single
confirmed tap). Covers text send, text send with immediate backgrounding,
and voice send, run locally against `bookclubdb-dev`. **Not wired into
`ci.yml`** — that still only builds — because the questions below are
unresolved, and running it locally already answers "does the send path
actually work," which was the immediate need.

For an automated suite to exercise real client-server behaviour in CI, the
runner needs to reach an isolated backend the same way this Mac does today,
which raises questions worth deciding before building the suite, without
blocking anything already done above:

- **Reachability** — a GitHub-hosted runner's egress IP isn't static, so the
  firewall-upsert approach that works for one dev machine doesn't generalize
  to CI. Likely answer is `AllowAzureServices` doesn't help (GitHub runners
  aren't Azure), so either a narrower Actions-specific firewall rule, or
  running the API itself *inside* the CI job (a service container / `dotnet
  run` in the workflow) against `bookclubdb-dev` over the same connection
  string used locally.
- **Reset between runs** — CI needs deterministic starting state, which is
  exactly what the Half A seeder is for; it should be designed to be safely
  re-runnable (truncate-and-reseed, not just insert) from the start rather
  than retrofitted later.
- **Isolation between concurrent runs** — if two PRs run CI at once against
  the same `bookclubdb-dev`, they'd collide. Worth deciding later whether
  that's solved with per-run schema/database isolation or just accepting
  serialized CI (matches the existing `deploy-api.yml` concurrency group,
  which already serializes for a related reason).
- **What "regression suite" covers** — likely a mix of API integration tests
  (hitting real endpoints against `bookclubdb-dev`) and iOS UI/unit tests
  (`#32`), not yet designed.
- **Must be runnable manually, not CI-only.** A developer needs to run the
  exact same pass locally against `bookclubdb-dev` before pushing — not a
  separate, weaker check that only exists inside a GitHub Actions job. This
  means the suite should be built as a standalone, plain script/command
  (e.g. a shell script or `dotnet test` / `xcodebuild test` invocation with no
  GitHub-specific assumptions baked in) that `ci.yml` calls, rather than logic
  written directly into the workflow YAML. CI becomes just "run the same thing
  automatically," not a second implementation.

`/admin/seed-baseline` was already built idempotent (matches on `(ClubId,
Title)` rather than inserting blindly) and the dev connection details already
live in one place (`dotnet user-secrets`) — both ahead of this suite actually
being scoped, so neither should need rework when it is.

## Azure region move: Norway East → West US 3 (DONE)

Not part of #120, discovered alongside it. App Service ran in **Norway East**
while Azure SQL ran in **West US 2** — not a design decision, just that West
US App Service capacity was unavailable when the app was first deployed.

**Capacity turned out narrower than expected.** `az appservice list-locations`
listed West US / West US 2 / West US 3 as all offered, but attempting to
create a plan found **zero quota** in West US and West US 2 for this
subscription — only **West US 3** succeeded. (A quota increase request for
West US 2, which would co-locate with the database, is a possible future
follow-up; not filed.)

**The gotcha that would have silently broken a naive recreate:** production
had no `Azure:SignalRConnectionString` or Blob connection string in app
settings — it authenticates to both via a **system-assigned managed
identity** with three role assignments (SignalR App Server; Storage Blob Data
Contributor; Storage Blob Delegator). A recreated App Service gets a new
identity and zero role assignments; missing this breaks chat (no SignalR
auth) and degrades every media URL to a plain, unsigned link.

**What was done:** wrote `recreate_ombc_api.sh` (settings → runtime config →
identity → all 3 roles → deploy, ~70s end to end) and rehearsed it twice
against a throwaway name on a West US 3 plan before touching production — the
deploy workflow (`deploy-api.yml`) needed no changes, since it authenticates
via a service-principal (`AZURE_CREDENTIALS`), not a publish profile, and
targets the app by name + resource group. Cutover: deleted the Norway app,
immediately recreated `oldmansbookclub-api` on the West US 3 plan from the
proven script. **Downtime ~10.5 minutes** — mostly Azure's internal
hostname-to-cluster propagation after reclaiming the name, not the script
itself, which is worth expecting if this is ever done again.

**Result, measured:** `/health/ready` minus `/health` (isolates the DB round
trip, cancels out the caller's own distance to each region) dropped from
**588ms (Norway↔West-US-2) to ~0ms (West-US-3↔West-US-2)**. Verified further
with a real end-to-end message + push notification after cutover.

**Cleanup:** the rehearsal app and the empty Norway plan (`oldmansbookclub-plan`)
were both deleted afterward — the marginal rollback benefit of an idle empty
plan is small (it only saves the ~15s `az appservice plan create` step; the
config/identity/role replay is the same work either way), so it wasn't worth
the ongoing ~$12.75/month. If this region is ever revisited, `recreate_ombc_api.sh`
is the reusable tool (kept in `docs/` scratchpad conventions — copy it back
into the repo if a similar move happens again).

**Lesson banked:** `az webapp delete` auto-deletes the last app's plan too,
unless `--keep-empty-plan` is passed. Always pass it when deleting an app you
don't want to lose the plan for.
