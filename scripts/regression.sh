#!/usr/bin/env bash
#
# OMBC regression suite (#126).
#
# One command, three lanes. Plain bash on purpose: CI calls this same script rather than
# reimplementing the steps in workflow YAML, so "it passed in CI" and "it passed on my machine"
# mean the same thing.
#
#   ./scripts/regression.sh                 lane A — hermetic. No network, no backend, no Azure.
#   ./scripts/regression.sh --live          lane A + real XCUITests against a local API
#   ./scripts/regression.sh --device        lane B + the device-only tests, on a connected iPhone
#
# What a green run does NOT prove is listed at the end of every run, and in docs/TESTING.md.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$PWD"

# ---- options ---------------------------------------------------------------------------------

LANE_API=1
LANE_IOS_UNIT=1
LANE_LIVE=0
LANE_DEVICE=0
RESET_DEV_DB=1
SIMULATOR="${OMBC_SIMULATOR:-iPhone 17 Pro}"
SKIP_UNIT=0
HERMETIC_SHARDS_TO_RUN="1 2"
BUILD_FOR_TESTING_DIR=""
PRODUCTS_DIR=""

# #204 (C1) — the hermetic UI tests run as two halves, one CI job each, in parallel. A half is a
# list of test CLASSES, so a new test lands in a half by being written in one of these classes.
# check_hermetic_shards() fails the run if a Hermetic*UITests class is in neither half — a test
# that silently runs nowhere is the failure mode this guards against.
HERMETIC_SHARD_1="OldMansBookClubUITests/HermeticChatUITests"
HERMETIC_SHARD_2="OldMansBookClubUITests/HermeticMediaUITests"

usage() {
    sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'USAGE'

Options:
  --live               also run the XCUITests against a local API + bookclubdb-dev
  --device             --live, plus the device-only tests on OMBC_DEVICE_UDID
  --only api|ios|ui    run just one part
  --only ios-unit      iOS unit tests only, skipping the hermetic UI tests
  --only hermetic-1    one half of the hermetic UI tests (hermetic-2 for the other) — what each
                       parallel CI job runs (#204)
  --build-for-testing DIR   build the app + test bundles into DIR and stop (CI's build job)
  --products DIR       run tests from bundles already built into DIR (test-without-building)
  --no-reset           for --live: do not wipe bookclubdb-dev first (leaves your dev state alone,
                       at the cost of determinism)
  --simulator NAME     simulator to use (default: iPhone 17 Pro, or $OMBC_SIMULATOR)
  -h, --help           this

Environment:
  OMBC_DEVICE_UDID     required for --device; `xcrun devicectl list devices` to find it
  OMBC_SEED_KEY        must match the API's Seeding:Key (dotnet user-secrets) for --live
  OMBC_TEST_SQL_IMAGE  override the SQL Server container image
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --live)      LANE_LIVE=1 ;;
        --device)    LANE_LIVE=1; LANE_DEVICE=1 ;;
        --no-reset)  RESET_DEV_DB=0 ;;
        --simulator) SIMULATOR="$2"; shift ;;
        --build-for-testing) BUILD_FOR_TESTING_DIR="$2"; LANE_API=0; LANE_IOS_UNIT=0; LANE_LIVE=0; shift ;;
        --products)  PRODUCTS_DIR="$2"; shift ;;
        --only)
            LANE_API=0; LANE_IOS_UNIT=0; LANE_LIVE=0
            case "$2" in
                api) LANE_API=1 ;;
                ios) LANE_IOS_UNIT=1 ;;
                # Unit tests without the hermetic UI tests — a faster subset for quick local
                # iteration. CI itself gates on the full `--only ios` (both).
                ios-unit) LANE_IOS_UNIT=1; SKIP_HERMETIC_UI=1 ;;
                hermetic-1|hermetic-2) LANE_IOS_UNIT=1; SKIP_UNIT=1; HERMETIC_SHARDS_TO_RUN="${2#hermetic-}" ;;
                ui)  LANE_LIVE=1 ;;
                *)   echo "--only takes api, ios, ios-unit, hermetic-1, hermetic-2 or ui" >&2; exit 2 ;;
            esac
            shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---- output ----------------------------------------------------------------------------------

if [[ -t 1 ]]; then BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else BOLD=""; RED=""; GREEN=""; DIM=""; OFF=""; fi

RESULTS=()
FAILED=0
START=$SECONDS

step()  { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$OFF"; }
note()  { printf '%s    %s%s\n' "$DIM" "$1" "$OFF"; }
fail()  { printf '%s    %s%s\n' "$RED" "$1" "$OFF"; }

record() {  # record <name> <exit-status>
    if [[ "$2" -eq 0 ]]; then RESULTS+=("${GREEN}PASS${OFF}  $1")
    else RESULTS+=("${RED}FAIL${OFF}  $1"); FAILED=1; fi
}

# ---- lane A: API integration -----------------------------------------------------------------

if [[ $LANE_API -eq 1 ]]; then
    step "API integration tests (real SQL Server in a container)"

    if ! docker info >/dev/null 2>&1; then
        fail "Docker is not running."
        note "These tests need a real SQL Server: the schema's filtered unique index on"
        note "(SenderId, ClientId) is what makes clientId dedup correct, and SQLite or the"
        note "in-memory provider would run the same tests green while enforcing nothing."
        note ""
        note "  brew install colima docker && colima start --vm-type vz --vz-rosetta"
        note ""
        note "On Apple Silicon the suite falls back to the arm64 azure-sql-edge image"
        note "automatically; CI runs the real mssql/server image on every PR."
        record "API integration" 1
    else
        set +e
        dotnet test Tests/BookClubApi.Tests/BookClubApi.Tests.csproj --logger "console;verbosity=minimal"
        record "API integration" $?
        set -e
    fi

    # #204 (C4) — the hermetic UI tests' stub has to behave like the server it stands in for
    # (dedup, 429 + Retry-After, the file-body send, dropped connections), or a UI test can pass
    # while proving nothing. Stdlib Python, a couple of seconds; lives here because the API lane
    # is the cheap CI job and the stub's shape comes from the API's contract fixtures.
    step "Hermetic stub self-test"
    set +e
    python3 scripts/test_hermetic_stub.py
    record "hermetic stub" $?
    set -e
fi

# ---- lane A: iOS unit ------------------------------------------------------------------------

run_xcodebuild_tests() {  # run_xcodebuild_tests <label> <destination> <retry:0|1> <only-testing...>
    local label="$1" destination="$2" retry="$3"; shift 3
    local args=()
    for target in "$@"; do args+=("-only-testing:$target"); done

    # NOT CODE_SIGNING_ALLOWED=NO. That flag produces a completely unsigned binary with NO
    # entitlements at all, which silently breaks every Keychain operation
    # (SecItemAdd/SecItemCopyMatching return errSecMissingEntitlement, -34018). TokenStore never
    # checks those return codes, so the failure is invisible where it happens: a login call
    # "succeeds" over the wire, but the token is never actually persisted. The very next
    # authenticated request goes out with no Authorization header, gets a 401, finds no refresh
    # token either, and the error path collapses that into a generic "check your connection" —
    # which looks exactly like a networking problem and is not one. This one flag was the entire
    # cause of an afternoon spent chasing a live-lane "network" failure that unsigned `main` had
    # identically, for the same reason.
    #
    # The fix costs nothing: Xcode's automatic "Sign to Run Locally" identity needs no Apple ID,
    # no certificate, and no network — it is generated locally and is exactly what a plain `open
    # OldMansBookClub.xcodeproj` + Run already uses. project.yml's CODE_SIGN_STYLE: Automatic
    # picks it up with no flag needed here at all.
    #
    # #204 (C2) — UI tests retry a FAILING TEST once (`-retry-tests-on-failure`), not the whole
    # suite. This used to re-run every UI test after any failure, which doubled a 30-minute CI job
    # whenever one known-flaky test tripped. Two things still get a second chance, now per test:
    # a crash inside Apple's own tooling (SpringBoard taking EXC_BAD_ACCESS in
    # XCTAutomationSupport, so the app under test never reaches the foreground — confirmed by
    # ~/Library/Logs/DiagnosticReports/SpringBoard-*.ips; a plain `simctl launch` opens the same
    # app instantly when it happens), and a genuinely flaky test. A real regression fails both
    # attempts. Either way a test that needed the retry is listed as FLAKY by xcresult_summary.py
    # (and in the GitHub job summary), so it gets an issue instead of quietly costing a retry.
    # Unit tests never retry: they don't touch a simulator UI, so a flaky one is always a bug.
    if [[ "$retry" -eq 1 ]]; then args+=(-retry-tests-on-failure -test-iterations 2); fi
    # #204 — a hung test fails by name instead of holding the runner for hours (GitHub's job limit
    # is 6 h). Found the hard way: a deliberately broken engine left a unit test waiting forever.
    # XCTest rounds allowances up to whole minutes.
    local allowance=120
    if [[ "$retry" -eq 1 ]]; then allowance=600; fi
    args+=(-test-timeouts-enabled YES -default-test-execution-time-allowance "$allowance"
           -maximum-test-execution-time-allowance "$allowance")

    local mode=(test -project OldMansBookClub.xcodeproj -scheme OldMansBookClub)
    if [[ -n "$PRODUCTS_DIR" ]]; then
        local xctestrun
        xctestrun=$(ls "$PRODUCTS_DIR"/Build/Products/*.xctestrun 2>/dev/null | head -1)
        if [[ -z "$xctestrun" ]]; then
            fail "no .xctestrun under $PRODUCTS_DIR/Build/Products — run --build-for-testing first"
            record "$label" 1
            return
        fi
        mode=(test-without-building -xctestrun "$xctestrun")
    fi

    local status xcodebuild_log result_bundle
    xcodebuild_log=$(mktemp -t ombc-xcodebuild)
    result_bundle="$(mktemp -d -t ombc-results)/$(echo "$label" | tr -c 'A-Za-z0-9' '-').xcresult"
    set +e
    set -o pipefail
    xcodebuild "${mode[@]}" \
        -destination "$destination" \
        -resultBundlePath "$result_bundle" \
        "${args[@]}" \
        | tee "$xcodebuild_log" | tail -40
    status=$?
    # tail -40 alone dropped the assertion messages, so a CI failure named the test but
    # not why. Surface every failure line from the full log.
    grep -E "error: -\[|: error: " "$xcodebuild_log" | head -20 || true
    set +o pipefail
    set -e
    python3 scripts/xcresult_summary.py "$result_bundle" "$label" || true
    record "$label" $status
}

check_hermetic_shards() {
    local cls missing=0
    for cls in $(grep -hoE "class Hermetic[A-Za-z]*UITests" UITests/*.swift | awk '{print $2}'); do
        if [[ " $HERMETIC_SHARD_1 $HERMETIC_SHARD_2 " != *"/$cls "* ]]; then
            fail "$cls is in neither hermetic half — add it to HERMETIC_SHARD_1 or _2 in regression.sh"
            missing=1
        fi
    done
    return $missing
}

resolve_simulator() {
    # A CI runner does not have the same simulators installed as this Mac, and the set changes
    # with every Xcode release. Rather than pinning a name that will rot, fall back to whatever
    # iPhone the machine actually has — a unit test does not care which.
    if xcrun simctl list devices available | grep -qF "$SIMULATOR ("; then return; fi
    local fallback
    fallback=$(xcrun simctl list devices available \
        | sed -n 's/^ *\(iPhone [^(]*\) (.*/\1/p' | sed 's/ *$//' | tail -1)
    if [[ -z "$fallback" ]]; then
        fail "no iPhone simulator is available on this machine"
        exit 1
    fi
    note "simulator '$SIMULATOR' not installed — using '$fallback'"
    SIMULATOR="$fallback"
}

# The simulator's persisted state is shared across lanes, and a session left by one lane poisons
# the next: the hermetic lane signs in against its stub server, and the token it stores is not
# valid on the real API — every later request 401s and the failures look like app bugs. (This is
# the same class as the stale-Keychain failure that once made a whole live run look broken.)
#
# So each iOS lane starts from a clean app: uninstall, and reset the simulator keychain, which an
# uninstall alone does not clear.
reset_simulator_state() {
    local udid
    udid=$(xcrun simctl list devices available \
        | sed -n "s/^ *$SIMULATOR (\([0-9A-F-]*\)).*/\1/p" | head -1)
    [[ -z "$udid" ]] && return 0

    xcrun simctl boot "$udid" >/dev/null 2>&1 || true

    # `simctl boot` returns, and `simctl list devices` reports "(Booted)", the instant the OS
    # reaches an early launchd milestone — measured here at ~1s. The device is not actually usable
    # for another ~10-15s after that: BackBoard (system UI services, including the loopback
    # networking stack a UI test's app needs to reach a stub server) is still coming up. A test
    # that starts in that window doesn't get a slow response — it gets NONE, because nothing is
    # listening on the interface yet. This is what silently broke the hermetic UI tests both in CI
    # (which boots a fresh simulator for every job) and, intermittently, in a local run that
    # happened to start right after a boot. `bootstatus` blocks until the device is genuinely
    # ready, not just reachable in `simctl list`.
    xcrun simctl bootstatus "$udid" >/dev/null 2>&1 || true

    xcrun simctl uninstall "$udid" com.markleit.oldmansbookclub.dev >/dev/null 2>&1 || true
    xcrun simctl keychain "$udid" reset >/dev/null 2>&1 || true
}

if [[ $LANE_IOS_UNIT -eq 1 || $LANE_LIVE -eq 1 || -n "$BUILD_FOR_TESTING_DIR" ]]; then
    resolve_simulator
fi

# Prebuilt bundles (--products) need no project at all — they were built from it already.
if [[ ( $LANE_IOS_UNIT -eq 1 || $LANE_LIVE -eq 1 || -n "$BUILD_FOR_TESTING_DIR" ) && -z "$PRODUCTS_DIR" ]]; then
    step "Regenerating the Xcode project"
    # project.yml is the source of truth and .xcodeproj is generated, so a test file added since
    # the last generate would otherwise be silently absent from the run — passing by not existing.
    xcodegen generate >/dev/null
fi

# #204 (C1) — CI builds once and runs the unit tests and each hermetic half on separate runners
# from those same bundles (`--products`), instead of one job building and then running everything
# in sequence.
if [[ -n "$BUILD_FOR_TESTING_DIR" ]]; then
    step "Building the app and test bundles into $BUILD_FOR_TESTING_DIR"
    set +e
    set -o pipefail
    xcodebuild build-for-testing \
        -project OldMansBookClub.xcodeproj -scheme OldMansBookClub \
        -destination "generic/platform=iOS Simulator" \
        -derivedDataPath "$BUILD_FOR_TESTING_DIR" | tail -20
    record "build for testing" $?
    set +o pipefail
    set -e
fi

if [[ $LANE_IOS_UNIT -eq 1 ]]; then
    if [[ $SKIP_UNIT -eq 0 ]]; then
        step "iOS unit tests (no network, no backend)"
        reset_simulator_state
        run_xcodebuild_tests "iOS unit" "platform=iOS Simulator,name=$SIMULATOR" 0 OldMansBookClubTests
    fi

    if [[ "${SKIP_HERMETIC_UI:-0}" != "1" ]]; then
        if check_hermetic_shards; then
            # The app is pointed at a stub HTTP server (a host process — see start_hermetic_stub.sh),
            # using the debugServerBaseURL override that already exists for #120 — so these are as
            # deterministic as the unit tests, just slower because a simulator has to boot and draw.
            scripts/start_hermetic_stub.sh
            for shard in $HERMETIC_SHARDS_TO_RUN; do
                step "Hermetic UI tests, half $shard of 2 (stub server, still no backend)"
                reset_simulator_state
                classes_var="HERMETIC_SHARD_$shard"
                # shellcheck disable=SC2086
                run_xcodebuild_tests "hermetic UI $shard/2" "platform=iOS Simulator,name=$SIMULATOR" 1 ${!classes_var}
            done
        else
            record "hermetic UI (shard check)" 1
        fi
    fi
fi

# ---- lane B: live UI -------------------------------------------------------------------------

API_PID=""
cleanup_api() {
    if [[ -n "$API_PID" ]] && kill -0 "$API_PID" 2>/dev/null; then
        note "stopping the local API (pid $API_PID)"
        kill "$API_PID" 2>/dev/null || true
        wait "$API_PID" 2>/dev/null || true
    fi
}
trap cleanup_api EXIT

if [[ $LANE_LIVE -eq 1 ]]; then
    step "Starting the local API against bookclubdb-dev"

    if curl -fsS --max-time 2 http://localhost:5235/health >/dev/null 2>&1; then
        note "an API is already listening on :5235 — using it, and leaving it running"
    else
        # 0.0.0.0, not localhost. Binding to loopback makes the API unreachable from the iOS
        # Simulator on this setup (the app renders "Unable to load. Check your connection." while
        # curl from the Mac succeeds, which is a genuinely confusing pair of symptoms), and it
        # would make the device lane impossible outright — a phone cannot reach the Mac's
        # loopback at all.
        ( cd API && ASPNETCORE_ENVIRONMENT=Development dotnet run --urls http://0.0.0.0:5235 ) \
            >"$REPO_ROOT/.regression-api.log" 2>&1 &
        API_PID=$!
        note "waiting for http://localhost:5235/health/ready"
        for _ in $(seq 1 60); do
            curl -fsS --max-time 2 http://localhost:5235/health/ready >/dev/null 2>&1 && break
            sleep 1
        done
        if ! curl -fsS --max-time 2 http://localhost:5235/health/ready >/dev/null 2>&1; then
            fail "the API never became ready — see .regression-api.log"

            # By far the most common cause, and the error carries everything needed to fix it.
            # SQL error 40615 names the IP the server ACTUALLY saw, which is the one that matters:
            # it can differ from what an ipify-style lookup reports (different egress path), and it
            # changes whenever the machine moves network. Reading it out of a stack trace by hand
            # is how you end up allow-listing an address that was already stale.
            if grep -q "Error Number:40615" "$REPO_ROOT/.regression-api.log" 2>/dev/null; then
                blocked=$(grep -oE "Client with IP address '[0-9.]+'" "$REPO_ROOT/.regression-api.log" \
                    | grep -oE '[0-9.]+' | tail -1)
                fail "Azure SQL rejected this machine's IP ($blocked). Run:"
                note ""
                note "  az sql server firewall-rule update --server oldmansbookclub-db \\"
                note "    -g \$(az resource list --name oldmansbookclub-db --query '[0].resourceGroup' -o tsv) \\"
                note "    -n dev-machine-current --start-ip-address $blocked --end-ip-address $blocked"
                note ""
                note "then re-run. Use THIS address, not whatever an external IP lookup reports —"
                note "the database connection can take a different egress path."
            fi

            record "live UI" 1
            LANE_LIVE=0
        fi
    fi
fi

if [[ $LANE_LIVE -eq 1 ]]; then
    if [[ $RESET_DEV_DB -eq 1 ]]; then
        step "Resetting and reseeding bookclubdb-dev"
        if [[ -z "${OMBC_SEED_KEY:-}" ]]; then
            fail "OMBC_SEED_KEY is not set — it must match the API's Seeding:Key."
            note "  cd API && dotnet user-secrets list | grep Seeding"
            note "Or pass --no-reset to run against whatever state the dev database is in."
            record "live UI" 1
            LANE_LIVE=0
        else
            curl -fsS -X POST -H "X-Seed-Key: $OMBC_SEED_KEY" http://localhost:5235/admin/reset-dev-db >/dev/null
            curl -fsS -X POST http://localhost:5235/admin/seed-baseline >/dev/null
            note "wiped and reseeded — three books, one per status"
        fi
    else
        note "skipping the reset (--no-reset): the UI tests will run against existing data"
    fi
fi

if [[ $LANE_LIVE -eq 1 ]]; then
    step "XCUITests against the live API (simulator)"
    # Clean app + keychain: the hermetic lane just signed in against its stub, and that token is
    # not valid here.
    reset_simulator_state
    # The Hermetic* classes are excluded here: they bring their own stub server, so running them
    # again against the live API would prove nothing new and cost another minute.
    run_xcodebuild_tests "live UI (simulator)" "platform=iOS Simulator,name=$SIMULATOR" 1 \
        OldMansBookClubUITests/OldMansBookClubUITests OldMansBookClubUITests/LibraryUITests
fi

# ---- lane C: device --------------------------------------------------------------------------

if [[ $LANE_DEVICE -eq 1 ]]; then
    step "XCUITests on a physical device"
    if [[ -z "${OMBC_DEVICE_UDID:-}" ]]; then
        fail "OMBC_DEVICE_UDID is not set."
        note "  xcrun devicectl list devices"
        record "device" 1
    else
        # A device build needs real signing, so CODE_SIGNING_ALLOWED=NO is not passed here — and
        # the device has to be pointed at this Mac, since localhost on a phone is the phone.
        note "the device must be pointed at this Mac in Settings → Server (Debug) → Dev Machine"
        note "DeviceOnlyUITests skips itself on a simulator rather than passing vacuously"
        set +e
        set -o pipefail
        # HermeticUITests explicitly excluded: it points the app at 127.0.0.1, which on a
        # physical device is the phone itself, not this Mac — it cannot ever pass here, for a
        # reason unrelated to whether the device lane itself is healthy.
        xcodebuild test \
            -project OldMansBookClub.xcodeproj \
            -scheme OldMansBookClub \
            -destination "platform=iOS,id=$OMBC_DEVICE_UDID" \
            -only-testing:OldMansBookClubUITests/OldMansBookClubUITests \
            -only-testing:OldMansBookClubUITests/LibraryUITests \
            -only-testing:OldMansBookClubUITests/DeviceOnlyUITests \
            | tail -40
        status=$?
        set +o pipefail
        set -e
        record "device UI" $status
    fi
fi

# ---- summary ---------------------------------------------------------------------------------

printf '\n%s%s%s\n' "$BOLD" "──────────── regression summary ────────────" "$OFF"
for line in "${RESULTS[@]}"; do printf '  %s\n' "$line"; done
printf '  %sran in %ds%s\n' "$DIM" "$((SECONDS - START))" "$OFF"

if [[ $LANE_DEVICE -eq 0 ]]; then
    cat <<EOF

${BOLD}Not covered by this run${OFF} — needs ${BOLD}--device${OFF} with an iPhone attached:
  · real APNs delivery (the simulator cannot receive a push; the payload the server
    builds IS covered, by the API lane)
  · background and suspended behaviour, background URLSession completion after a kill
  · real microphone capture and audio routing
  · watchdog/hang timing (the 0x8BADF00D scene-update crashes)
EOF
fi

cat <<EOF

${BOLD}Not covered by any automated lane${OFF}: CarPlay. See the checklist in docs/TESTING.md.
EOF

exit $FAILED
