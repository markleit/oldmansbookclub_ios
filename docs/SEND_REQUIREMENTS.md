# Sending: requirements → tests

Every agreed behaviour for sending (#204 spec, 2026-10-10) and the tests that prove it **as the
requirement states it**. Code coverage is secondary: a row is covered only when a test asserts the
behaviour in the requirement's own terms and has been seen to fail when that behaviour is broken.

**Rules**
- A PR that adds or changes a send behaviour updates its row here, in the same PR.
- Tests are written from the row, not from the implementation. A "while locked / backgrounded"
  row needs a unit test with the app **not** in the foreground and **no** app-side trigger
  (no network-back event, no timer) — a suspended app gets neither.
- Each new test is validated by breaking what it covers (docs/TESTING.md).
- "Device only" rows can't be proven by any automated lane (iOS's own background-transfer
  timing, real force-quit, real radio); they're run on every TestFlight build with the send log
  as evidence (M rows, #204 test plan).

Status: **Covered** · **Partial** (some of the row) · **Gap** (not yet covered) ·
**PR n** (built in that PR) · **Device** (device lane only).

Tests: `E:` SendEngineTests · `P:` SendPolicyTests · `O:` OutboxTests · `C:` ContractTests ·
`H:` HermeticSendUITests · `API:` server test class.

## Tapping Send

| # | Requirement | Tests | Status |
|---|---|---|---|
| S1 | The bubble appears instantly; the message is on the phone before any network work | E: `testATextIsOnDiskBeforeAnythingIsSent`, `testS1EveryKindIsOnDiskBeforeAnythingIsSent` | Covered |
| S2 | The composer is free immediately; video compressed after it's queued | — | **PR 5** |
| S3 | App open, good signal: arrives in ~1–2 s | H: `testATextReachesTheServerWithinTwoSecondsOfTappingSend` (< 2.5 s), `testS3APhotoReachesTheServerWithinSecondsWithTheAppOpen` (< 5 s: iOS first, direct after 3 s) | Covered; voice: **PR 8** (needs the test recorder) |
| S4 | Storage full at tap: an error, no bubble (D4) | — | **PR 8** — photo/video show the error (untested); voice currently loses the take silently (found 2026-10-11): fix + tests for all three with PR 8's test recorder |

## Order and time

| # | Requirement | Tests | Status |
|---|---|---|---|
| O1 | Stamped with the tap time; strictly increasing per device | O: `testTapTimesAreStrictlyIncreasing…`, `…NeverGoBackwards…`, `…SurvivesARelaunch`; E: `testMessagesGoInParallelNotInALine` | Covered |
| O2 | Sent independently, in parallel: **a text after a video goes immediately** | E: `testO2ATextAfterAVideoGoesImmediatelyWithoutWaitingForTheVideo`, `testMessagesGoInParallelNotInALine` | Covered |
| O3 | Every chat is ordered by tap time — **the video slots in above the text when its upload finishes**, on the sender's phone and others' | H: `testPhotosAndTheirCaptionKeepTheOrderTheyWereSentIn` (all fast) | **Gap: PR 6** — the sender's confirmed message and others' live arrivals are added as newest (found 2026-10-11); test: slow video then fast voice, order checked on both phones |
| O4 | The server keeps the tap time within [arrival − 7 days, arrival] | API: `SentAtClampTests` (6), `SentTimeTests` (clamp rows) | Covered |
| O5 | A late message still pushes, counts as unread, read marker by arrival | API: `SentTimeTests` (unread, marker, no rewind) | Covered (server); client read marker **PR 6** |
| O6 | "↑ New message above" chip; late arrivals merged into the chat | — | **PR 6** |
| O7 | `received_at` decodes in both Swift mirrors (`Message`, `ChatMessageDto`) | — | **PR 6** (was in PR 4's gate; slipped — the app doesn't read it yet) |
| O8 | Equal tap times keep a stable order | API: `Messages_with_the_same_tap_time_always_come_back_in_the_same_order` | Covered; paging across equal times: #227 |

## What the sender sees

| # | Requirement | Tests | Status |
|---|---|---|---|
| B1 | Sending: spinner for the first ~30 s | P: `testSendingThenWaitingAfterAWhileOfFailures`; E: `testSendingTurnsIntoWaitingAfterThirtySecondsOfFailures` | Covered |
| B2 | Waiting: quiet clock when offline or still retrying after ~30 s; **never red** | P: `testOfflineShowsWaitingStraightAway`, `testHandedToIOSWithNoNetworkShowsWaiting`; H: `testWhenTheServerIsDownItShowsWaiting…`, `testServerErrorsAreRetriedAutomatically` | Covered |
| B3 | Waiting menu: "Will send automatically", **Send now**, **Delete** | H: `testSendNowTriesImmediately…` (menu wording, Delete offered, Send now), `testB3AWaitingMessageDeletedFromItsMenuNeverArrives`; E: `testDeletingAnUnsentMessageCancelsIt` | Covered |
| B4 | Couldn't send: red with the server's reason, content kept, **Copy** (text), **Delete**; only on a permanent refusal | E: `testARefusalShowsTheReasonAndIsNeverRetried`; H: `testARefusedMessageShowsTheReasonAndCanBeDeleted` (reason, Copy, Delete); P: `testOtherClientErrorsAreRefused…` | Covered |
| B5 | Library: "N unsent", red if any refused | — | **PR 7** |

## Walking away

| # | Requirement | Tests | Status |
|---|---|---|---|
| W1 | Go to another chat or the Library → sends | H: `testATextSentThenLeftImmediatelyStillArrives`, `testAPhotoSentThenLeftImmediatelyStillArrives`, `testSendsInTwoChatsBothArriveWhileYouSitInTheLibrary` | Covered |
| W2 | Background or lock → sends (iOS carries it) | H: `testATextSentThenBackgroundedStillArrives`; E: `testNothingGoesDirectlyWhileTheAppIsBackgrounded`, `testLeavingTheAppHandsIOSWhatsWaitingOnTheClock` | Covered (logic); iOS carrying it: **Device** M3/M4 |
| W3 | **Signal returns while locked → sends** | E: `testOfflineAtTapIsHandedToIOSAndShowsWaiting`, `testAMessageHandedOverOfflineIsSentByIOSWithNoHelpFromTheApp` (#226) | Covered (logic); **Device** M5 |
| W4 | Server back while locked → sends | E: `testLeavingTheAppHandsIOSWhatsWaitingOnTheClock`, `testAFailureWhileSuspendedGoesStraightBackToIOSOnTheBackoff` (#226) | Covered (logic); **Device** M6 |
| W5 | iOS kills the app / reboot → sends when iOS wakes it or it's next opened | H: `testMessagesQueuedWhenTheAppWasKilledGoOnRelaunchWithoutOpeningTheChat`; E: `testOnRelaunch…` (3) | Covered (relaunch); the iOS wake itself: **Device** M8 |
| W6 | Force-quit → a reminder 10 min after the oldest unsent; cancelled when sent; not while open | — | **PR 7** |
| W7 | App update mid-send: 2.1's queues taken over; 2.1's in-flight transfers recognised, nothing sent twice (D3) | O: `testEverything21HadQueuedIsTakenOverInSendOrder`, `testALegacyMediaItemWhoseFileWasPurgedIsDropped` | Partial — each message arrives once (server dedup), but a 2.1 photo/voice upload still in flight at upgrade can upload twice (one unused blob); 2.1 transfer results untested. Decision pending; **Device** M12 |

## Retry schedule and responses

| # | Requirement | Tests | Status |
|---|---|---|---|
| R1 | 1, 2, 4, 8, 15, 30 s, then every 60 s, ±20% | P: `testTheScheduleIsAggressiveThenEveryMinuteForever`, `testJitterStaysWithinTwentyPercent` | Covered |
| R2 | **No limit** on attempts | P: `testTheScheduleIsAggressiveThenEveryMinuteForever`; E: `testR2APassingFailureIsRetriedWithNoLimit` (20 failures) | Covered |
| R3 | One shared clock; the oldest goes first; if it gets through, the rest go at once | P: `testWhileBackingOffOnlyTheOldestGoesAsAProbe`, `testNoSecondProbeWhileOneIsInFlight`; E: `testWhenTheServerIsDownOneProbeAtATimeThenEverythingFollowsIt` | Covered |
| R4 | Reset to immediate on: network back, foreground, iOS wake, any other request succeeding, chat open, Send now | E: `testR4EachGoodNewsTriggerSendsAWaitingMessageAtOnce` (network back, app opened, chat opened, another request succeeded, Send now), `testR4BeingRelaunchedByIOSSendsWaitingMessagesAtOnce`, `testATriggerStormSendsEachMessageOnce`; P: `testGoodNewsResetsTheBackoff` | Covered |
| R5 | No network: handed to iOS, no direct attempt; a 60 s backup check | E: `testOfflineAtTapIsHandedToIOSAndShowsWaiting`, `testR5WithTheAppOpenTheBackupCheckSendsEvenIfTheNetworkBackEventIsMissed` | Covered (the backup check now also sends what iOS holds, as the event does) |
| R6 | In the background a failure goes back to iOS, keeping the backoff | E: suspended tests (#226) | Covered |
| R7 | 401 → refresh, retry at once; refused refresh → waiting, not refused | E: `testARefusedTokenIsRefreshedAndTheMessageResent`, `testASecondRefusedTokenWaitsOnTheClock`, `testARetryDuringTheTokenRefresh…`; H: `testAnExpiredSignInIsRefreshedOnceAndTheMessageSent` | Covered |
| R8 | 429 → wait Retry-After | E: `testRateLimitedWaitsExactlyAsLongAsTheServerSays`; P: `testARateLimitSurvivesGoodNews`; H: `testRateLimitedWaitsForRetryAfterThenSends`; API: `MessageSendTests` (429 + Retry-After), `RateLimitTests` | Covered |
| R9 | 5xx, timeout → next step on the schedule | P: `testServerTroubleAndTimeoutsAreTransient`, `testDroppedConnectionsAndTimeoutsAreTransient`; H: `testServerErrorsAreRetriedAutomatically` | Covered |
| R10 | Any other 4xx → couldn't send | P: `testOtherClientErrorsAreRefused…`; API: MediaFileSendTests refusals | Covered |
| R11 | Token with < 10 min left refreshed before handing to iOS | E: `testATokenIsRefreshedIfItExpiresTooSoonForIOSToHoldTheRequest` | Covered |

## Transport and edge cases

| # | Requirement | Tests | Status |
|---|---|---|---|
| T1 | Text: background + direct at once | E: `testATextGoesThroughIOSAndDirectlyAtOnce` | Covered |
| T2 | Voice/photo: direct only after 3 s while open, or on network back / Send now; never while backgrounded | E: `testVoiceGoesThroughIOSFirstAndDirectlyOnlyAfterTheNudge`, `testNothingGoesDirectlyWhileTheAppIsBackgrounded` | Covered |
| T3 | The first copy to land wins; the other is cancelled; shown once | E: `testTheFirstCopyToLandWinsAndTheOtherIsDropped`, `testTheSignalREchoCountsAsDelivered`; H: `testASentMessageAppearsOnceNotTwice` | Covered |
| T4 | Server: one request per voice/photo; dedup by `client_id` before the limit; refusals before storage | API: `MediaFileSendTests` (13) | Covered |
| T5 | Delete while in flight: cancelled; if it lands anyway, shown as sent (D1) | E: `testDeletingAnUnsentMessageCancelsIt`, `testAMessageDeletedOnItsWayThatLandsAnywayIsShownAsSent` | Covered |
| T6 | A purged file → refused with that reason, never silently dropped (D4) | E: `testAMessageWhoseFileIsGoneIsRefusedNotSilentlyDropped` | Covered |
| T7 | Sent with no chat open → the chat's saved copy is updated | E: `testAConfirmationUpdatesTheSavedChatEvenWithNoChatOpen` | Covered |
| T8 | The send log records every step with stable names, **never message text** | E: `testT8TheSendLogNamesEveryStepButNeverWhatWasWritten` | Covered |
| T9 | Forward through the engine | E: `testAForwardCarriesTheSavedMessageAndAClientId`; API: `ForwardTests` (5) | Partial — UI path **PR 9** |
| T10 | Share extension through the outbox; app and extension never refresh at once | `SharedSignInTests` (token) | Partial — **PR 10** |
| T11 | Video: compress after queue, fresh link on failure, too large → refused | E: `testAVideoUploadsItsBlobThenPostsTheURL` | Partial — **PR 5** |
| T12 | Old clients keep working against the new server | API: `The_json_send_is_unchanged_alongside_the_file_send`, `No_tap_time_means_sent_when_received…`; **Device** M13 after each deploy | Covered |

## Voice recording (#213)
All rows (pause/resume within 15 s, hold-to-talk, leaving the chat sends the take, stop reasons
logged): **PR 8**, with U13/H17 and device rows R1–R9.
