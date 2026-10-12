#!/usr/bin/env python3
"""
#204 (C4) — the hermetic stub's own tests. The 2.2 send tests lean on the stub behaving like the
real server (dedup, 429 + Retry-After, the file-body send, dropped connections); if the stub is
wrong, a UI test can pass while proving nothing. Runs in the API CI job (seconds, stdlib only):

    python3 scripts/test_hermetic_stub.py
"""
import http.client
import json
import os
import socket
import subprocess
import sys
import time
import unittest
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class StubTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.port = _free_port()
        env = dict(os.environ, OMBC_STUB_PORT=str(cls.port))
        cls.proc = subprocess.Popen([sys.executable, os.path.join(HERE, "hermetic_stub.py")], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        line = cls.proc.stdout.readline()
        assert "listening on" in line, line

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(5)

    def setUp(self):
        self.request("POST", "/_stub/reset")

    def request(self, method, path, body=None, content_type="application/json"):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        data = body if isinstance(body, (bytes, type(None))) else json.dumps(body).encode()
        headers = {"Content-Type": content_type} if data is not None else {}
        conn.request(method, path, body=data, headers=headers)
        response = conn.getresponse()
        raw = response.read()
        conn.close()
        return response.status, dict(response.getheaders()), (json.loads(raw) if raw else None)

    def send_text(self, client_id=None, **extra):
        payload = {"type": "Text", "body": "hi", "client_id": client_id or str(uuid.uuid4())}
        payload.update(extra)
        return self.request("POST", "/books/66666666-6666-6666-6666-666666666666/messages", payload)

    def sent(self):
        return self.request("GET", "/_stub/sent")[2]

    # ---- the wire shape ----------------------------------------------------------------------

    def test_every_message_has_exactly_the_servers_fields(self):
        with open(os.path.join(ROOT, "Tests", "contract", "message_minimal_rest.json")) as f:
            server_keys = set(json.load(f))
        self.request("POST", "/_stub/messages", ["seeded"])
        _, _, history = self.request("GET", "/books/66666666-6666-6666-6666-666666666666/messages")
        _, _, echo = self.send_text()
        self.assertEqual(set(history[0]), server_keys)
        self.assertEqual(set(echo), server_keys)

    # ---- sends -------------------------------------------------------------------------------

    def test_a_json_send_records_its_client_id_and_tap_time(self):
        cid = str(uuid.uuid4())
        status, _, echo = self.send_text(cid, sent_at="2026-10-10T10:00:00.000Z")
        self.assertEqual(status, 200)
        self.assertEqual(echo["sent_at"], "2026-10-10T10:00:00.000Z")
        self.assertIsNotNone(echo["received_at"])
        record = self.sent()[0]
        self.assertEqual((record["client_id"], record["sent_at"], record["via"]), (cid, "2026-10-10T10:00:00.000Z", "json"))

    def test_a_repeated_client_id_is_one_message(self):
        cid = str(uuid.uuid4())
        first = self.send_text(cid)[2]
        second = self.send_text(cid)[2]
        self.assertEqual(first["id"], second["id"])
        self.assertEqual(len(self.sent()), 1)

    def test_the_file_body_send(self):
        cid = str(uuid.uuid4())
        path = (f"/books/66666666-6666-6666-6666-666666666666/messages?client_id={cid}"
                f"&duration_seconds=12&sent_at=2026-10-10T10:00:00.000Z")
        status, _, echo = self.request("POST", path, b"\x00\x01\x02", content_type="audio/mp4")
        self.assertEqual(status, 200)
        self.assertEqual((echo["type"], echo["duration_seconds"], echo["client_id"]), ("Voice", 12, cid))
        record = self.sent()[0]
        self.assertEqual((record["via"], record["size"], record["content_type"]), ("file", 3, "audio/mp4"))
        # And dedup holds for it too.
        self.request("POST", path, b"\x00\x01\x02", content_type="audio/mp4")
        self.assertEqual(len(self.sent()), 1)

    def test_sends_to_any_book_work(self):
        status, _, _ = self.request("POST", "/books/77777777-7777-7777-7777-777777777777/messages",
                                    {"type": "Text", "body": "other book", "client_id": str(uuid.uuid4())})
        self.assertEqual(status, 200)
        self.assertEqual(self.sent()[0]["book_id"], "77777777-7777-7777-7777-777777777777")

    def test_a_forward_takes_the_saved_originals_content(self):
        self.request("POST", "/_stub/saved", [{"type": "Photo"}])
        _, _, saved = self.request("GET", "/messages/saved")
        _, _, echo = self.send_text(forward_message_id=saved[0]["message_id"])
        self.assertTrue(echo["is_forwarded"])
        self.assertEqual(echo["type"], "Photo")

    # ---- scripted trouble --------------------------------------------------------------------

    def test_scripted_responses_are_used_in_order_then_normal_handling_resumes(self):
        self.request("POST", "/_stub/script", {"route": "POST /books/*/messages",
                                               "responses": [{"status": 503}, {"status": 429, "retry_after": 2}]})
        self.assertEqual(self.send_text()[0], 503)
        status, headers, body = self.send_text()
        self.assertEqual((status, headers.get("Retry-After")), (429, "2"))
        self.assertIn("error", body)
        self.assertEqual(self.send_text()[0], 200)
        self.assertEqual(len(self.sent()), 1)   # only the one that got through

    def test_a_step_for_one_content_type_leaves_other_requests_alone(self):
        # The photo is held up; the text sent after it on the same route isn't (#204 PR 6's O3 test).
        self.request("POST", "/_stub/script", {"route": "POST /books/*/messages",
                                               "responses": [{"status": 503, "content_type": "image/jpeg"}]})
        self.assertEqual(self.send_text()[0], 200, "a JSON send doesn't use up the photo's step")
        path = f"/books/66666666-6666-6666-6666-666666666666/messages?client_id={uuid.uuid4()}"
        self.assertEqual(self.request("POST", path, b"\xff\xd8", content_type="image/jpeg")[0], 503)
        self.assertEqual(self.request("POST", path, b"\xff\xd8", content_type="image/jpeg")[0], 200)

    def test_a_dropped_connection_gets_no_answer(self):
        self.request("POST", "/_stub/script", {"route": "POST /books/*/messages", "responses": [{"drop": True}]})
        with self.assertRaises((http.client.HTTPException, ConnectionError, OSError)):
            self.send_text()
        self.assertEqual(self.send_text()[0], 200)

    def test_a_delay_only_step_answers_normally_after_the_delay(self):
        self.request("POST", "/_stub/script", {"route": "POST /books/*/messages", "responses": [{"delay": 0.5}]})
        start = time.time()
        self.assertEqual(self.send_text()[0], 200)
        self.assertGreaterEqual(time.time() - start, 0.5)

    def test_server_down_drops_everything_but_the_control_api(self):
        self.request("POST", "/_stub/down", {"down": True})
        with self.assertRaises((http.client.HTTPException, ConnectionError, OSError)):
            self.request("GET", "/books")
        self.assertEqual(self.request("GET", "/_stub/sent")[0], 200)
        self.request("POST", "/_stub/down", {"down": False})
        self.assertEqual(self.request("GET", "/books")[0], 200)

    def test_a_send_left_over_from_an_earlier_test_is_ignored(self):
        # A background transfer from the previous test arrives after this test's reset.
        _, _, login = self.request("POST", "/auth/dev-login", {})
        old_token = login["access_token"]
        self.request("POST", "/_stub/reset")
        self.request("POST", "/_stub/script", {"route": "POST /books/*/messages", "responses": [{"status": 503}]})
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("POST", "/books/66666666-6666-6666-6666-666666666666/messages",
                     body=json.dumps({"type": "Text", "body": "stray", "client_id": str(uuid.uuid4())}),
                     headers={"Content-Type": "application/json", "Authorization": f"Bearer {old_token}"})
        self.assertEqual(conn.getresponse().status, 401)
        conn.close()
        self.assertEqual(self.sent(), [], "not recorded")
        self.assertEqual(self.send_text()[0], 503, "and the scripted response is still there for this test")
        # This test's own sign-in works.
        _, _, fresh = self.request("POST", "/auth/refresh", {})
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("GET", "/books", headers={"Authorization": f"Bearer {fresh['access_token']}"})
        self.assertEqual(conn.getresponse().status, 200)
        conn.close()

    def test_a_send_still_in_progress_when_the_next_test_starts_is_not_recorded_there(self):
        # A scripted delay outlasts the test that set it; the next test's reset happens meanwhile.
        import threading
        self.request("POST", "/_stub/script", {"route": "POST /books/*/messages", "responses": [{"delay": 1.0}]})
        result = {}
        thread = threading.Thread(target=lambda: result.setdefault("r", self.send_text()))
        thread.start()
        time.sleep(0.3)
        self.request("POST", "/_stub/reset")
        thread.join(5)
        self.assertEqual(result["r"][0], 200, "still answered")
        self.assertEqual(self.sent(), [], "but not recorded into the next test")

    def test_a_late_arrival_can_be_seeded(self):
        self.request("POST", "/_stub/messages", [{"body": "late", "sent_at": "2026-09-01T09:00:00.000Z",
                                                  "received_at": "2026-09-01T12:00:00.000Z"}])
        _, _, history = self.request("GET", "/books/66666666-6666-6666-6666-666666666666/messages")
        self.assertEqual((history[0]["sent_at"], history[0]["received_at"]),
                         ("2026-09-01T09:00:00.000Z", "2026-09-01T12:00:00.000Z"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
