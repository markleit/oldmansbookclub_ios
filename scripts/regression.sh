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

usage() {
    sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'USAGE'

Options:
  --live               also run the XCUITests against a local API + bookclubdb-dev
  --device             --live, plus the device-only tests on OMBC_DEVICE_UDID
  --only api|ios|ui    run just one part
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
        --only)
            LANE_API=0; LANE_IOS_UNIT=0; LANE_LIVE=0
            case "$2" in
                api) LANE_API=1 ;;
                ios) LANE_IOS_UNIT=1 ;;
                ui)  LANE_LIVE=1 ;;
                *)   echo "--only takes api, ios or ui" >&2; exit 2 ;;
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
fi

# ---- lane A: iOS unit ------------------------------------------------------------------------

run_xcodebuild_tests() {  # run_xcodebuild_tests <label> <destination> <only-testing...>
    local label="$1" destination="$2"; shift 2
    local args=()
    for target in "$@"; do args+=("-only-testing:$target"); done

    set +e
    set -o pipefail
    xcodebuild test \
        -project OldMansBookClub.xcodeproj \
        -scheme OldMansBookClub \
        -destination "$destination" \
        "${args[@]}" \
        CODE_SIGNING_ALLOWED=NO \
        | tail -40
    local status=$?
    set +o pipefail
    set -e
    record "$label" $status
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
    xcrun simctl uninstall "$udid" com.markleit.oldmansbookclub.dev >/dev/null 2>&1 || true
    xcrun simctl keychain "$udid" reset >/dev/null 2>&1 || true
}

if [[ $LANE_IOS_UNIT -eq 1 || $LANE_LIVE -eq 1 ]]; then
    resolve_simulator

    step "Regenerating the Xcode project"
    # project.yml is the source of truth and .xcodeproj is generated, so a test file added since
    # the last generate would otherwise be silently absent from the run — passing by not existing.
    xcodegen generate >/dev/null
fi

if [[ $LANE_IOS_UNIT -eq 1 ]]; then
    step "iOS unit tests (no network, no backend)"
    reset_simulator_state
    run_xcodebuild_tests "iOS unit" "platform=iOS Simulator,name=$SIMULATOR" OldMansBookClubTests

    step "Hermetic UI tests (stub server, still no backend)"
    # The app is pointed at a stub HTTP server run by the test process itself, using the
    # debugServerBaseURL override that already exists for #120 — so these are as deterministic as
    # the unit tests, just slower because a simulator has to boot and draw.
    run_xcodebuild_tests "hermetic UI" "platform=iOS Simulator,name=$SIMULATOR" \
        OldMansBookClubUITests/HermeticUITests
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
        ( cd API && ASPNETCORE_ENVIRONMENT=Development dotnet run --urls http://localhost:5235 ) \
            >"$REPO_ROOT/.regression-api.log" 2>&1 &
        API_PID=$!
        note "waiting for http://localhost:5235/health/ready"
        for _ in $(seq 1 60); do
            curl -fsS --max-time 2 http://localhost:5235/health/ready >/dev/null 2>&1 && break
            sleep 1
        done
        if ! curl -fsS --max-time 2 http://localhost:5235/health/ready >/dev/null 2>&1; then
            fail "the API never became ready — see .regression-api.log"
            fail "a readiness failure is usually the Azure SQL firewall: your egress IP changed."
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
    # HermeticUITests is excluded here: it brings its own stub server, so running it again against
    # the live API would prove nothing new and cost another minute.
    run_xcodebuild_tests "live UI (simulator)" "platform=iOS Simulator,name=$SIMULATOR" \
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
        xcodebuild test \
            -project OldMansBookClub.xcodeproj \
            -scheme OldMansBookClub \
            -destination "platform=iOS,id=$OMBC_DEVICE_UDID" \
            -only-testing:OldMansBookClubUITests \
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
