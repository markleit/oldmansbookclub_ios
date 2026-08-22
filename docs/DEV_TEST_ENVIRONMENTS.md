# Dev & test environments (#120)

This document describes how OMBC is developed and tested across simulator and
device, what's shared with production today, and the plan to stop sharing it.
See also `docs/ARCHITECTURE.md` for the system overview and `CLAUDE.md` for
day-to-day build commands.

## The problem this solves

Historically the API host was compile-time (`#if targetEnvironment(simulator)`
in both `APIClient` and `ChatService`), so a physical device could **only**
reach production. Anything device-only — push, CarPlay, background wake,
outage recovery — could only be exercised against real member data, and a
client change depending on unshipped server behaviour was untestable until
that server change had already deployed to prod.

Separately, local dev has always run against the **production Azure SQL
database** (`API/appsettings.Development.json`), because there's no local or
dev database at all.

These are two independent problems (client wiring vs. server data), tracked
together as #120 and split into two halves below.

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

## What's still shared with production (Half A — PLANNED, decisions made, not built)

Until Half A is built, the local API is a different front end onto the
**same** backing services as production:

| Service | Local dev uses | Risk |
|---|---|---|
| Azure SQL (`bookclubdb`) | **Production**, directly | Startup runs EF migrations against prod; test writes are real |
| Azure Blob Storage | Production `oldmansbookclubstore` | Test uploads land in the real container |
| APNs | Production credentials | A message from a dev/test account pushes real devices |
| Azure SignalR | Shared backplane with prod (deliberate — see `Program.cs`) | A local hub invoke may route to the Azure server instead, or vice versa |
| GitHub (Feedback feature) | Production PAT/repo | Test feedback files real issues |

**The standing guardrail until this is built: test in "Test Club"**, which
reaches only two real accounts (Mark, Reviewer) rather than the full
membership. "Old Man's Book Club" is the real club and reaches Mitty.

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

### Decisions (made 2026-08-22)

**1. SignalR — switch dev to in-process `AddSignalR()`, drop the shared backplane.**
The shared-backplane design predates Half B: `Program.cs`'s own comment says
it exists so a simulator (local) and a physical device (previously *forced*
onto production) could reach each other in real time — the only way to bridge
two different API deployments. Half B removed that constraint: device and
simulator can now both point at the same local process. In-process SignalR
gives full isolation, zero Azure SignalR cost for dev traffic, **and**
preserves sim ↔ device real-time testing, because both clients hit the same
server. No remaining tradeoff.

**2. APNs — no-op in dev, real only via the Production preset.**
Gate is a single `Apns:Enabled` config flag (default `true`) checked once in
`NotificationService` (all three send paths — `SendJoinRequestNotificationAsync`,
`SendJoinResponseNotificationAsync`, `SendNewMessageAsync` — already share one
class with `IConfiguration` injected). `appsettings.Development.json` sets it
`false`: dev sends are logged, not delivered. There's no useful middle ground
(a "sandboxed but realistic" push isn't meaningfully safer than real APNs) —
when real push behaviour actually needs verifying, that's what pointing the
client at Production is *for*, deliberately, not an accident of shared dev
config.

**3. Blob — a second real Azure Storage account, not Azurite.**
Checked `BlobService.cs:91,164`: SAS generation goes through
`GetUserDelegationKeyAsync` (Azure AD user-delegation SAS). **Azurite doesn't
support user-delegation SAS at all** — only account-key SAS — so using it
would mean forking `BlobService` to carry two SAS code paths permanently,
which breaks the "isolate via config, not code" goal. Same reasoning as the
SQL decision: a second real Azure resource (`oldmansbookclubdev`, its own
`club-media`/`avatars` containers) costs a few cents a month at dev traffic
volumes and has zero drift from production's behaviour.

**4. Seed data — a seeder, extending the existing seed mechanism.**
A `/admin/seed-messages` endpoint (`X-Seed-Key`-gated) already exists for
messages. Extend it to also seed clubs/books/memberships/users, and run it
once against `bookclubdb-dev` after migrations. Preferred over a sanitized
production snapshot: reproducible and resettable for deterministic test
scenarios, and side-steps any question about copying real member content even
redacted.

### Build plan (not started)

1. **`bookclubdb-dev`** — second Basic-tier Azure SQL database on the existing
   server. Prod is Azure SQL Database (evergreen PaaS, no fixed version to
   match) and there is no native ARM64 SQL Server engine (Microsoft: container
   images are x86-64-only, Rosetta explicitly unsupported; Azure SQL Edge, the
   old ARM path, retired 2025-09-30) — a second real Azure DB has zero engine
   drift, unlike any local/container option. ~$5/month.
2. **`oldmansbookclubdev`** storage account — mirrors `oldmansbookclubstore`'s
   containers (`club-media`, `avatars`).
3. **Firewall upsert script** — replace manually chasing the dev machine's
   rotating egress IP with a one-line `az sql server firewall-rule create`
   run before `dotnet run`. (Not fixable with a VNet rule — VNet rules and
   Private Link put the *client* inside an Azure network, which a laptop
   can't join.)
4. **`Program.cs`** — branch `AddSignalR()` vs `AddAzureSignalR(...)` on
   `builder.Environment.IsDevelopment()`.
5. **`NotificationService`** — add the `Apns:Enabled` gate.
6. **Seeder** — extend `/admin/seed-messages` to cover clubs/books/memberships/users.
7. **Secrets migration** — `API/appsettings.Development.json` currently holds
   plaintext SQL/SignalR/Blob/APNs/JWT/GitHub secrets (gitignored, but one
   `git add -A` from disaster). Move dev secrets to `dotnet user-secrets`.

## Scenario matrix (current, post Half B)

| # | Client | Host | Data | Status |
|---|---|---|---|---|
| 1 | Simulator | localhost (default) | Production DB | Everyday dev |
| 2 | Simulator | Production | Production DB | Reproduce a prod bug |
| 3 | Device (`.dev`) | Dev Machine (LAN IP) | Production DB | **New** — device-only features against unshipped server changes |
| 4 | Device (`.dev`) | Production | Production DB | **New** — device testing against prod without touching the App Store app |
| 5 | Device, App Store | Production | Production DB | What users have — never disturbed by any of the above |

After Half A is built, scenarios 1 and 3 point at `bookclubdb-dev` instead,
and become genuinely data-isolated rather than merely app-isolated.

## Looking ahead: a CI regression / build-acceptance suite

Once Half A exists, the intent is to build an automated regression pass —
build-acceptance testing that runs on every CI build, not a one-off manual
check. This is future work, not yet scoped in detail, but it changes how Half
A should be built, so it's worth stating the constraint now rather than
discovering it after the fact:

**A GitHub Actions runner is not this dev machine.** `ci.yml` currently only
builds (`xcodebuild ... clean build`, simulator only, no test target — this is
also #32, "No test target"); it doesn't touch the API or a database at all.
For an automated suite to exercise real client-server behaviour, the runner
needs to reach an isolated backend the same way this Mac does today, which
raises questions Half A's build should leave room for rather than block on:

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

None of this blocks starting Half A — it only argues for building the seeder
idempotently, keeping the dev database's connection details in one obvious,
swappable config spot from day one, and keeping the eventual test runner as a
plain, locally-invokable script from the start.

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
