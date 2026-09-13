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
import uuid

PORT = 51235

CLUB_ID = "22222222-2222-2222-2222-222222222222"
USER_ID = "33333333-3333-3333-3333-333333333333"
CURRENT_BOOK_ID = "66666666-6666-6666-6666-666666666666"
FUTURE_BOOK_ID = "77777777-7777-7777-7777-777777777777"

_lock = threading.Lock()
_state = {"messages": [], "refuse_sends": False, "requested_paths": []}


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


def _message(body, index):
    return {
        "id": f"88888888-8888-8888-8888-{index:012d}", "club_id": CLUB_ID,
        "sender_id": "99999999-9999-9999-9999-999999999999", "sender_name": "Dixie",
        "sender_avatar_url": None, "type": "Text", "body": body, "media_url": None,
        "duration_seconds": None, "sent_at": f"2026-09-01T12:00:0{index % 10}.000Z",
        "is_deleted": False, "is_forwarded": False, "client_id": None, "parent_message_id": None,
        "parent_sender_name": None, "parent_preview": None, "parent_sent_at": None,
        "transcript": None, "reactions": None,
    }


def _echo_sent(body_bytes):
    try:
        parsed = json.loads(body_bytes) if body_bytes else {}
    except json.JSONDecodeError:
        parsed = {}
    return {
        "id": str(uuid.uuid4()), "club_id": CLUB_ID, "sender_id": USER_ID,
        "sender_name": "Mark", "sender_avatar_url": None, "type": "Text",
        "body": parsed.get("body", ""), "media_url": None, "duration_seconds": None,
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
                _state["refuse_sends"] = False
                _state["requested_paths"] = []
            return self._send_json({"status": "reset"})

        if route == "/_stub/messages":
            with _lock:
                _state["messages"] = json.loads(body) if body else []
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
        if route == f"/books/{CURRENT_BOOK_ID}/messages":
            with _lock:
                refuse = _state["refuse_sends"]
            if refuse:
                return self._send_json({"error": "stub refused this send"})
            return self._send_json(_echo_sent(body))

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
