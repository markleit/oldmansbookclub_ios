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
  timing, real force-quit, real radio); they're run on the TestFlight build with the send log as
  evidence — the checklist is `docs/SEND_DEVICE_MATRIX.md`.

Status: **Covered** · **Partial** (some of the row) · **Gap** (not yet covered) ·
**PR n** (built in that PR) · **Device** (device lane only).

Tests: `E:` SendEngineTests · `P:` SendPolicyTests · `O:` OutboxTests · `C:` ContractTests ·
`H:` HermeticSendUITests · `API:` server test class.

## Tapping Send

| # | Requirement | Tests | Status |
|---|---|---|---|
| S1 | The bubble appears instantly; the message is on the phone before any network work | E: `testATextIsOnDiskBeforeAnythingIsSent`, `testS1EveryKindIsOnDiskBeforeAnythingIsSent` | Covered |
| S2 | **A picked video is made ready in the composer before Send** (checked and compressed, with progress; Send waits for it) — so a sent video is complete at the tap. Too long or too large is shown then, before anything is sent; leaving the app mid-way picks up on return (design v2; was: compressed after it's queued) | `VideoPreparationTests` (5); H: `testH14AVideoIsPreparedBeforeSendThenGoesAtTheTap` (a 1 s sample clip) | Covered; long videos' wait in the composer: **Device** |
| S3 | App open, good signal: arrives in ~1–2 s | H: `testATextReachesTheServerWithinTwoSecondsOfTappingSend` (< 2.5 s), `testS3APhotoReachesTheServerWithinSecondsWithTheAppOpen` (< 5 s: iOS first, direct after 3 s) | Covered; voice: **PR 8** (needs the test recorder) |
| S5 | **Ten photos sent at once all arrive on the first try**, even when some wait their turn on the phone's one connection | API (real web server): `BatchUploadTests.A_photo_that_waits_its_turn_for_eight_seconds_still_arrives`, `…Ten_photos_sent_at_once_over_one_slow_connection_all_arrive_the_first_time` | Covered by #231 (found 2026-10-11: the server cut 2 of 9 off); **Device**: M5 with 10 photos, zero 408s in the server log |
| S6 | A photo is sent at 2048 px on its long side (~1 MB), from the chat and the share sheet | `PhotoUploadTests` (chat path) | Covered by #231 (chat); share sheet uses the same constant, untested — **PR 10** |
| S4 | Storage full at tap: an error, no bubble (D4) | — | Partial — photo/video show the error (as before); voice was silent and now shows it too (PR 8); untested — needs a full disk |

## Order and time

| # | Requirement | Tests | Status |
|---|---|---|---|
| O1 | Stamped with the tap time; strictly increasing per device | O: `testTapTimesAreStrictlyIncreasing…`, `…NeverGoBackwards…`, `…SurvivesARelaunch`; E: `testMessagesGoInParallelNotInALine` | Covered |
| O2 | Sent independently, in parallel: **a text after a video goes immediately** | E: `testO2ATextAfterAVideoGoesImmediatelyWithoutWaitingForTheVideo`, `testMessagesGoInParallelNotInALine` | Covered |
| O3 | Every chat is ordered by tap time — **the video slots in above the text when its upload finishes**, on the sender's phone and others' | `ChatOrderTests.testO3AVideoTappedBeforeAVoiceMessageStaysAboveItWhenItsUploadFinishesLater`, `…testALiveMessageTappedEarlierGoesWhereItWasTappedNotAtTheBottom`, `…testEqualTapTimesKeepOneOrderHoweverTheyArrive`; H: `testO3APhotoTappedBeforeATextStaysAboveItWhenTheTextLandsFirst`, `testPhotosAndTheirCaptionKeepTheOrderTheyWereSentIn` | Covered (PR 6) |
| O4 | The server keeps the tap time within [arrival − 7 days, arrival] | API: `SentAtClampTests` (6), `SentTimeTests` (clamp rows) | Covered |
| O5 | A late message still pushes, counts as unread, read marker by arrival | API: `SentTimeTests` (unread, marker, no rewind); `ChatOrderTests.testTheReadMarkerGoesToTheLatestToArriveNotTheNewestByTapTime`, `…FallsBackToTapTime` | Covered (PR 6 marks read by the latest arrival) |
| O6 | "↑ New message above" chip for someone else's message that lands above what was seen (D2); late arrivals merged into the chat | `ChatOrderTests.testTheChipPointsAtTheOldestNewMessageFromOthersAboveWhatWasSeen`, `…testNoChipForNewMessagesAtTheBottomForMyOwnOrOnAFirstLoad`, `…testALateArrivalFromAFetchIsMergedAtItsTapTime`; H: `testH15ALateArrivalGoesAtItsTapTimeWithANewMessageAboveChip` | Covered (PR 6) |
| O7 | `received_at` decodes in both Swift mirrors (`Message`, `ChatMessageDto`) | C: `testTheArrivalTimeDecodesOverRestAndOverSignalR` | Covered (PR 6) |
| O8 | Equal tap times keep a stable order | API: `MessagesTests.Messages_with_the_same_SentAt_return_in_a_stable_deterministic_order` (#156) | Covered; paging across equal times: #227 |

## What the sender sees

| # | Requirement | Tests | Status |
|---|---|---|---|
| B1 | Sending: spinner for the first ~30 s | P: `testSendingThenWaitingAfterAWhileOfFailures`; E: `testSendingTurnsIntoWaitingAfterThirtySecondsOfFailures` | Covered |
| B2 | Waiting: quiet clock when offline or still retrying after ~30 s; **never red** | P: `testOfflineShowsWaitingStraightAway`, `testHandedToIOSWithNoNetworkShowsWaiting`; H: `testWhenTheServerIsDownItShowsWaiting…`, `testServerErrorsAreRetriedAutomatically` | Covered |
| B3 | Waiting menu: "Will send automatically", **Send now**, **Delete** | H: `testSendNowTriesImmediately…` (menu wording, Delete offered, Send now), `testB3AWaitingMessageDeletedFromItsMenuNeverArrives`; E: `testDeletingAnUnsentMessageCancelsIt` | Covered |
| B4 | Couldn't send: red with the server's reason, content kept, **Copy** (text), **Delete**; only on a permanent refusal | E: `testARefusalShowsTheReasonAndIsNeverRetried`; H: `testARefusedMessageShowsTheReasonAndCanBeDeleted` (reason, Copy, Delete); P: `testOtherClientErrorsAreRefused…` | Covered |
| B5 | Library: "N unsent", red if any refused; a video whose upload has landed isn't unsent (the server creates it) | P: `testB5ABooksUnsentCountsSendingWaitingAndRefusedAndOnlyItsOwn`, `testB5AVideoTheServerCreatesIsNotUnsent`; H: `testWhenTheServerIsDown…` (count, clears when sent), `testARefusedMessage…` (red) | Covered (PR 7; video: design v2) |

## Walking away

| # | Requirement | Tests | Status |
|---|---|---|---|
| W1 | Go to another chat or the Library → sends | H: `testATextSentThenLeftImmediatelyStillArrives`, `testAPhotoSentThenLeftImmediatelyStillArrives`, `testSendsInTwoChatsBothArriveWhileYouSitInTheLibrary` | Covered |
| W2 | Background or lock → sends: **the carrier is already with iOS**, so leaving hands nothing over (design v2) | H: `testATextSentThenBackgroundedStillArrives`; E: `testNothingGoesDirectlyWhileTheAppIsBackgrounded`, `testW2LeavingTheAppHandsNothingOverEveryMessageAlreadyHasItsCarrier` | Covered (logic); iOS carrying it: **Device** M3/M4 |
| W3 | **Signal returns while locked → sends** — with a token still good: every send carries the week-long send token | E: `testOfflineAtTapIsHandedToIOSAndShowsWaiting`, `testAMessageHandedOverOfflineIsSentByIOSWithNoHelpFromTheApp`, `testW3LeavingTheAppWaitsForAHandOverStillGettingItsToken`, `testR7EverySendCarriesTheSendTokenOnBothCopies`; API: `SendTokenTests` (K1–K4) | Covered (logic); **Device** M5 — when iOS sends is iOS's (L1) |
| W4 | Server back while locked → sends: a failed carrier is replaced at once, held until the clock is due | E: `testR6AFailedCarrierIsReplacedAtOnceHeldUntilTheClockAppOpenOrNot`, `testW2LeavingTheAppHandsNothingOver…` | Covered (logic); **Device** M6 |
| W5 | iOS kills the app / reboot → sends when iOS wakes it or it's next opened | H: `testMessagesQueuedWhenTheAppWasKilledGoOnRelaunchWithoutOpeningTheChat`; E: `testOnRelaunch…` (3) | Covered (relaunch); the iOS wake itself: **Device** M8 |
| W6 | Force-quit → a reminder 10 min after the oldest unsent; cancelled when sent; not while open | `SendReminderTests` (10 min after the oldest; refused don't count; overdue → a minute out; wording; not shown while open); E: `testU10TheReminderIsSetWhenSomethingsUnsentAndMovesAsItSends`, `…OnlyTouchedWhenWhatsUnsentChanges`, `…LeavingTheAppReArms…` | Covered (PR 7); the notification itself after a real force-quit: **Device** M7 (`-sendReminderAfter 60` shortens it) |
| W7 | App update mid-send: 2.1's queues taken over; 2.1's in-flight transfers recognised, nothing sent twice (D3) | O: `testEverything21HadQueuedIsTakenOverInSendOrder`, `testALegacyMediaItemWhoseFileWasPurgedIsDropped` | Partial — each message arrives once (server dedup), but a 2.1 photo/voice upload still in flight at upgrade can upload twice (one unused blob); 2.1 transfer results untested. Decision pending; **Device** M12 |

## Retry schedule and responses

| # | Requirement | Tests | Status |
|---|---|---|---|
| R1 | 1, 2, 4, 8, 15, 30 s, then every 60 s, ±20% | P: `testTheScheduleIsAggressiveThenEveryMinuteForever`, `testJitterStaysWithinTwentyPercent` | Covered |
| R2 | **No limit** on attempts | P: `testTheScheduleIsAggressiveThenEveryMinuteForever`; E: `testR2APassingFailureIsRetriedWithNoLimit` (20 failures) | Covered |
| R3 | One shared clock; while backing off one probe (the oldest) goes directly, and if it gets through the rest go at once. Carriers wait with iOS until the clock is due | P: `testWhileBackingOffOnlyTheOldestMessageWithNoCarrierGoesAsAProbe`, `testWhileBackingOffOnlyTheOldestFailingMessageIsRetriedDirectly`; E: `testWhenTheServerIsDownOneProbeAtATimeThenEverythingFollowsIt` | Covered (design v2: suspended, iOS releases every held carrier when it's due — it can't be told which one landed) |
| R4 | Reset to immediate on: network back, foreground, iOS wake, any other request succeeding, chat open, Send now | E: `testR4EachGoodNewsTriggerSendsAWaitingMessageAtOnce` (network back, app opened, chat opened, another request succeeded, Send now), `testR4BeingRelaunchedByIOSSendsWaitingMessagesAtOnce`, `testATriggerStormSendsEachMessageOnce`; P: `testGoodNewsResetsTheBackoff` | Covered |
| R5 | No network: the carrier is with iOS at once (it waits for the network), no direct attempt; a 60 s backup check | E: `testOfflineAtTapIsHandedToIOSAndShowsWaiting`, `testR5WithTheAppOpenTheBackupCheckSendsEvenIfTheNetworkBackEventIsMissed`; P: `testCarrierEveryNewMessageGetsItsCarrierAtOnceEvenWhileBackingOff` | Covered |
| R6 | A carrier that fails for a passing reason (5xx, 429, a second 401) is **replaced at once**, held until the clock is due — the same with the app open or suspended. Replaced from the background, iOS treats it as discretionary and may hold it longer (its rule) | E: `testR6AFailedCarrierIsReplacedAtOnceHeldUntilTheClockAppOpenOrNot`, `testRateLimitedWhileSuspendedGoesBackToIOSAfterRetryAfter`, `testASecondRefusedTokenIsRetriedOnTheClockNotRenewedInALoop` | Covered (design v2) |
| R7 | 401 → renew the token, resend at once; refused renewal → waiting, not refused; **while locked, the wake lasts until the message is back with iOS** | E: `testARefusedTokenIsRefreshedAndTheMessageResent`, `testASecondRefusedTokenIsRetriedOnTheClockNotRenewedInALoop`, `testARetryDuringTheTokenRefresh…`; H: `testAnExpiredSignInIsRefreshedOnceAndTheMessageSent`; E: `testM9AfterA401WhileSuspendedTheWakeLastsUntilTheMessageIsBackWithIOS` | Covered; rare with the send token (sign-out, or a week offline); iOS's wake itself: **Device** M9 |
| R8 | 429 → wait Retry-After | E: `testRateLimitedWaitsExactlyAsLongAsTheServerSays`; P: `testARateLimitSurvivesGoodNews`; H: `testRateLimitedWaitsForRetryAfterThenSends`; API: `MessageSendTests` (429 + Retry-After), `RateLimitTests` | Covered |
| R9 | 5xx, timeout → next step on the schedule | P: `testServerTroubleAndTimeoutsAreTransient`, `testDroppedConnectionsAndTimeoutsAreTransient`; H: `testServerErrorsAreRetriedAutomatically` | Covered |
| R10 | Any other 4xx → couldn't send | P: `testOtherClientErrorsAreRefused…`; API: MediaFileSendTests refusals | Covered |
| R11 | Every send carries the **week-long send token** (design v2), renewed when under a day is left — with a network; offline the stored one goes. A server without send tokens gets the access token (10 min freshness) | E: `testR7EverySendCarriesTheSendTokenOnBothCopies`; P: `testATokenWithTimeLeftIsUsedAsIs`, `testWithANetworkAnExpiringOrExpiredTokenIsRefreshedFirst`, `testOfflineTheStoredTokenGoesAtOnceEvenIfExpired`; `SharedSignInTests` (share sheet); API: `SendTokenTests` | Covered (the renewal threshold lives in APIClient.sendToken, unit-tested through the policy) |

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
| T9 | Forward through the engine: queued at once with a client id, retried, a refusal shown red | E: `testAForwardCarriesTheSavedMessageAndAClientId`; API: `ForwardTests` (5); H: `testForwardAsksWhichChatThenConfirms` (send endpoint, saved message id, client id) | Covered (PR 9) |
| T10 | Share sheet: queued in the shared inbox, uploads handed to iOS, the sheet closes at once; the app takes them in and sees them through | `ShareInboxTests` (reads back in tap order; half-written not taken; the same request as the app's, photo and text; the result readable as the app's); E: `testU16AShareSheetMessage…` (waited for when iOS has it, confirmed by its result; sent by the app when not handed over; not duplicated); `SharedSignInTests` (token) | Covered (PR 10, logic); the sheet closing and it arriving while locked: **Device** S1, S2 |
| T11 | Video: sent ready (S2); its carrier is **one upload to a slot fetched in advance** (VA1), carrying the message's details — the server creates the message when it lands, so nothing after the tap needs the app. No slot left: reserved (online; every refusal before the upload), or waits offline. A copy already through → nothing uploaded. A failed upload is replaced at once on the same blob; one storage refuses (a week-old link, a repeat of one that landed) drops the slot for a reservation. (A video queued by an older build is still compressed by the engine, with the app open) | E: `testVSAVideoSentOfflineWithASlotIsHandedToIOSAtTheTap`, `testVSAVideoWithNoSlotLeftIsReservedOnlineAndWaitsOffline`, `testVSARetryReusesTheVideosSlotAndAStorageRefusalDropsItForAReservation`, `testV1…`, `testV2…`, `testV5…`, `testV6…`, `testV7…`, `testU9…`; H: `testH14…`; API: `ReservedVideoTests`, `VideoSlotTests` | Covered (design v2) |
| T12 | Old clients keep working against the new server | API: `The_json_send_is_unchanged_alongside_the_file_send`, `No_tap_time_means_sent_when_received…`; **Device** M13 after each deploy | Covered |

## Send token (design v2, server)

What a message handed to iOS carries so it can wait for the network without the app awake to
refresh an hour-long access token (#204 design v2, 2026-10-12). The app side lands in the v2 app PR.

| # | Requirement | Tests | Status |
|---|---|---|---|
| K1 | Signing in and refreshing each hand out a send token lasting 7 days; the access token is unchanged (no scope, 1 h) | API: `SendTokenTests.K1_…` | Covered |
| K2 | It sends every kind: JSON (text, video post, forward), the file body (voice, photo), a video reservation | API: `K2_…` | Covered |
| K3 | It does nothing else: no reading, no account calls, no upload links, no live connection | API: `K3_…` (each checked against the access token too) | Covered |
| K4 | Signing out on that phone ends it at once | API: `K4_…` | Covered |
| K5 | Deleting the account ends it | API: `AccountDeletionTests.K5_deleting_the_account_ends_the_send_token` | Covered (#244) |

## Video without the app (design v2, server)

The app reserves a video once it's compressed and uploads the file straight to storage; storage's
"file landed" report (Azure Event Grid → `/storage/events`) makes the server create the message.
Nothing after the upload needs the app.

| # | Requirement | Tests | Status |
|---|---|---|---|
| V1 | Reserving gives an upload link that lasts as long as the send token; no message yet | API: `ReservedVideoTests.V1_…` | Covered |
| V2 | When the upload lands, the server creates the message: tap time, reply, one push skipping the sender's phone | API: `V2_…` | Covered |
| V3 | The report and the app's own post make one message, whichever comes first | API: `V3_…`, `V4_…` | Covered |
| V4 | A report is not trusted: the file must really be in storage; a report of a file nobody reserved changes nothing | API: `V5_…`, `V6_…` | Covered |
| V5 | Reserving again reuses the file; once sent, it returns the message and nothing to upload | API: `V7_…` | Covered |
| V6 | Everything that can refuse a send refuses before the upload; a refusal on landing (too large) is told to the app when it posts | API: `V8_…`, `V9_…` | Covered |
| V7 | One send counts once against the limit (reservation, re-reservation, its own post) | API: `V10_…` | Covered |
| V8 | The upload link can't replace a file that has landed (create-only) | Checked against Azure dev storage (403 `UnauthorizedBlobOverwrite`, 2026-10-12); not reachable from CI | **Manual** |
| V9 | Event Grid's subscription handshake is answered | API: `V11_…`; the real subscription: **Device** M-video after deploy | Covered |

## Video upload slots (design v2, server)

Upload links fetched in advance, so a video sent with no network can be handed to iOS at the tap
(the 2.2 (6) device test: offline, a video's upload had to wait for the network to reserve it, so
it reached iOS only from the background — low priority — and went when the app was opened).

| # | Requirement | Tests | Status |
|---|---|---|---|
| VS1 | A slot is a create-only upload link for one video, good for 7 days, only for a club you're in; at most 10 unexpired per user | API: `VideoSlotTests.VS1_…` (2) | Covered |
| VS2 | A slot upload carries its message's details (book, client id, tap time, reply, device) as metadata; when it lands, the server creates the message from them (tap time, reply, one push skipping the sender's phone) | API: `VS2_…` | Covered; metadata on a create-only upload checked against Azure dev storage (2026-10-12) |
| VS3 | Missing or wrong details, or a book in another club than the slot's, create nothing | API: `VS3_…` | Covered |
| VS4 | Signing out on that phone drops what its slots would create | API: `VS4_…` | Covered |
| VS5 | The report and the app's own post make one message, whichever comes first | API: `VS5_…` | Covered |
| VS6 | A slot video's post isn't counted against the send limit (slots are capped instead) | API: `VS6_…` | Covered |
| VS7 | Unused slots are dropped after 8 days | API: `VS7_…` | Covered |

## Voice recording (#213)

| # | Requirement | Tests | Status |
|---|---|---|---|
| C1 | Declined call, Siri, alarm: paused; over within 15 s → resumes into the same message (chirp, "Recording resumed") | `RecordingTakeTests.testR1ADeclinedCallWithin15sResumesIntoTheSameMessage` | Covered (PR 8); the real interruption: **Device** R1, R5 |
| C2 | Call answered, or over 15 s → sends what was recorded | `testR2R3AnAnsweredCallOrOneOver15sSendsWhatWasRecorded` | Covered (PR 8); **Device** R2, R3 |
| C3 | Hold-to-talk resumes only if still held; lifted → sends | `testR4HoldToTalkLiftedDuringTheInterruptionSendsWithoutResuming` | Covered (PR 8); **Device** R4 |
| C4 | Leaving the chat mid-recording sends the take | `testC8LeavingTheChatSendsTheTake` (take); the chat's close calls it (`BookViewModel.disconnect`) | Covered (PR 8); **Device** R8 (tap-to-talk + Back) — a UI test needs a microphone CI doesn't have |
| C5 | Home, lock, playing a bubble → sends the take, as before | `testEveryWayATakeEndsIsLogged` (each reason ends it once) | Covered; **Device** R9 |
| C6 | Notification sounds, AirPods/CarPlay route changes don't stop it | — | **Device** R6, R7, CarPlay checklist |
| C7 | The send log records why each recording ended | `testEveryWayATakeEndsIsLogged` | Covered (PR 8) |
| C8 | Under half a second → dropped; can't resume → what was recorded is sent; ends once | `testUnderHalfASecondIsDropped`, `testWhenItCantResumeWhatWasRecordedIsSent`, `testAnEndedTakeEndsOnce` | Covered (PR 8) |

## Design v2: the carrier, the limit, upload slots (app)

Agreed 2026-10-12 on #204 (design v2 and the research comment after it).

| # | Requirement | Tests | Status |
|---|---|---|---|
| L1 | **Stated limit:** with the phone locked, iOS decides when a handed-over transfer goes — usually seconds, sometimes a minute or more (energy and data budgets, Apple: "an implementation detail"). Nothing of the app's stands in its way. With the app open, sends go directly (~1 s) | — | **Device** M5 measures it; not ours to change |
| CA1 | Every unsent message always has its carrier with iOS — except while one can't be built yet (no token; a video offline with no slot left), which waits on the clock | P: `testCarrierEveryNewMessageGetsItsCarrierAtOnceEvenWhileBackingOff`; E: `testW2LeavingTheAppHandsNothingOver…`, `testR6…`, `testOfflineAtTapIsHandedToIOSAndShowsWaiting`, `testVSAVideoSentOfflineWithASlotIsHandedToIOSAtTheTap`, `testWithNoTokenASuspendedAppWaitsRatherThanRetryingInALoop` | Covered |
| VA1 | **Upload slots on the phone**: 3 per club, topped up whenever the app is online — at launch, on coming back, on opening a chat, after one is used; one older than a day is swapped for a fresh one, but only once fresh ones arrive; a video takes the newest; none left → it's reserved online or waits offline; signing out discards them | `VideoSlotsTests` (4); E: `testVSSlotsAreToppedUpToThreeAtLaunchOnReturningOnAChatAndAfterOneIsUsed`, `testVSOnlyOnlineAndOldSlotsGoOnlyWhenFreshOnesArrive`; API: `VideoSlotTests` | Covered |
| VA2 | Continued processing is **not used** (research on #204: unreliable on a locked phone; a video is complete at the tap now, so nothing is left for it) | — | Removed (design v2, 2026-10-12) |
| N1 | The background session is created off the main thread (iOS 26.6/27 can block creating it at launch — Apple Developer Forums 848396) | — | Not unit-testable (URLSession internals); **Device**: cold launch and a background wake still deliver results |

