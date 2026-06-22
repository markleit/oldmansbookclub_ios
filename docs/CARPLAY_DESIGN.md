# CarPlay — Browse & Play design

Status: design / not started. Tracking issue: CarPlay support (split from #18).

## Scope (phase 1)
Hands-free **browse + play** of book-club voice messages in the car:
- Choose club → book → see recent messages with indicators (unread / unheard).
- Play a message; **auto-play through unheard** messages (queue), with dash/wheel controls.
- Marking heard in the car syncs unread state everywhere (reuses the `MessageHeard` system).

**Out of scope for phase 1:** creating a new voice message from CarPlay (recording). That
forces the harder *communication* entitlement and concentrates the audio-session + driving-
distraction risk — deferred to a later phase. See "Deferred: recording" below.

## Entitlement
Browse + play (no recording) = an **audio** CarPlay app → `com.apple.developer.carplay-audio`.
This is the common, readily-granted CarPlay category (every podcast/music app has it), far
easier than `carplay-communication`. Must be requested from Apple.

⚠️ **You CANNOT test CarPlay (sim OR car) until Apple grants the entitlement.** It's a MANAGED
entitlement: Xcode's automatic signing strips it from builds until the App ID has it enabled,
and the iOS Simulator's SpringBoard **refuses to launch** an app carrying it if it isn't
legitimately provisioned ("denied by service delegate (SBMainWorkspace)"). Ad-hoc re-signing
the .app to embed it gets past signing but still fails launch. So: with the entitlement the app
won't launch un-provisioned; without it the CarPlay scene doesn't register. Net — CarPlay dev is
gated on the entitlement grant (request submitted 2026-06-22), full stop. (Verified the hard way
this session; earlier assumption that the sim works while pending was wrong.)

## Architecture
The CarPlay scene runs in the **same app process** as the phone UI, so it shares all existing
singletons — no new backend:
- `APIClient` (getMyBooks, getMessages, markHeard)
- `ChatService` (SignalR live updates)
- `AudioPlayerService` (AVPlayer, audio session, AudioCache, resume position, auto-advance)
- `TranscriptStore` (voice transcripts for readable rows)
- unread/heard system (`MessageHeard`, per-book unread counts)
- `ImageCache` (covers)

Entry point: a `CPTemplateApplicationSceneDelegate` registered in the Info.plist scene
manifest (CarPlay scene role). `didConnect(interfaceController:)` provides a
`CPInterfaceController` for push/pop of templates.

## Navigation & row layout

### 1. Clubs (root `CPListTemplate`) — skipped if user has one club
```
Clubs
─────────────────────────────
  Old Man's Book Club      ›
  Sci-Fi Saturdays   · 2   ›   (trailing = total unread)
```

### 2. Books (`CPListTemplate`)
```
Old Man's Book Club
─────────────────────────────
 [cover]  Dune                 · 3 new   ›   (currently reading, sorted first)
 [cover]  Project Hail Mary             ›
 [cover]  The Hobbit            · 1 new  ›
```
Row = cover image + title; trailing detail = unread count (omitted when 0).

### 3. Messages (`CPListTemplate`)
```
Dune
─────────────────────────────
 ▶  Play all unheard (3)
─────────────────────────────
 ● Tom · 3:42 PM
   "I loved the twist at the end of…"      (title = transcript)
 ● Dixie · 3:40 PM
   🎤 Voice message                        (no transcript yet)
   Mark · 3:31 PM
   "Did everyone finish chapter 5?"        (no dot = already heard)
```
- Title = transcript (or "🎤 Voice message" until transcribed).
- Subtitle = "Sender · time".
- Leading dot (●) = unheard. Cleared after playback.
- Pinned top row = "Play all unheard (N)".
- Limited to recent N (CarPlay caps visible rows while driving, ~12) — unheard first.

### 4. Now Playing (`CPNowPlayingTemplate`)
System Now Playing screen, fed via `MPNowPlayingInfoCenter` (sender, transcript, cover) and
`MPRemoteCommandCenter` (play/pause/next/prev → car dash + steering-wheel buttons).

## Playback & auto-play
- Playback goes through the existing `AudioPlayerService` (same engine as the phone).
- **Auto-play**: when a voice message finishes, advance to the next one — this behavior
  already exists (`onPlaybackCompleted`). "Play all unheard" = build a queue of the unheard
  voice messages (chronological) and let auto-advance run; next/prev remote commands step it.
- **Mark heard on completion**: the existing `markHeard` fires → `MessageHeard` updates →
  unread clears on phone + badge. Listening in the car keeps state consistent everywhere.

### ⚠️ Refactor needed: playback queue ownership
Today `AudioPlayerService.onPlaybackCompleted` is a single callback set by `BookDetailView`.
The CarPlay scene needs to drive its own continuous-play queue without fighting the chat view
for that one callback. Introduce a small **playback queue** abstraction in `AudioPlayerService`
(an ordered list + "advance" policy) that both the chat autoplay and CarPlay "play all unheard"
use, instead of a single externally-owned completion closure.

## Live updates
The CarPlay delegate subscribes to the same SignalR events. On a new message: refresh the
visible list (`CPListTemplate.updateSections`) and unread counts. Trigger transcription for
visible voice rows (as the reply chip does) so rows become readable.

## Constraints
- CarPlay limits visible rows in motion (~12) — show recent/unheard only; full backlog not
  browsable in-car by design.
- Glanceable: short text, large targets, transcript truncated to one line.
- Covers provided as `UIImage` at CarPlay sizes (from `ImageCache`).

## Phased build
1. CarPlay scene scaffolding + audio entitlement (request from Apple early — long pole).
2. Browse templates (clubs → books → messages) fed by `APIClient`, with unread/transcript/cover.
3. Playback queue refactor + `CPNowPlayingTemplate` + remote commands + mark-heard-on-finish.
4. SignalR-driven live list refresh + transcript fetch for visible rows.

## Deferred: recording (separate, later phase)
Creating a new voice message in-car needs the **communication** entitlement (Zello-style PTT),
a `CPVoiceControlTemplate`-style capture UI, a shorter in-car voice cap for safety/approval,
and careful audio-session handling (play + record over CarPlay HFP while ducking car audio).
Higher approval scrutiny + most of the technical risk. Design separately once browse+play ships.

## Open decisions
- Confirm OK to ship as **audio-category** (browse+play) first, recording later.
- Single-club users: skip the club chooser.
- Messages list: recent-unheard-first, capped (Apple-friendly).
