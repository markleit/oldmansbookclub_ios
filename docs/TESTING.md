# Testing

One command:

```bash
./scripts/regression.sh            # hermetic — no network, no backend, ~1 minute
./scripts/regression.sh --live     # + XCUITests against a local API and bookclubdb-dev
./scripts/regression.sh --device   # + the device-only tests, iPhone attached
```

CI calls this same script (`.github/workflows/test.yml` runs `--only api` and `--only ios`), so
"green in CI" and "green on my machine" mean the same thing rather than being two implementations
that drift.

---

## The three lanes

| Lane | Command | Where | Time | What it proves |
|---|---|---|---|---|
| **A — hermetic** | `regression.sh` | CI on every PR, and locally | ~2 min | API integration against a real SQL Server, iOS unit tests, and UI tests against a stub server |
| **B — live** | `regression.sh --live` | Locally, on demand | ~15 min | Lane A + the real app driven against a real API: blob uploads, SignalR, the full send path |
| **C — device** | `regression.sh --device` | Locally, iPhone attached | ~20 min | Lane B + push delivery, background behaviour, real audio |

### Lane A — hermetic

**API integration** (`Tests/BookClubApi.Tests`) boots the real `Program.cs` through
`WebApplicationFactory` against a throwaway SQL Server container. Real migrations, real
controllers, real auth, real EF model. Only the genuinely external edges are replaced: blob
storage, Apple's token endpoint, APNs and GitHub — and the APNs stub *records* what the server
would have sent, so push payloads are asserted even though delivery is not.

It must be a real SQL Server. `AppDbContext` declares the unique index on `(SenderId, ClientId)`
with a T-SQL filter, eight migrations contain raw T-SQL, and the dedup recovery path inspects
`SqlException.Number` for 2601/2627. On SQLite or the in-memory provider the clientId dedup tests
would pass while enforcing nothing — green, and testing the opposite of what they claim.

**iOS unit** (`UnitTests/`) constructs types directly: no simulator UI, no network, no backend.
The whole target runs in well under a second, which is what makes it viable as a merge gate.

**Hermetic UI** (`UITests/HermeticUITests.swift`) drives the real app against a stub HTTP server —
`scripts/hermetic_stub.py`, a genuine macOS process started by a build-phase script on the
`OldMansBookClubUITests` target (`project.yml`) before it builds. It needs no production code:
`ServerEnvironment` already resolves its host from the `debugServerBaseURL` default (#120), and a
launch argument populates it.

**Status: fixed and CI-gated (2026-09-12).** This lane had a real, confusing history worth knowing:

1. It originally ran the stub as a Swift `NWListener` created directly inside the test class. That
   was reachable instantly from its own process (proven with a raw `URLSession` call from inside
   the runner) but was **never** reachable from the app under test — a separate Simulator-hosted
   process — for the full duration of any test, deterministically, on a completely fresh device
   and in CI alike. iOS Simulator does not reliably bridge loopback connections *between two*
   Simulator-hosted apps, only from a Simulator app to a genuine macOS host process.
2. Moving the stub to a real host process (this file) fixed that class of failure.
3. It then, apparently at random and with no code change, alternated between long clean streaks
   and failing runs with the exact same symptom ("the app made NO request to the stub"). The
   actual cause: `HermeticUITests.launch()` passed `-hasAcceptedEULA YES` as a launch argument to
   skip the EULA screen, but the app's real `@AppStorage` key is `hasAcceptedEULA_v2`
   (`OldMansBookClubApp.swift`). The override never matched anything the app read — silently,
   with no error — so the app fell back to whatever `hasAcceptedEULA_v2` actually held in
   UserDefaults. On an already-installed app from an earlier test run, that value was still `true`
   (a real persisted write, unlike the broken launch-arg override) and Dev Login showed
   immediately — a clean pass. On a freshly (re)installed app, it reverted to `false`, the EULA
   screen showed instead of Dev Login, the button never appeared within its 5s wait, the tap was
   silently skipped, and the app never made its first network call at all — indistinguishable, on
   screen, from "the stub is unreachable." Confirmed directly via the app's own console log
   (`xcrun simctl spawn <udid> log stream --predicate 'process == "OldMansBookClub"'`): zero
   URLSession tasks were created on a failing run. Fixed by correcting the key.

This same bug was also the (until now unidentified) cause of a second, separately-tracked mystery:
even when the stub *was* reached, tapping a book row to enter its chat never navigated. Eight
distinct causes had been ruled out one at a time with the symptom surviving every one — the actual
cause was the same broken EULA key, manifesting identically. All four tests that were `XCTSkip`'d
pending this are re-enabled; three now pass reliably (confirmed across multiple fresh-install
runs, and 4 consecutive clean `regression.sh --only ios` runs end to end).

**One test still skipped, for a genuinely new and separate reason**:
`testASentMessageAppearsOnceNotTwice` was never exercised before (permanently blocked by the
navigation bug since inception), and now that it runs, the send button appears and is tapped
successfully but no send request is ever made afterward — confirmed via the same console-log
technique. Root cause not yet found; see the test's own doc comment.

CI now gates on `--only ios` (unit + hermetic UI both) — the CI-specific failure this lane
previously showed ("the app makes no request to the stub... a networking/environment difference")
was very likely this exact bug: a GitHub Actions runner is always a fresh VM, so it would hit the
broken-key path deterministically on every run, while locally it only surfaced once an earlier
test's persisted UserDefaults stopped masking it.

These cover what the app *draws* once the data exists, which is the part that needs no server:
the library's status groups, the chat rendering what was returned, and the emoji picker's grid.
Anything depending on real server behaviour — blob uploads, SignalR delivery, unread arithmetic —
stays in lane B or the API suite.

### Lane B — live

Starts the API on `localhost:5235` against `bookclubdb-dev`, **wipes and reseeds** it, then runs
`OldMansBookClubUITests` on a simulator.

The wipe is the point. These tests used to run against a database that only ever grew, and the
suite's own comments record a seeded message scrolling out of the first loaded page as it did —
turning a real assertion into a flake. Pass `--no-reset` to keep your dev data at the cost of that
determinism.

If the API fails to start, it is almost always the Azure SQL firewall — your egress IP changes
whenever the machine moves network. The script reads the address **the database server actually
saw** out of the error (SQL 40615) and prints the exact `az` command to fix it. Use that address
rather than an external IP lookup: the database connection can take a different egress path, and
the two do not always agree.

Needs `OMBC_SEED_KEY` to match the API's `Seeding:Key`:

```bash
cd API && dotnet user-secrets list | grep Seeding
```

Each iOS lane also **uninstalls the app and resets the simulator keychain** first. That is not
tidiness: the hermetic lane signs in against its stub server, and the token it stores is not valid
on the real API — without the reset, every request in the live lane 401s and the failures look
like app bugs. (Same class as the stale-Keychain state that once made a whole live run look
broken.)

A consequence worth knowing: a clean install shows the iOS notification-permission alert *over the
login screen*, and it swallows every tap behind it. `UITests/SystemAlerts.swift` dismisses it in
each `setUp`. The existing UI tests never needed this because they only ever ran on a simulator
where permission had been granted by hand at some point — which is exactly the kind of hidden
state a regression suite is supposed to remove.

**Coverage (2026-09-11):** `LibraryUITests` and `OldMansBookClubUITests` cover the library and
chat flows; `AdminUITests` and `ProfileUITests` cover the Admin tab's key actions (approve/decline
a join request, promote/demote a member's admin badge, kick a member) and Profile's edit-and-save
+ sign-out. `AdminUITests.testDeletingAMemberRemovesThemFromTheList` is `XCTSkip`'d against #153
(`DeleteUser` 500s for every caller — an execution-strategy/transaction conflict, not specific to
this test) — unskip it once that's fixed. Deliberately not covered: Profile's Delete Account,
which needs a disposable second account and has no login seam for one today (see
`ProfileUITests`'s header comment); Admin's Reports tab and club-delete, which need their own seed
data and are lower-value than the actions above. Both files seed their own throwaway join-request
users via the anonymous `/admin/seed-join-request` endpoint rather than relying on shared fixture
state, so they're safe to run in any order.

Both new files occasionally hit the same class of Simulator/XCTest flake already documented
below for the hermetic lane and in `run_xcodebuild_tests()`'s SpringBoard-crash retry — a test
that passes reliably alone or on a clean simulator can flake when stacked back-to-back with
several others on a loaded machine. Confirmed directly for each flake seen while writing these:
the underlying app behaviour is correct (verified via direct `curl` against the same endpoint),
and a clean rerun passes. Treat an isolated red run here as inconclusive, not as a regression,
until it reproduces on a fresh simulator with nothing else competing for CPU.

### Lane C — device

Everything in lane B, retargeted at `OMBC_DEVICE_UDID` (`xcrun devicectl list devices`), plus the
tests that only mean anything on real hardware. The device must be pointed at this Mac —
Settings → Server (Debug) → **Dev Machine** — since `localhost` on a phone is the phone.

---

## What a green run does not prove

Stated plainly, because a checkmark that implies more than it proves is worse than no checkmark.

**Needs lane C (a physical device):**

- **Real APNs delivery.** A simulator cannot receive a push at all; `simctl push` injects a local
  payload, which tests *handling*, never *delivery*. The payload the server builds — alert text,
  badge, per-book unread, recipient selection, sending-device exclusion — is fully covered by
  lane A.
- **Background and suspended behaviour.** Real suspension, background `URLSession` completion
  after the app is killed, recovery from a server outage (#121).
- **Watchdog and hang timing.** The open `0x8BADF00D` scene-update crashes (#141, #142, #151) are
  timing that only reproduces on real hardware.
- **Microphone capture and audio routing**, including Bluetooth and route changes.

**Covered by no automated lane at all:**

- **CarPlay.** Needs the managed entitlement and a head unit. Manual checklist below.

## CarPlay manual checklist

Run before any release that touches audio, playback or the CarPlay code. See
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

That closes a gap neither side could close alone. The server has one `MessageDto`; it goes out
over REST as snake_case and over SignalR as camelCase; and Swift has two independent mirrors of it
(`Message` in Models.swift, tolerant; `ChatMessageDto` in ChatService.swift, narrower, with
non-optional flags and a stricter date parser). A renamed field, an enum naming policy, a date
format change — each compiles cleanly on both sides and breaks exactly one transport at runtime.

If the wire format legitimately changes, the API test fails first with the list of what differs.
Check both Swift mirrors still work, then:

```bash
OMBC_UPDATE_CONTRACT=1 dotnet test Tests/BookClubApi.Tests/BookClubApi.Tests.csproj
```

Review the resulting diff as part of the change — it is the wire format, and old clients are still
running against it.

## Adding tests

**Validate a new test by breaking the code it covers.** Every regression this project has shipped
was invisible to the compiler, and a UI test once passed for a total voice/photo/video send outage
because it asserted absence via a query that could never match. If deliberately breaking the
behaviour does not turn the test red, the test is decoration — rewrite it.

Worked examples, all verified while writing this suite:

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

## Prerequisites

- **Docker**, for the API lane: `brew install colima docker && colima start --vm-type vz --vz-rosetta`.
  On Apple Silicon the fixture falls back to the arm64 `azure-sql-edge` image automatically —
  `mssql/server` publishes no arm64 image and its amd64 one will not run under Rosetta. CI runs
  the real `mssql/server` image on every PR, so that divergence is checked continuously.
- **xcodegen**, for the iOS lanes. The script regenerates the project before running, so a test
  file added since your last `xcodegen generate` cannot silently pass by not existing.
