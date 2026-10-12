# 2.2 device regression: sending and recording

The device-only rows of `docs/SEND_REQUIREMENTS.md` ("**Device**"), as a checklist for the TestFlight
build. 2.2 replaces how every message leaves the phone (#204 design v2) and how recording handles
interruptions (#213), so this is run in full on the release candidate, and the **P1** rows on any
later build that touches sending.

**How to run it**
- The TestFlight build (Release): real timings — the reminder comes 10 minutes after the oldest
  unsent message. Signed in to your real account; send to a chat everyone tolerates test messages in.
- **Evidence:** after each group, send Feedback from the app (it attaches the send log). A failure
  is a missing message, a message that needed the app opened, or a wrong order — note the time.
- **"Locked"** means the screen off with the side button, phone left alone. **"Arrives"** means it
  shows on another device (the Mac, or a second phone) — not just a tick on your own phone.
- Priority: **P1** must pass to ship; **P2** should pass — a failure is triaged, not automatically
  a blocker.

## 1. Sending: the core (P1)

| ID | Steps | Expected |
|---|---|---|
| M1 | In a chat, send a text, a voice message, a photo and a video (pick it; Send appears once it's prepared) | Each arrives within a few seconds; the video shows "preparing" (a progress circle where Send is) first |
| M2 | Send all four kinds, tap Back to the Library at once | All arrive; the Library shows no "unsent" once they have |
| M3 | Send all four kinds, press Home at once | All arrive without reopening the app |
| M4 | Send all four kinds, lock at once | All arrive while locked |
| M5 | Open the app online. Airplane Mode on. Send 10 photos, a voice message and a video. Lock. Wait 10 s. Airplane Mode off | **Everything arrives without unlocking** — usually within seconds, sometimes a minute or more (iOS decides; L1). The video too (it uses an upload slot fetched while online) |
| M5b | As M5, but use up the slots first: send 4 videos offline in a row, then lock, then Airplane Mode off | The first 3 go without the app (slots); the 4th waits until the app is opened (no slot left, can't reserve offline) — this is the stated gap, not a failure |
| M6 | Turn Wi-Fi off and use cellular; repeat M4 with a video | Arrives over cellular |
| M7 | Airplane Mode on, send a text, swipe the app away (force-quit). Wait 10 min | A notification says it'll send when you open the app. Open the app with the network back → it sends; no notification once everything's sent |
| M8 | Airplane Mode on, send a text and a photo, restart the phone, unlock, Airplane Mode off — don't open the app | Both arrive (iOS kept them through the restart); if not within a few minutes, open the app → they go at once |
| M9 | In a chat, send a message, then a video, then a voice message, quickly | On a 2.2 device they show in the order sent (video above the voice message) even if the video lands last; a "↑ New message above" chip appears on other 2.2 devices when something lands above what they've seen |

## 2. Video, prepared before Send (P1)

| ID | Steps | Expected |
|---|---|---|
| V1 | Pick a long video (2–4 min) | Progress circle while it's prepared; Send appears when ready; the time it took is reasonable (note it) |
| V2 | Pick a video, press Home while it's preparing, come back after 10 s | Preparing carries on and Send appears; nothing was sent while you were away |
| V3 | Pick a video over 5 minutes | "Video is too long (max 5 minutes)…" before anything is sent; the composer is cleared |
| V4 | Pick a video, tap ✕ on it while preparing | Removed; nothing sent |
| V5 | Open a chat in a **different club** (if you have one), send a video while offline | Same as M5 for that club (each club keeps its own slots) |

## 3. Upgrade and old clients (P1)

| ID | Steps | Expected |
|---|---|---|
| U1 | With the App Store 2.1 installed: Airplane Mode on, send a text and a photo (they queue in 2.1). Install 2.2 from TestFlight over it, Airplane Mode off, open | Both are taken over and sent once — no duplicates |
| U2 | On the Mac (2.1): send a text, voice, photo and video to the chat | All arrive on the phone (2.2); the Mac's video still works its old way |
| U3 | On the Mac (2.1), look at what the phone sent in M5 and M9 | Everything is there (the Mac orders by arrival — expected for 2.1) |

## 4. Recording interruptions (#213) (P1)

| ID | Steps | Expected |
|---|---|---|
| R1 | Record a voice message; have someone call; **decline** within 15 s | Recording resumes into the same message ("Recording resumed"); one message with both parts |
| R2 | Record; **answer** the call | What was recorded before the call is sent |
| R3 | Record; let a call ring past 15 s and decline | What was recorded is sent; no resume |
| R4 | Hold-to-talk: hold, get a call, lift your finger during it, decline | Sent without resuming |
| R5 | Record; trigger Siri or an alarm | Resumes within 15 s, or sends what was recorded |
| R6 | Record while a notification sound plays; connect/disconnect AirPods mid-recording | Recording carries on |
| R7 | Tap-to-talk: start recording, tap Back | The recording is sent |
| R8 | Record, then lock the phone | What was recorded is sent |

## 5. Share sheet and forward (P2)

| ID | Steps | Expected |
|---|---|---|
| S1 | Airplane Mode on; in Photos, share a photo to a chat | The sheet closes at once; Airplane Mode off while locked → it arrives without opening the app |
| S2 | Don't open the app for over an hour; share a photo from Photos | Sends (the share sheet signs itself in) |
| F1 | Saved Messages → forward one to another chat | "Forwarded" confirmation; arrives once |

## 6. Conditions (P2)

| ID | Steps | Expected |
|---|---|---|
| C1 | Low Power Mode on, repeat M5 | Arrives without unlocking (may take longer — note how long) |
| C2 | Settings → OMBC → Background App Refresh off, repeat M5 | Same as C1 |
| C3 | Weak signal (lift, basement): send a photo batch and lock | Arrives once signal is back; nothing shown red |

## 7. Everything else 2.2 touched (P2)

| ID | Steps | Expected |
|---|---|---|
| X1 | The − / + buttons beside a voice message's speed | Steps 0.05× (1× → 1.05×); the slider still moves freely |
| X2 | A waiting message (Airplane Mode on): tap it | "Will send automatically", **Send now**, **Delete**; Delete removes it and it never arrives |
| X3 | Admin → delete one of the leftover test members (the old "Simulator" accounts) | Deleted without an error; the chat stays readable for everyone else |
| X4 | Library unread badges and push notifications with messages arriving from someone else | Unchanged from 2.1 |
| X5 | CarPlay checklist (`docs/TESTING.md` → CarPlay manual checklist) | All pass (2.2 changed recording and audio handling) |

**Not tested on device (proven by automated tests instead):** server outage recovery (can't stop
production), a token that expires while a message waits (send token: 7 days), refusals with a
reason, and the API rules — see `docs/SEND_REQUIREMENTS.md`.
