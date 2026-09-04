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
| **A — hermetic** | `regression.sh` | CI on every PR, and locally | ~1 min | API integration against a real SQL Server, plus iOS unit tests |
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

### Lane B — live

Starts the API on `localhost:5235` against `bookclubdb-dev`, **wipes and reseeds** it, then runs
`OldMansBookClubUITests` on a simulator.

The wipe is the point. These tests used to run against a database that only ever grew, and the
suite's own comments record a seeded message scrolling out of the first loaded page as it did —
turning a real assertion into a flake. Pass `--no-reset` to keep your dev data at the cost of that
determinism.

Needs `OMBC_SEED_KEY` to match the API's `Seeding:Key`:

```bash
cd API && dotnet user-secrets list | grep Seeding
```

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
