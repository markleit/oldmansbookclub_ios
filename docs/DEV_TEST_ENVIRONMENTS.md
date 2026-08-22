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

## What's still shared with production (Half A — NOT DONE)

Until Half A lands, the local API is a different front end onto the **same**
backing services as production:

| Service | Local dev uses | Risk |
|---|---|---|
| Azure SQL (`bookclubdb`) | **Production**, directly | Startup runs EF migrations against prod; test writes are real |
| Azure Blob Storage | Production `oldmansbookclubstore` | Test uploads land in the real container |
| APNs | Production credentials | A message from a dev/test account pushes real devices |
| Azure SignalR | Shared backplane with prod (deliberate — see `Program.cs`) | A local hub invoke may route to the Azure server instead, or vice versa |
| GitHub (Feedback feature) | Production PAT/repo | Test feedback files real issues |

**The standing guardrail: test in "Test Club"**, which reaches only two real
accounts (Mark, Reviewer) rather than the full membership. "Old Man's Book
Club" is the real club and reaches Mitty.

### Half A — plan (not started)

- **A real dev database** (`bookclubdb-dev`), not a local container. Prod is
  Azure SQL Database (evergreen PaaS, not a boxed version), and there is no
  native ARM64 SQL Server engine — Microsoft states container images are
  x86-64-only and explicitly does not support Rosetta emulation; Azure SQL
  Edge (the old ARM path) was retired 2025-09-30. A second Basic-tier Azure
  SQL database on the same server is ~$5/month and has zero engine drift from
  prod, unlike any local option.
- **A firewall upsert script** — replace manually chasing the dev machine's
  rotating egress IP with a one-line `az sql server firewall-rule create`
  run before `dotnet run`. (There is no way to fix this with a VNet rule
  instead — VNet rules and Private Link put the *client* inside an Azure
  network, which a laptop can't join.)
- **A seeder** — an empty dev database needs clubs/books/users/sample
  messages to be useful; decide seeder vs. sanitized prod snapshot.
- **Secrets migration** — `API/appsettings.Development.json` currently holds
  plaintext SQL/SignalR/Blob/APNs/JWT/GitHub secrets (gitignored, but one
  `git add -A` from disaster). Move dev secrets to `dotnet user-secrets`.

**Open decisions, not yet made:**

1. **SignalR in dev** — keep the shared backplane (current: sim ↔ device
   real-time works, but a local invoke may silently route to Azure prod and
   vice versa) vs. switch to `AddSignalR()` in-process for dev (guaranteed
   local routing, but loses sim ↔ device real-time entirely).
2. **APNs in dev** — real pushes to real devices remains the sharpest edge
   even after the DB is isolated, since push is a separate credential/service.
3. **Blob storage in dev** — Azurite (local emulator) vs. continuing to use
   production storage for a `bookclubdb-dev`-backed environment.
4. **Seed data** — a written seeder vs. a sanitized copy of production data.

## Scenario matrix (current, post Half B)

| # | Client | Host | Data | Status |
|---|---|---|---|---|
| 1 | Simulator | localhost (default) | Production DB | Everyday dev |
| 2 | Simulator | Production | Production DB | Reproduce a prod bug |
| 3 | Device (`.dev`) | Dev Machine (LAN IP) | Production DB | **New** — device-only features against unshipped server changes |
| 4 | Device (`.dev`) | Production | Production DB | **New** — device testing against prod without touching the App Store app |
| 5 | Device, App Store | Production | Production DB | What users have — never disturbed by any of the above |

After Half A, scenarios 1 and 3 point at `bookclubdb-dev` instead, and become
genuinely data-isolated rather than merely app-isolated.

## Separate: the Azure region split (not part of #120, discovered alongside it)

App Service (API) runs in **Norway East**; Azure SQL runs in **West US 2**.
Every production query crosses that distance. This wasn't a design decision —
West US App Service capacity was unavailable when the app was first deployed.
B1 Linux is now offered in West US / West US 2 / West US 3.

**Plan: move the App Service to West US, not the database.** The API's
hostname (`oldmansbookclub-api.azurewebsites.net`) is compiled into every
shipped client and is globally unique, so moving it means deleting the Norway
app and recreating the same name in West US — a brief window where the name
is unclaimed. Moving the (30 MB) database instead would be invisible to
clients, but West US is the intended end state either way, so moving the app
avoids doing this twice.

**The gotcha that would silently break a naive recreate:** production has no
`Azure:SignalRConnectionString` or Blob storage connection string in app
settings — it authenticates to both via a **system-assigned managed
identity** with three role assignments (SignalR App Server; Storage Blob Data
Contributor; Storage Blob Delegator). A recreated App Service gets a new
identity and zero role assignments. Missing this breaks chat (no SignalR
auth) and degrades every media URL to a plain, unsigned link. Any recreate
script must re-grant all three roles and wait for propagation (a few
minutes) before declaring success.

The deploy workflow (`deploy-api.yml`) needs no changes for this move — it
authenticates via a service-principal (`AZURE_CREDENTIALS`), not a publish
profile, and targets the app by name + resource group.

Sequence: create a West US B1 plan (proves capacity) → stand up a staging
app there with the full config, deploy, and validate (including comparing
`/health` vs. `/health/ready` latency against the Norway app, to confirm the
region split is actually costing meaningful round-trip time before spending
the migration effort) → delete the Norway app and recreate the same name on
the West US plan from the proven script → re-verify.
