#!/usr/bin/env python3
"""
The hermetic UI tests' fake backend — now a genuine macOS host process, not code running inside
the UI-test-runner.

Why it moved here (#126): the original stub was a Swift `NWListener` created directly inside the
HermeticUITests class, which executes AS PART OF the `OldMansBookClubUITests-Runner.app` —
itself a Simulator-hosted app, a separate process from the app-under-test. Diagnosed directly: the
runner process could reach its own listener instantly (proven with a raw URLSession call from
inside the same process), but the APP UNDER TEST — a different Simulator app — could not reach it
at all, ever, for the full test duration. iOS Simulator does not reliably bridge loopback
connections BETWEEN two Simulator-hosted app processes, even though it does reliably bridge
loopback from any Simulator app to a genuine macOS host process (which is exactly why the live
lane, talking to a real `dotnet run` process, was never affected by this). Moving the stub here —
started by a pre-build script on the OldMansBookClubUITests target (project.yml) before that
target builds — puts it on the same footing as the live lane's real API: a host process, reachable
the same proven way. (A scheme-level pre-action was tried first and rejected: it runs with a
stripped environment — confirmed directly, no $SRCROOT, no $PROJECT_DIR — because XcodeGen does
not wire build-setting inheritance into scheme pre/post actions the way it does for a target's own
build phases.)

Answers requests the same way the retired Swift StubState did: by request SHAPE, not by
enumerating every endpoint. An unrecognised GET returns `[]`, an unrecognised POST returns `{}`.
Plus a small control API (`/_stub/...`) so a test can configure state and read back what the app
requested — replacing what used to be plain Swift property mutation on a fresh per-test object.
This process is long-lived across an entire `xcodebuild test` invocation, so each test's setUp
calls `POST /_stub/reset` first for the isolation a fresh object used to give for free.
"""
import http.server
import json
import socketserver
import sys
import threading
import time
import uuid

PORT = 51235

CLUB_ID = "22222222-2222-2222-2222-222222222222"
USER_ID = "33333333-3333-3333-3333-333333333333"
CURRENT_BOOK_ID = "66666666-6666-6666-6666-666666666666"
FUTURE_BOOK_ID = "77777777-7777-7777-7777-777777777777"

_lock = threading.Lock()
_state = {"messages": [], "saved": [], "refuse_sends": False, "requested_paths": [], "sent": [],
          "upload_url_delay": 0.0, "upload_url_times": [], "by_client_id": {}, "post_attempts": 0}


def _user():
    return {
        "id": USER_ID, "display_name": "Mark", "nickname": None, "avatar_url": None,
        "is_admin": True, "is_club_admin": True, "preferences": {"tap_to_talk": False},
    }


def _book(book_id, title, status, order):
    return {
        "id": book_id, "club_id": CLUB_ID, "title": title, "author": "Test Author",
        "cover_blob_url": None, "added_at": "2026-09-01T00:00:00.000Z", "finished_at": None,
        "status": status, "description": None, "published_year": None, "page_count": None,
        "unread_count": 0, "series_name": None, "series_order": order,
    }


def _test_png(width=2400, height=1600):
    """A wide photo whose left and right thirds differ (red | white | blue), so a test can tell
    whether a zoomed viewer can actually be panned to each edge (#191). Pure-stdlib PNG."""
    import struct
    import zlib

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    third = width // 3
    row = b"\x00" + b"\xd0\x30\x30" * third + b"\xf0\xf0\xf0" * (width - 2 * third) + b"\x30\x30\xd0" * third
    raw = row * height
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def _fixture(name):
    import os
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", name), "rb") as f:
        return f.read()


_MEDIA = {"photo.png": ("image/png", _test_png()),
          # 30s of silent AAC (afconvert), long enough to still be playing while a UI test
          # drives the speed controls (#190) — they only show during playback. Must be real
          # AAC: the app caches voice audio as .m4a, so a WAV would never play.
          "voice.m4a": ("audio/mp4", _fixture("voice-30s-silent.m4a"))}


def _message(item, index):
    # A plain string is a text message; {"type": "Photo"} is a photo served by this stub.
    body, kind, media_url = item, "Text", None
    if isinstance(item, dict):
        kind = item.get("type", "Text")
        body = item.get("body")
        if kind == "Photo":
            # Distinct URL per message (same bytes) so the viewer pages through separate photos.
            media_url = f"http://127.0.0.1:{PORT}/_stub/media/photo.png?m={index}"
        elif kind == "Voice":
            media_url = f"http://127.0.0.1:{PORT}/_stub/media/voice.m4a"
    return {
        "id": f"88888888-8888-8888-8888-{index:012d}", "club_id": CLUB_ID,
        "sender_id": "99999999-9999-9999-9999-999999999999", "sender_name": "Dixie",
        "sender_avatar_url": None, "type": kind, "body": body, "media_url": media_url,
        "duration_seconds": 30 if kind == "Voice" else None, "sent_at": f"2026-09-01T12:00:0{index % 10}.000Z",
        "is_deleted": False, "is_forwarded": False, "client_id": None, "parent_message_id": None,
        "parent_sender_name": None, "parent_preview": None, "parent_sent_at": None,
        "transcript": None, "reactions": None,
    }


def _saved(item, index):
    # Saved Messages (#192): same item shapes as /_stub/messages.
    body, kind, media_url = item, "Text", None
    if isinstance(item, dict):
        kind = item.get("type", "Text")
        body = item.get("body")
        if kind == "Photo":
            media_url = f"http://127.0.0.1:{PORT}/_stub/media/photo.png"
        elif kind == "Voice":
            media_url = f"http://127.0.0.1:{PORT}/_stub/media/voice.m4a"
    return {
        "saved_id": f"aaaaaaaa-aaaa-aaaa-aaaa-{index:012d}",
        "message_id": f"bbbbbbbb-bbbb-bbbb-bbbb-{index:012d}",
        "sender_name": "Dixie", "type": kind, "body": body, "media_url": media_url,
        "duration_seconds": 30 if kind == "Voice" else None, "sent_at": "2026-09-01T12:00:00.000Z",
        "saved_at": "2026-09-02T12:00:00.000Z", "is_deleted": False,
    }


def _echo_sent(body_bytes):
    try:
        parsed = json.loads(body_bytes) if body_bytes else {}
    except json.JSONDecodeError:
        parsed = {}
    return {
        "id": str(uuid.uuid4()), "club_id": CLUB_ID, "sender_id": USER_ID,
        "sender_name": "Mark", "sender_avatar_url": None, "type": parsed.get("type", "Text"),
        "body": parsed.get("body", ""), "media_url": parsed.get("media_url"),
        "duration_seconds": parsed.get("duration_seconds"),
        "sent_at": "2026-09-01T12:30:00.000Z", "is_deleted": False, "is_forwarded": False,
        "client_id": parsed.get("client_id"), "parent_message_id": None,
        "parent_sender_name": None, "parent_preview": None, "parent_sent_at": None,
        "transcript": None, "reactions": None,
    }


class Handler(http.server.BaseHTTPRequestHandler):
    # Without this, BaseHTTPRequestHandler defaults to HTTP/1.0 semantics: it closes the TCP
    # connection after every single response. URLSession (the app's HTTP client) defaults to
    # persistent HTTP/1.1 connections and tries to REUSE one for consecutive requests — so the
    # first request on a fresh connection succeeds, but a later one reusing that now-closed
    # socket can hang waiting for a response that will never arrive. This matched the observed
    # symptom exactly: the library screen (few requests: dev-login, clubs, books) always loaded
    # fine, while entering a book's chat (a burst of more requests: messages, reads, my-heard,
    # hub negotiate) consistently hung — the failure threshold tracked request COUNT, not data.
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # xcodebuild's own log is noisy enough without this too.

    def _send_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length else b""

    def _send_not_found(self):
        body = b"{}"
        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        route = self.path.split("?")[0]

        if route.startswith("/_stub/media/"):
            print(f"media GET {route} {self.headers.get('Range', '')}", flush=True)
            media = _MEDIA.get(route.rsplit("/", 1)[-1])
            if media is None:
                return self._send_not_found()
            content_type, data = media
            # AVPlayer streams over HTTP with byte-range requests (Azure Blob honours them) and
            # won't play from a server that ignores Range, so answer "bytes=a-b" with a 206.
            status, start, end = 200, 0, len(data) - 1
            header = self.headers.get("Range", "")
            if header.startswith("bytes="):
                first, _, last = header[len("bytes="):].partition("-")
                start = int(first) if first else 0
                end = min(int(last), len(data) - 1) if last else len(data) - 1
                status = 206
            body = data[start:end + 1]
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(len(body)))
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
            self.end_headers()
            self.wfile.write(body)
            return

        if route == "/_stub/upload-url-times":
            with _lock:
                return self._send_json(_state["upload_url_times"])

        if route == "/_stub/sent":
            with _lock:
                return self._send_json(_state["sent"])

        if route == "/_stub/requests":
            with _lock:
                return self._send_json(_state["requested_paths"])

        with _lock:
            _state["requested_paths"].append(f"GET {self.path}")

        if route == "/users/me":
            return self._send_json(_user())
        if route == "/clubs":
            return self._send_json([{
                "id": CLUB_ID, "name": "Old Man's Book Club", "description": None,
                "cover_blob_url": None, "is_club_admin": True,
            }])
        if route == "/books":
            return self._send_json([
                _book(CURRENT_BOOK_ID, "Seed: Current Read", "current", 0),
                _book(FUTURE_BOOK_ID, "Seed: Future Read", "future", 0),
            ])
        if route == "/messages/saved":
            with _lock:
                saved = list(_state["saved"])
            return self._send_json([_saved(item, i) for i, item in enumerate(saved)])
        if route == f"/books/{CURRENT_BOOK_ID}/messages":
            with _lock:
                messages = list(_state["messages"])
            return self._send_json([_message(b, i) for i, b in enumerate(messages)])

        # SignalR is deliberately unsupported: /hubs/chat/negotiate must fail with a real HTTP
        # error, not a generic 200 {}. A malformed-but-200 negotiate response gets far enough into
        # the SignalR client's handshake to attempt a WebSocket upgrade against a server that
        # doesn't speak the protocol, which hangs for many seconds before giving up — long enough
        # to blow past a UI test's wait for the chat screen to render. A hard 404 is what "no such
        # hub here" actually means, and it is what makes the client abandon the attempt quickly,
        # exactly like it does with no server at all. The REST-driven chat still renders fine
        # either way — only realtime delivery is unsupported here, which lanes B and C cover.
        if route.startswith("/hubs/"):
            return self._send_not_found()

        return self._send_json([])

    def do_POST(self):
        route = self.path.split("?")[0]
        body = self._body()

        if route == "/_stub/reset":
            with _lock:
                _state["messages"] = []
                _state["saved"] = []
                _state["refuse_sends"] = False
                _state["requested_paths"] = []
                _state["sent"] = []
                _state["upload_url_delay"] = 0.0
                _state["upload_url_times"] = []
                _state["by_client_id"] = {}
                _state["post_attempts"] = 0
            return self._send_json({"status": "reset"})

        if route == "/_stub/messages":
            with _lock:
                _state["messages"] = json.loads(body) if body else []
            return self._send_json({"status": "ok"})

        if route == "/_stub/saved":
            with _lock:
                _state["saved"] = json.loads(body) if body else []
            return self._send_json({"status": "ok"})

        if route == "/_stub/refuse-sends":
            payload = json.loads(body) if body else {}
            with _lock:
                _state["refuse_sends"] = bool(payload.get("refuse", False))
            return self._send_json({"status": "ok"})

        with _lock:
            _state["requested_paths"].append(f"POST {self.path}")

        if route.startswith("/hubs/"):
            return self._send_not_found()

        if route in ("/auth/dev-login", "/auth/refresh"):
            return self._send_json({
                "access_token": "stub-access-token", "refresh_token": "stub-refresh-token",
                "user": _user(),
            })
        # Media send (#201): hand out an upload URL on this stub, accept the PUT, and serve the
        # "uploaded" photo back from /_stub/media so the sent bubble renders.
        if route == "/_stub/upload-url-delay":
            payload = json.loads(body) if body else {}
            with _lock:
                _state["upload_url_delay"] = float(payload.get("seconds", 0))
            return self._send_json({"status": "ok"})

        if route == "/media/upload-url":
            # #203 — record when each request ARRIVES (before any delay), so a test can tell a
            # batch whose sends start together from one that starts them one after another.
            with _lock:
                _state["upload_url_times"].append(time.time())
                delay = _state["upload_url_delay"]
            if delay:
                time.sleep(delay)
            blob = uuid.uuid4().hex
            return self._send_json({
                "upload_url": f"http://127.0.0.1:{PORT}/_stub/upload/{blob}.jpg",
                "media_url": f"http://127.0.0.1:{PORT}/_stub/media/photo.png?u={blob}",
            })
        if route.startswith("/_stub/upload/"):
            return self._send_json({})

        if route == f"/books/{CURRENT_BOOK_ID}/messages":
            with _lock:
                refuse = _state["refuse_sends"]
            if refuse:
                return self._send_json({"error": "stub refused this send"})
            # Mirror the real server's clientId dedup (MessageSendService): a repeat of a clientId
            # returns the message already created, and isn't a second message. The app now posts
            # media both directly and via the background session (#203), so this matters.
            echoed = _echo_sent(body)
            with _lock:
                _state["post_attempts"] += 1
                cid = echoed.get("client_id")
                if cid and cid in _state["by_client_id"]:
                    return self._send_json(_state["by_client_id"][cid])
                if cid:
                    _state["by_client_id"][cid] = echoed
                _state["sent"].append({"type": echoed["type"], "body": echoed["body"],
                                       "media_url": echoed["media_url"]})
            return self._send_json(echoed)

        return self._send_json({})

    # PATCH/PUT/DELETE all fall through to the same "unrecognised POST" shape.
    do_PATCH = do_POST
    do_PUT = do_POST
    do_DELETE = do_POST


def main():
    with socketserver.ThreadingTCPServer(("127.0.0.1", PORT), Handler) as httpd:
        httpd.allow_reuse_address = True
        print(f"hermetic stub listening on http://127.0.0.1:{PORT}", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
