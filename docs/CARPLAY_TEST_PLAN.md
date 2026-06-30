# CarPlay Manual Test Plan — 1.7.0 (#46)

Exhaustive manual verification of the CarPlay work before shipping 1.7.0.
Covers #46, #53, #54, #55, #59, #60, #66 plus the wireless-CarPlay audio
stability work.

## Legend
- **[CAR]** must be run on a real device in an actual car (wireless or wired CarPlay head unit). Audio-stability/skip cases live here.
- **[SIM]** can be run on the CarPlay Simulator (Xcode ▸ I/O ▸ External Displays ▸ CarPlay) — good for UI/navigation/logic.
- **[BOTH]** run on both; behavior can differ between sim and a real head unit.
- Result: mark **PASS / FAIL / N/A** and note the build (1.7.0 (1)).

## Test environment setup (do this first)
- [ ] **Only ONE iPhone simulator booted.** Multiple booted sims break the CarPlay external display. An iPad sim greys out CarPlay — must be iPhone.
- [ ] CarPlay **entitlement granted** for the bundle id (device-only / managed-gated). Without it, nothing custom appears in the car.
- [ ] In-car phone is signed in and has at least: 2+ clubs, a book with **a mix of voice + text messages**, some **unheard**, some already **heard**, and **at least one message you sent** (to verify own-message exclusion in counts).
- [ ] Have both **wireless** and **wired** CarPlay available if possible — the historical skip bug was wireless-specific.
- [ ] Decide test order: do **[SIM]** UI/logic cases first at your desk, then the **[CAR]** audio cases in the car.

---

## A. Connection & scene lifecycle [BOTH]
- [ ] A1. Connect to CarPlay cold (app not running) → CarPlay root (club chooser) appears within a few seconds.
- [ ] A2. Connect with app already foregrounded on phone → CarPlay root appears, no duplicate/blank screens.
- [ ] A3. Connect with app backgrounded → CarPlay root appears.
- [ ] A4. Disconnect and reconnect CarPlay (unplug/replug or toggle) → root rebuilds cleanly, no stale screens, no crash.
- [ ] A5. Leave and re-enter the CarPlay app via the car's home button → lists are present and refreshed (no blank list).
- [ ] A6. Background the phone app while on a CarPlay list, bring it back → CarPlay list still valid.

## B. Browse / navigation [SIM] (verify on [CAR] once)
- [ ] B1. Club chooser lists all clubs the user belongs to, correct names.
- [ ] B2. Tap a club → book list for that club appears.
- [ ] B3. Tap a book → message list appears, newest/most-relevant ordering matches the phone.
- [ ] B4. Back navigation works at every level (message → book → club → root).
- [ ] B5. Re-entering a list after playing a message refreshes it (counts/heard state updated, ref: `ca50af8`).
- [ ] B6. A book/club with **no messages** shows a sensible empty state (no crash, no infinite spinner).

## C. List content correctness [SIM] (spot-check [CAR])
- [ ] C1. Voice messages show the 🎤/voice icon; text messages show the 💬/text icon (ref: `9fa0cbc`, `20ccb33`).
- [ ] C2. All message types render (voice, text, and any photo/video appear as a reasonable row, not blank).
- [ ] C3. Message timestamps match the phone's format (ref: `ae34129`).
- [ ] C4. Transcripts: voice messages with a stored transcript show it; transcripts refresh live as they arrive (ref: `9fa0cbc`, `377098f`).

## D. Unread / unheard counts & dots — #53 [SIM]
- [ ] D1. Unheard **count** on a book in CarPlay matches the count shown on the phone for the same book.
- [ ] D2. Unheard **dots** appear on exactly the unheard messages, matching the phone.
- [ ] D3. **Own messages are excluded** from the unheard count/dots (send yourself nothing-new check: your own messages never count as unheard). (ref: `643b4b1`)
- [ ] D4. After playing an unheard message to completion in the car, its dot clears and the book's count decrements — **and the same change is reflected on the phone** (mark-heard sync).
- [ ] D5. Counts update live when a **new** message arrives while CarPlay is connected (SignalR refresh).

## E. Playback — core [BOTH]
- [ ] E1. Tap a voice message → it plays through the car speakers.
- [ ] E2. Tap a text message → it is **read aloud via TTS** (ref: `20ccb33`).
- [ ] E3. **Continuous autoplay**: starting playback advances automatically through subsequent **unheard** messages without manual taps (ref: `4e880c0`).
- [ ] E4. Autoplay correctly mixes voice + text (TTS) messages in sequence without dropping or doubling any.
- [ ] E5. When the queue ends, the last message stays shown on Now Playing (paused) rather than blanking (ref: `39a2007`, `68c2924`).
- [ ] E6. Each played message is marked heard on completion and unread syncs everywhere (ties to D4).
- [ ] E7. Stop/pause from the car keeps the current message visible (paused), not blank (ref: `39a2007`).

## F. Now Playing template — transport, scrubbing, art [BOTH]
- [ ] F1. **Album art** = the app/book icon shows on Now Playing (#55, ref: `1860316`).
- [ ] F2. Now Playing metadata (title/sender/etc.) is correct and updates per message (ref: `ae3bb0c`, `a982606`).
- [ ] F3. Play/pause from the Now Playing/steering-wheel controls works.
- [ ] F4. **Scrubber** for voice messages: the elapsed time advances live and visibly moves (ref: `43f17a4`).
- [ ] F5. Scrubbing to a position (changePlaybackPosition) seeks within the voice message (ref: `ff9e2c9`). (Text/TTS may not support scrub — verify it degrades gracefully.)
- [ ] F6. **±10s skip** buttons jump within the current voice message (ref: `72b7d24`).
- [ ] F7. **Next** advances to the next message; **Previous/back** goes to the prior message (ref: `07f3f9a`).
- [ ] F8. Progress bar does **NOT** restart/jump at message boundaries when one message ends and the next begins (ref: `1101994` — the reused-player stale-clock fix). **Watch this closely across 3–4 consecutive messages.**

## G. Playback speed — #54 [BOTH]
- [ ] G1. Speed button cycles **1x → 1.5x → 2x → 3x → 1x** (ref: `286ddf1`).
- [ ] G2. Each setting **audibly** changes the playback rate for voice messages.
- [ ] G3. Speed setting persists across messages during continuous autoplay (doesn't reset to 1x each message).
- [ ] G4. Speed applies (or degrades gracefully) for text TTS.
- [ ] G5. Pitch stays natural at higher speeds (no chipmunk), audio still intelligible at 3x.

## H. Phone ↔ CarPlay sync [BOTH]
- [ ] H1. Start playing a message **on the phone**, then look at CarPlay → CarPlay **jumps to and follows** that playback, even across different chats (ref: `f2214f2`, `f5b3cb3`).
- [ ] H2. Transport state stays in sync: pause on phone → CarPlay shows paused, and vice-versa (ref: `a982606`).
- [ ] H3. Start on CarPlay, then look at the phone → phone reflects the same now-playing message.
- [ ] H4. Switching the playing message on one side updates the other without a stale/ghost Now Playing.
- [ ] H5. Stale TTS callbacks don't cause wrong skip/jump after rapidly changing messages (ref: `17ad6de`, `b312ff9`).

## I. Background / lifecycle — #60 [CAR]
- [ ] I1. Audio **keeps playing when the phone app is backgrounded** (home screen, other app) (ref: `e097008` UIBackgroundModes audio).
- [ ] I2. Audio keeps playing with the **phone screen locked / asleep** (ref: `44c7261` — phone screen allowed to sleep during playback).
- [ ] I3. Now Playing info is correct on the **car home screen / dashboard** widget, not just inside the app (#60).
- [ ] I4. Lock the phone, then operate transport from the car (play/pause/next) → works while locked.
- [ ] I5. Incoming phone call interrupts audio, and playback **resumes** (or sensibly stops) after the call ends.
- [ ] I6. Switching to another audio app (e.g. Maps voice, music) and back behaves correctly (no permanent silence, session recovers).

## J. Audio stability & quality — the main risk [CAR]
> This is where the historical wireless-CarPlay bugs lived. Run a **long** session (10+ minutes, many messages).
- [ ] J1. **WIRELESS CarPlay**: play through 10+ messages continuously → **no skips, no stalls, no dropouts** (ref: `c2abedf`, `04d8b46`, `03be6a0`, `5b02e3d`, `e097008`).
- [ ] J2. **WIRED CarPlay**: same long run → no skips/stalls.
- [ ] J3. Audio **quality** is clean — no garbled/low-quality/HFP-telephony-sounding audio (ref: `cde3aa4`, `1dfa82d`, `c728be7`).
- [ ] J4. Rapid user actions (skip, next, scrub, change speed repeatedly) don't cause stalls, stuck audio, or the player dying (ref: `5b02e3d` reused player, `5c884e9` pause-not-destroy).
- [ ] J5. Mixed voice→text→voice transitions don't stall (TTS render-to-file path, ref: `e1b3c7a`, `c728be7`).
- [ ] J6. No connection drops/skips attributable to main-thread session IPC (ref: `03be6a0`) or priority inversion (ref: `d1eebfd`) — i.e. the long run stays smooth.
- [ ] J7. Battery/low-power mode: repeat a short J1 run in Low Power Mode → still no skips.

## K. Signed-out & auth — #59 [SIM] then [CAR]
- [ ] K1. **Signed out** on phone, then connect CarPlay → CarPlay shows a **graceful signed-out message**, not a broken/empty list or crash (ref: `47e8916`).
- [ ] K2. Sign in on the phone while CarPlay is connected → CarPlay **root refreshes** to show clubs (ref: `47e8916` refresh root on reappear).
- [ ] K3. **Locked phone at connect** (Keychain token unreadable while locked): connect CarPlay with phone locked → after unlock, CarPlay reads the token and loads content (does NOT get stuck signed-out) (ref: `018b4af`).
- [ ] K4. Token expiry / sign-out mid-session → CarPlay handles it without crashing.

## L. App icon — #66 [BOTH]
- [ ] L1. App icon on the **CarPlay dashboard/home** shows **filled corners** — no white/bare corner gaps (ref: `ce9b4b8`).
- [ ] L2. iOS **home-screen** icon still looks correct (unchanged — corners were already masked).
- [ ] L3. The album art on Now Playing (same asset, #55) looks correct, corners not distracting.

## M. Phone-only regression — shared code paths [device, no car]
> The CarPlay work modified code shared with the normal phone app: `AudioPlayerService`
> (session category `.spokenAudio`→`.default`, BT options narrowed to A2DP, reused player,
> session kept active across the queue), `Info.plist` (`UIBackgroundModes: audio`,
> `UISceneConfigurations`), `TokenStore` (Keychain `AfterFirstUnlock`), and the server message
> DTO (added `transcript`). These are NOT CarPlay-gated — verify on a plain phone with no car.

**Playback (AudioPlayerService):**
- [ ] M1. Normal in-app voice playback on the phone (no CarPlay) works, no skips/quality change.
- [ ] M2. Phone chat autoplay through messages still works (reused-player / queue refactor).
- [ ] M3. Text TTS playback on the phone still works (render-to-file path).
- [ ] M4. Audio **route/sound on the phone is unchanged** by the `.spokenAudio`→`.default` mode switch (volume, no unexpected ducking, plays through correct output).
- [ ] M5. **Bluetooth on the phone**: voice plays over A2DP headphones; check an HFP-only/older BT device still gets audio (BT options were narrowed to A2DP).
- [ ] M6. **Other-app audio**: start Spotify/podcast, play a voice message, finish it → the other app's audio **resumes** (session doesn't stay active and keep it ducked/paused indefinitely).
- [ ] M7. Speaker vs. earpiece/Bluetooth routing on the phone is correct after a CarPlay session ends and the phone is used alone.

**Recording (shared audio session):**
- [ ] M8. Recording a voice message on the phone still works; mic chirps/cues behave (ref. closed #11).
- [ ] M9. Record → play → record again on the phone: no session conflict, mic still captures (the `.playAndRecord` vs `.playback` category switching still works).

**Background audio (`UIBackgroundModes: audio` — standard/required for a CarPlay audio app):**
> Declaring this is the convention — it's how every audio app keeps playing in the background,
> and CarPlay audio apps require it. Not a review risk. These checks are behavioral hygiene,
> not a policy decision.
- [ ] M10. Lock-screen / Control Center **Now Playing controls** appear during phone playback and work (play/pause/skip) — a side effect of background audio being enabled.
- [ ] M11. **Session releases when idle**: after playback finishes in the background, the app does NOT stay awake / keep Now Playing / drain battery (session deactivates when nothing is playing).
- [ ] M11b. **No runaway autoplay while locked**: locking the phone mid-message doesn't silently churn through the whole queue if that's not the intended UX — confirm autoplay-while-locked behaves as designed.

**App launch / scenes (new `UISceneConfigurations`):**
- [ ] M12. **Clean launch on a plain phone (no CarPlay)**: app launches and shows its normal UI — adding the CarPlay scene config did not break the default window scene.
- [ ] M13. Backgrounding/foregrounding the normal app, app switcher, cold launch — all normal.

**Auth (TokenStore Keychain change — all users):**
- [ ] M14. **Upgrade path**: install the live 1.6.2 build, sign in, then upgrade to 1.7.0 → still signed in (Keychain accessibility migration on existing token doesn't log the user out).
- [ ] M15. Fresh sign-in on 1.7.0, force-quit, relaunch → still signed in.
- [ ] M16. Sign out works and fully clears the token.

**Server DTO (`transcript` field added) — deploy ordering:**
- [ ] M17. Deploy the updated API, then run the **live 1.6.2 App Store client** against it → no breakage (the added `transcript` field is additive; older clients must ignore it).
- [ ] M18. New 1.7.0 client receives transcripts correctly from the deployed API.

---

## Sign-off
- Build under test: **1.7.0 (1)**
- Tester / date:
- Wireless head unit model:
- Wired tested? Y/N
- Blocking failures (must fix before ship):
- Non-blocking issues (file as new GitHub issues):
- Issues verified & OK to close: #46 ___ #53 ___ #54 ___ #55 ___ #59 ___ #60 ___ #66 ___
