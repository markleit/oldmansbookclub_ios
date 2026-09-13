# Testing & Environments

How OMBC is tested, and the environments that make it possible — client × host × data
combinations, the automated lanes that exercise them, and what each does and does not prove. If
you were told to test a PR, this is the reference: run the commands in **The three lanes**, read
**What a green run does not prove** before claiming more than that, and check **Troubleshooting a
red run** before treating a failure as a real regression.

See also `docs/ARCHITECTURE.md` for the system overview and `CLAUDE.md` for day-to-day build
commands.

---

## Quick start

```bash
./scripts/regression.sh            # lane A — hermetic. No network, no backend, no Azure. ~2 min
./scripts/regression.sh --live     # + lane B — real XCUITests against a local API + bookclubdb-dev. ~15 min
./scripts/regression.sh --device   # + lane C — device-only tests, iPhone attached. ~20 min
```

CI calls this same script (`.github/workflows/test.yml` runs `--only api` and `--only ios`), so
"green in CI" and "green on my machine" mean the same thing rather than being two implementations
that drift.

| Lane | Command | Where | Time | Proves |
|---|---|---|---|---|
| **A — hermetic** | `regression.sh` | CI, every PR + local | ~2 min | API integration against a real SQL Server, iOS unit tests, UI tests against a stub server |
| **B — live** | `regression.sh --live` | Local, on demand | ~15 min | Lane A + the real app driven against a real API: blob uploads, SignalR, the full send path, Admin/Profile |
| **C — device** | `regression.sh --device` | Local, iPhone attached | ~20 min | Lane B + push delivery, background behaviour, real audio |

---

## Environments

Every test run is a point in three independent dimensions: which **client** (Simulator or
device), which **host** it points at, and which **data/backend** sits behind that host. Knowing
where a given run sits in this space is what makes a failure interpretable.

### How the API host is resolved

`App/Services/ServerEnvironment.swift` resolves it at runtime:

- **RELEASE** — compiles to the production literal. No lookup, no storage read, no way to change
  it — a shipped build behaves exactly as if this system didn't exist.
- **DEBUG** — a runtime value backed by `UserDefaults` (`debugServerBaseURL`), editable via
  `DebugServerControl`, embedded in both the pre-auth `LoginView` and post-auth `SettingsView` →
  "Server (Debug)". It needs a pre-auth copy because production returns 404 for `/auth/dev-login`
  outside Development, so there'd otherwise be no way to reach a local server on a fresh install.

Presets: **Production** (the hardcoded URL), **Localhost** (`http://localhost:5235` — simulator
only; on a device this means the device itself, and fails immediately by design), **Dev Machine**
(`ServerEnvironment.devMachineURLString`, the dev Mac's LAN IP — update by hand via
`ipconfig getifaddr en0` when the network changes; a convenience preset, not a source of truth).
Switching host signs you out — a JWT is only valid on the server that minted it.

**Both `APIClient` and `ChatService` read the same resolver.** Any new network caller must too —
pointing only one at a new host silently leaves the other on production.

### The `.dev` app

A DEBUG build installs under a separate bundle id, `com.markleit.oldmansbookclub.dev`
(`OMBC_BUNDLE_SUFFIX` in `project.yml`), so it coexists on a device with the real App Store
install instead of replacing it.

- **Auth**: Sign in with Apple requires the production bundle id, so `.dev` normally authenticates
  via Dev Login (`AuthViewModel.devLogin()`, `#if DEBUG`) against a `dev_*` user
  (`AuthController.DevLogin`, subject = `"dev_" + displayName.lowercased()` — always makes the
  caller a global admin, and always creates the club/joins the caller as club admin on a DB with
  no clubs yet). Sign in with Apple also works from a `.dev` build if you need to reproduce a prod
  account issue — see the Production-preset gotchas below.
- **Entitlements**: `com.apple.developer.carplay-audio` is a managed entitlement Apple grants only
  to the production App ID, so **the `.dev` app cannot test CarPlay**. For a CarPlay debug session
  with the debugger attached, build Debug with the real identity instead:
  `xcodebuild ... OMBC_BUNDLE_SUFFIX="" CODE_SIGN_ENTITLEMENTS=App/OldMansBookClub.entitlements`.
- **Push**: registers a sandbox APNs token against whichever `dev_*` user is signed in, so it
  never disturbs push delivery to the App Store app on the same device.
- **Visually distinct**: `(DEV)` name suffix and a red-bordered "DEV" icon, so the two installs
  are never confused on a home screen.

### Data isolation

|  | Client → **Production** | Client → **Localhost / Dev Machine** |
|---|---|---|
| API | Deployed Azure App Service | Local `dotnet run` |
| DB | `bookclubdb` | `bookclubdb-dev` — second Azure SQL database, isolated |
| SignalR | Azure SignalR Service | In-process `AddSignalR()`, no Azure resource |
| Blob | `oldmansbookclubstore` | Second real storage account, `oldmansbookclubdev` (SAS generation needs Azure AD user-delegation, which Azurite doesn't support, hence a real second account rather than a local emulator) |
| APNs | Real, sends | No-op — `Apns:Enabled=false` in dev secrets, logs instead of calling Apple |

Pointing at Localhost/Dev Machine touches none of Production's database, storage, SignalR, or
APNs. Pointing at Production is deliberate — that preset is what lets the Simulator or a device
double as a real-world tester.

### Scenario matrix

| # | Client | Host | Data | Account | Use |
|---|---|---|---|---|---|
| 1 | Simulator | Localhost (default) | `bookclubdb-dev`, fully isolated | "Dev Login (Debug)" — no real Apple ID | Everyday development |
| 2 | Simulator | Production | Real everything | Your real Apple ID, **signed in at the Simulator's OS level first** | Reproducing a prod bug — see gotchas |
| 3 | Device (`.dev`) | Dev Machine (LAN IP) | `bookclubdb-dev`, fully isolated | "Dev Login (Debug)" | Device-only features against unshipped server changes, zero prod contact |
| 4 | Device (`.dev`) | Production | Real everything | Your real Apple ID (already signed in at the OS level) | Device testing against prod without touching the App Store app |
| 5 | Device, App Store | Production | Real everything | Your real Apple ID | What users have — never disturbed by 1–4 |

### Known environment gotchas

**A Simulator with no real Apple ID signed in silently fakes it.** Tapping Sign in with Apple on
a Simulator with no Apple ID configured at the OS level doesn't error — iOS substitutes its
built-in synthetic test identity ("Simulator", no email) and hands the app a valid-looking token
for it, which the server has no way to distinguish from a real sign-in. **Before testing scenario
2, sign the Simulator into a real Apple ID via Settings first** — otherwise every run mints
another throwaway account.

**Pushing to yourself from a second device on the same account doesn't work, and isn't a bug.**
`NotificationDispatch` excludes the sender's own `UserId` from the push fan-out by design. Device
tokens are per-*user*, not per-device (#25, open), so a sim and a phone on the same real account
are, to the server, the same recipient being excluded. Testing push delivery end-to-end needs a
second real club member to send from.

**Keychain survives a plain `simctl uninstall`; UserDefaults does not.** A stale Keychain-stored
token from an earlier run can make `AuthViewModel.init()` treat the app as already authenticated
before Dev Login is ever tapped — see **Troubleshooting a red run** below.

---

## The three lanes

### Lane A — hermetic

No network, no backend, no Azure. This is the CI merge gate.

**API integration** (`Tests/BookClubApi.Tests`) boots the real `Program.cs` through
`WebApplicationFactory` against a throwaway SQL Server container (`Testcontainers.MsSql`; falls
back to arm64 `azure-sql-edge` on Apple Silicon, since `mssql/server` publishes no arm64 image).
Real migrations, real controllers, real auth, real EF model — only genuinely external edges are
replaced: blob storage, Apple's token endpoint, APNs and GitHub, with the APNs stub *recording*
what the server would have sent so push payloads are asserted even though delivery is not.

It must be a real SQL Server: `AppDbContext` declares the unique index on `(SenderId, ClientId)`
with a T-SQL filter, several migrations contain raw T-SQL, and the dedup recovery path inspects
`SqlException.Number` for 2601/2627. On SQLite or the in-memory provider, the clientId dedup tests
would pass while enforcing nothing.

**iOS unit** (`UnitTests/`) constructs types directly — no simulator UI, no network, no backend.
Runs in well under a second, which is what makes it viable as a merge gate.

**Hermetic UI** (`UITests/HermeticUITests.swift`) drives the real app against a stub HTTP server —
`scripts/hermetic_stub.py`, a genuine macOS process started by a build-phase script on the
`OldMansBookClubUITests` target (`project.yml`) before it builds, answering requests by shape
(unrecognized GET → `[]`, unrecognized POST → `{}`) plus a small control API
(`/_stub/reset`, `/_stub/messages`, `/_stub/requests`) so a test can seed state and read back what
the app requested. It runs as a real host process rather than in-process, because the iOS
Simulator does not reliably bridge loopback connections *between two* Simulator-hosted app
processes — only from a Simulator app to a genuine macOS host process, which is also why the live
lane's real API (also a host process) never has this problem. `/hubs/*` returns a hard 404 rather
than a generic 200, so the SignalR client abandons its handshake quickly instead of hanging for
several seconds waiting for a WebSocket upgrade a plain-HTTP stub will never deliver.

These tests cover what the app *draws* once the data exists — the library's status groups, the
chat rendering what the server returned, a sent message reconciling to exactly one bubble
(`SendReconciler`), the emoji picker's grid. Anything depending on real server behaviour — blob
uploads, SignalR delivery, unread arithmetic — belongs in lane B or the API suite instead.

### Lane B — live

Starts the local API on `localhost:5235` against `bookclubdb-dev`, wipes and reseeds it
(`POST /admin/reset-dev-db` — Development-only *and* `Seeding:Key`-guarded, then
`/admin/seed-baseline` for one book per status), then runs the real app on a simulator against it.
Needs `OMBC_SEED_KEY` set to match the API's `Seeding:Key`:

```bash
cd API && dotnet user-secrets list | grep Seeding
```

The wipe is what makes assertions deterministic against a database that would otherwise only
grow. Pass `--no-reset` to keep existing dev data instead.

Covers everything lane A's stub can't: real blob upload, real SignalR delivery, the full send
path against a real server, and the Admin/Profile flows (`AdminUITests`, `ProfileUITests` —
approve/decline a join request, promote/demote a member, kick a member, edit-and-save profile,
sign out). Both files seed their own throwaway join-request users via the anonymous
`/admin/seed-join-request` endpoint rather than relying on shared fixture state, so they're safe
to run in any order. Not covered: Profile's Delete Account (needs a disposable second account and
there's no login seam for one today) and Admin's Reports tab / club-delete (need their own seed
data, lower value than the actions above). `AdminUITests.testDeletingAMemberRemovesThemFromTheList`
is `XCTSkip`'d against #153 (`DeleteUser` 500s for every caller) — unskip once that's fixed.

Each iOS lane also uninstalls the app and resets the simulator Keychain first
(`reset_simulator_state()`) — necessary because a stale hermetic-lane session token isn't valid on
the real API, and because Keychain (unlike UserDefaults) survives a plain uninstall. See
**Troubleshooting a red run** if iterating without this script directly.

### Lane C — device

Everything in lane B, retargeted at `OMBC_DEVICE_UDID` (`xcrun devicectl list devices`), plus
tests that only mean anything on real hardware: push delivery, backgrounding, and real audio
capture. The device must be pointed at this Mac — Settings → Server (Debug) → **Dev Machine** —
since `localhost` on a phone is the phone itself.

---

## What a green run does not prove

Stated plainly, because a checkmark that implies more than it proves is worse than no checkmark.

**Needs lane C (a physical device):**

- **Real APNs delivery.** A simulator cannot receive a push at all; `simctl push` injects a local
  payload, which tests *handling*, never *delivery*. The payload the server builds — alert text,
  badge, per-book unread, recipient selection, sending-device exclusion — is fully covered by
  lane A.
- **Background and suspended behaviour.** Real suspension, background `URLSession` completion
  after the app is killed, recovery from a server outage (#121, manual steps only).
- **Watchdog and hang timing.** The `0x8BADF00D` scene-update crash class is timing that only
  reproduces on real hardware.
- **Microphone capture and audio routing**, including Bluetooth and route changes.

**Covered by no automated lane at all:**

- **CarPlay.** Needs the managed entitlement and a head unit — see the manual checklist below.

## CarPlay manual checklist

Run before any release that touches audio, playback or CarPlay code. See
`docs/CARPLAY_TEST_PLAN.md` for the full plan; this is the short pre-release pass:

- [ ] App appears in the CarPlay launcher (wired **and** wireless — wireless is where the audio
      path has historically differed)
- [ ] Book list renders, and a book opens its message list
- [ ] A voice message plays, and playback survives the phone locking
- [ ] Marking heard from CarPlay updates the unread badge on the phone
- [ ] A new message arriving while CarPlay is connected does not interrupt playback

---

## The JSON contract

`Tests/contract/*.json` is generated by the API test suite from the options the **running
application** is configured with — pulled out of its own DI container, not re-declared — and
committed. `UnitTests/ContractTests.swift` decodes those exact bytes through the app's real
decoders.

This closes a gap neither side alone can close. The server emits one `MessageDto` two ways —
snake_case over REST, camelCase over SignalR — and Swift has two independent mirrors of it
(`Message` in Models.swift, tolerant; `ChatMessageDto` in ChatService.swift, narrower, with
non-optional flags and a stricter date parser). A renamed field, an enum naming policy, or a date
format change compiles cleanly on both sides and breaks exactly one transport at runtime.

If the wire format legitimately changes, the API test fails first with the list of what differs.
Check both Swift mirrors still work, then:

```bash
OMBC_UPDATE_CONTRACT=1 dotnet test Tests/BookClubApi.Tests/BookClubApi.Tests.csproj
```

Review the resulting diff as part of the change — it is the wire format, and old clients are still
running against it.

## Adding tests

**Validate a new test by breaking the code it covers.** A UI test once passed for a total
voice/photo/video send outage because it asserted absence via a query that could never match. If
deliberately breaking the behaviour does not turn the test red, the test is decoration — rewrite
it.

| Break this | Only this should fail |
|---|---|
| `MessageSendService.TryRebroadcastExistingAsync` returns null | both clientId dedup tests |
| Invert the `incomingSentAt <= currentSentAt` comparison | `The_read_marker_only_ever_advances` |
| Drop the voice clause from `UnreadCalculator` | `A_voice_message_stays_unread_after_the_read_marker_passes_it` |
| Make `UnreadStore` always write the badge | `testThePushPathUpdatesTheCountWithoutTouchingTheBadge` |
| Add a camelCase policy to the server's `JsonStringEnumConverter` | the contract fixtures (three of them) |
| Make `SendReconciler` always `.insert` | `testASentMessageAppearsOnceNotTwice` (the bubble renders twice) |

**Where a test belongs.** Prefer the fastest lane that can actually prove the thing. Server logic
is an API integration test; client logic is a unit test; a flow that needs the real app on screen
is a UI test. A UI test that could have been a unit test costs a simulator boot on every run and
fails for more reasons than the one you care about.

## Troubleshooting a red run

A failure in one of these categories is an environment artifact, not necessarily a real
regression. Rule these out before reporting a bug.

**"The app made no request" / an unexplained auth-shaped failure ("Session error", a stray 403)
right after resetting state.** Keychain survives a plain `xcrun simctl uninstall` — only
UserDefaults gets wiped. If you're iterating with `xcodebuild test` directly instead of through
`regression.sh` (which always pairs both), reset both:
```bash
xcrun simctl uninstall <udid> com.markleit.oldmansbookclub.dev
xcrun simctl keychain <udid> reset
```
A stale token from an earlier run — especially against the hermetic stub, whose dev-login always
returns the exact same fixed tokens — can look perpetually valid, letting the app skip Dev Login
entirely and leaving `TokenStore.shared.userId` (UserDefaults-only) nil for the whole session.
Everything that doesn't read `userId` will render fine regardless, which is what makes this look
like a random UI bug rather than an auth one. Check the actual identity/token the app is using,
not just what the server or stub's own state shows.

**A UI test hangs or fails to bring the app to the foreground.** Check
`~/Library/Logs/DiagnosticReports/SpringBoard-*.ips` from the last couple of minutes for a crash
with `XCTAutomationSupport` at the top of the stack — a known, non-deterministic bug in Apple's
own Simulator-automation tooling, not this app. `run_xcodebuild_tests()` in `regression.sh` already
retries once automatically when it detects this. A real regression fails the same way on the
retry too; this doesn't.

**A test that passes reliably alone flakes when run back-to-back with several others.** This
machine's resource headroom matters — check `uptime`/`vm_stat` before and between heavy
Simulator/xcodebuild work, especially several invocations in a row. A red result under heavy
resource contention is inconclusive; rerun on its own before treating it as a regression.

**A single `-only-testing:` run behaves differently from the full lane.** Each `HermeticUITests`
test resets the stub server's own state in `setUp`, but the app's install and Keychain/UserDefaults
state on the simulator carries across every test in the same `xcodebuild test` invocation — it's
only reset once, up front, by `regression.sh` itself. A bare `xcodebuild test -only-testing:...`
skips that reset entirely and is fine for fast iteration, but a failure there should be reproduced
through the full script (or with the manual reset above) before you trust it.

## Prerequisites

- **Docker**, for the API lane: `brew install colima docker && colima start --vm-type vz --vz-rosetta`.
  CI runs the real `mssql/server` image on every PR; the Apple Silicon local fallback
  (`azure-sql-edge`) is checked against it continuously by that same CI run.
- **xcodegen**, for the iOS lanes. The script regenerates the project before running, so a test
  file added since your last `xcodegen generate` cannot silently pass by not existing.
- **A paired, unlocked iPhone** for lane C, with `OMBC_DEVICE_UDID` set and the device pointed at
  this Mac (Settings → Server (Debug) → Dev Machine).
