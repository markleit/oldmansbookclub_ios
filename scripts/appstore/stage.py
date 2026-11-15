#!/usr/bin/env python3
"""Stage the App Store screenshot club on the LOCAL dev API (never prod).

A fresh club each run: fictional members (generated avatars), public-domain books (generated covers),
and a Moby-Dick discussion with voice messages (with transcripts), a photo, replies, reactions and
saved messages. Nothing is read for the viewer ("Mark", the app's Dev Login), so the chat opens with
an unread backlog. Prints the club id the screenshot UI test needs.

    python3 scripts/appstore/make_assets.py   # once, or after changing the art
    python3 scripts/appstore/stage.py            → writes scripts/appstore/.stage.json
"""
import datetime as dt, json, os, sys, time, urllib.request, uuid

API = os.environ.get("OMBC_STAGE_API", "http://localhost:5235")
if "azurewebsites" in API or not ("localhost" in API or ".local" in API):
    sys.exit("refusing: staging only runs against a local dev API")
HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
VOICE = os.path.join(HERE, "..", "fixtures", "voice-30s-silent.m4a")
VIEWER = "Mark"                      # AuthViewModel.devLogin()'s fixed display name
MEMBERS = ["Walt", "Hank", "Earl", "Gus", "Frank"]


def call(method, path, token=None, body=None, raw=None, headers=None):
    url = path if path.startswith("http") else API + path
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, data=data, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=120) as r:
        text = r.read()
        return json.loads(text) if text else None


def login(name):
    return call("POST", "/auth/dev-login", body={"display_name": name})["access_token"]


def put_blob(url, path, content_type):
    call("PUT", url, raw=open(path, "rb").read(), headers={"x-ms-blob-type": "BlockBlob", "Content-Type": content_type})


def upload_media(token, club_id, path, ext, content_type):
    up = call("POST", f"/media/upload-url?clubId={club_id}&ext={ext}", token)
    put_blob(up["upload_url"], path, content_type)
    return up["media_url"]


# Local times relative to today: (days ago, "HH:MM").
def at(days_ago, hhmm):
    h, m = map(int, hhmm.split(":"))
    local = dt.datetime.now().astimezone().replace(hour=h, minute=m, second=0, microsecond=0) - dt.timedelta(days=days_ago)
    return local.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# The conversation, oldest first. kind: text | voice(seconds, transcript) | photo(caption)
CHAT = [
    ("Walt",  1, "18:58", "text",  "Welcome aboard, gentlemen. Moby-Dick for November — the big one. 🐋"),
    ("Hank",  1, "19:06", "voice", (38, "I'll admit I was dreading this one. Then the first chapter made me laugh out loud. Melville is funnier than anyone warned me.")),
    ("Earl",  1, "19:14", "photo", "Best opening line ever written. Fight me."),
    ("Gus",   1, "19:16", "text",  "No argument here.", "reply:photo"),
    ("Frank", 1, "19:21", "text",  "Call me Frank. 😄"),
    ("Mark",  1, "19:40", "voice", (52, "Chapter three, the Spouter-Inn. Queequeg and the tomahawk pipe — I did not see that friendship coming.")),
    ("Walt",  1, "19:47", "text",  "Ishmael and Queequeg: best friendship in American literature?"),
    ("Hank",  1, "20:02", "text",  "Easily. That bed scene is comedy gold."),
    ("Gus",   0, "07:12", "voice", (72, "Okay, the cetology chapters. I know they're slow, but I loved them. It's a whaling encyclopedia written by a poet.")),
    ("Earl",  0, "07:31", "text",  "Ahab is every boss I've ever had."),
    ("Frank", 0, "07:48", "voice", (29, "Started chapter thirty-six last night. The quarter-deck speech gave me chills.")),
    ("Hank",  0, "08:05", "text",  "Who's bringing the chowder Thursday? Chapter 15 has me starving."),
    ("Mark",  0, "08:09", "text",  "I'll bring it. Clam, obviously. 🍲"),
    ("Walt",  0, "08:26", "voice", (41, "\"Strike through the mask!\" Read that line out loud tonight. You'll see what I mean.")),
    ("Gus",   0, "08:52", "text",  "Halfway there. Thursday at Walt's, 7 o'clock?"),
    ("Earl",  0, "09:18", "voice", (63, "Running a little behind, but I'll be caught up by Thursday. No spoilers past the Pequod setting sail!")),
]
REACTIONS = {  # message index → [(member, emoji)]
    2: [("Walt", "❤️"), ("Hank", "👍"), ("Gus", "❤️"), ("Frank", "👍")],
    4: [("Walt", "😂"), ("Hank", "😂"), ("Earl", "😂")],
    9: [("Hank", "😂"), ("Walt", "😂"), ("Frank", "👍")],
    12: [("Hank", "❤️"), ("Gus", "👍")],
}
SAVED_BY_VIEWER = [2, 1, 13]

BOOKS = [  # title, author, cover key, status, series
    ("Moby-Dick", "Herman Melville", "moby-dick", "current", None),
    ("Treasure Island", "Robert Louis Stevenson", "treasure-island", "future", None),
    ("The Three Musketeers", "Alexandre Dumas", "three-musketeers", "future", "The d'Artagnan Romances"),
    ("Twenty Years After", "Alexandre Dumas", "twenty-years", "future", "The d'Artagnan Romances"),
    ("Frankenstein", "Mary Shelley", "frankenstein", "future", None),
    ("The Count of Monte Cristo", "Alexandre Dumas", "monte-cristo", "past", None),
    ("Twenty Thousand Leagues Under the Sea", "Jules Verne", "twenty-thousand", "past", None),
    ("The Adventures of Sherlock Holmes", "Arthur Conan Doyle", "sherlock", "past", None),
]


def main():
    viewer = login(VIEWER)
    # A clean name over your own bubbles, and tap-to-talk so one tap shows a recording in progress.
    call("PATCH", "/users/me", viewer, body={"display_name": VIEWER, "nickname": "", "preferences": {"tap_to_talk": True}})
    club = call("POST", "/clubs", viewer, body={"name": "Old Man's Book Club",
                                                "description": f"App Store screenshots {dt.date.today()}"})
    club_id = club["id"]
    tokens = {VIEWER: login(VIEWER)}
    for name in MEMBERS:                      # dev-login joins every club, this one included
        tokens[name] = login(name)
        up = call("POST", "/media/avatar-upload-url", tokens[name])
        put_blob(up["upload_url"], os.path.join(ASSETS, f"avatar-{name.lower()}.jpg"), "image/jpeg")
        call("PATCH", "/users/me", tokens[name], body={"display_name": name, "avatar_url": up["media_url"]})

    book_ids = {}
    for title, author, key, status, series in BOOKS:
        cover = upload_media(viewer, club_id, os.path.join(ASSETS, f"cover-{key}.jpg"), "jpg", "image/jpeg")
        b = call("POST", "/books", viewer, body={"club_id": club_id, "title": title, "author": author,
                                                  "cover_url": cover, "series_name": series})
        book_ids[title] = b["id"]
        if status != "future":
            call("PATCH", f"/books/{b['id']}/status", viewer, body={"status": status})
    call("PUT", "/books/series-order", viewer, body={"club_id": club_id, "series_name": "The d'Artagnan Romances",
         "ordered_book_ids": [book_ids["The Three Musketeers"], book_ids["Twenty Years After"]]})

    book = book_ids["Moby-Dick"]
    photo_url = upload_media(tokens["Earl"], club_id, os.path.join(ASSETS, "photo-page.jpg"), "jpg", "image/jpeg")
    voice_url = None
    ids = []
    for i, entry in enumerate(CHAT):
        who, days, hhmm, kind, payload = entry[:5]
        extra = entry[5] if len(entry) > 5 else None
        msg = {"client_id": str(uuid.uuid4()), "sent_at": at(days, hhmm)}
        if extra == "reply:photo":
            msg["parent_message_id"] = ids[2]
        if kind == "text":
            msg.update(type="Text", body=payload)
        elif kind == "photo":
            msg.update(type="Photo", media_url=photo_url, body=payload)
        else:
            seconds, transcript = payload
            url = upload_media(tokens[who], club_id, VOICE, "m4a", "audio/mp4")
            msg.update(type="Voice", media_url=url, duration_seconds=seconds)
        m = call("POST", f"/books/{book}/messages", tokens[who], body=msg)
        ids.append(m["id"])
        if kind == "voice":
            call("POST", f"/messages/{m['id']}/transcript", tokens[who], body={"transcript": payload[1]})
        time.sleep(0.2)
    for idx, reacts in REACTIONS.items():
        for who, emoji in reacts:
            call("POST", f"/books/{book}/messages/{ids[idx]}/reactions", tokens[who], body={"emoji": emoji})
    for idx in SAVED_BY_VIEWER:
        call("POST", f"/messages/{ids[idx]}/save", viewer)

    # A couple of early messages on the next read, so the Library shows life there too.
    nxt = book_ids["Treasure Island"]
    for who, hhmm, text in [("Frank", "08:40", "Already got my copy. Pirates next month! 🏴‍☠️"),
                            ("Walt", "09:02", "Long John Silver is the best villain in the whole list.")]:
        call("POST", f"/books/{nxt}/messages", tokens[who], body={"type": "Text", "body": text,
             "client_id": str(uuid.uuid4()), "sent_at": at(0, hhmm)})

    out = {"club_id": club_id, "club_name": club["name"], "books": book_ids, "messages": ids}
    json.dump(out, open(os.path.join(HERE, ".stage.json"), "w"), indent=2)
    print(json.dumps({"club_id": club_id, "moby_dick": book}, indent=2))


if __name__ == "__main__":
    main()
