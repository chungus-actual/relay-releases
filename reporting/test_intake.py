import base64
import hashlib
import io
import json
import threading
import unittest
import urllib.error
import urllib.request
import zipfile
from http.server import ThreadingHTTPServer
from intake import Handler, Intake, MAX_REQUEST, PNG, Rejected, bundle


def fixture():
    return {"schema": 1, "id": "e2f0c426-4864-4d32-9e40-413acb6072c9", "created": "2026-09-25T00:00:00Z",
            "description": "Messages disappear; scrolling restores them. 界", "diagnostics": {"engine": "WebKit"},
            "events": "2026-09-25 messenger navigation-complete", "screenshot": base64.b64encode(PNG + b"fixture").decode()}


class FakeGitHub:
    repo = "chungus-actual/relay"
    def __init__(self):
        self.private = True
        self.files = {}
        self.issues = []
        self.issue_failure = False
        self.ambiguous_upload = False
    def call(self, method, path="", body=None):
        if path == "":
            return 200, {"private": self.private}
        if path == "/issues":
            self.issues.append(body)
            if self.issue_failure:
                raise OSError("simulated uncertain issue response")
            return 201, {}
        path = path.split("?")[0]
        if method == "GET":
            if path not in self.files:
                return 404, {}
            data = self.files[path]
            digest = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
            return 200, {"sha": digest}
        if method == "PUT":
            if path in self.files:
                return 422, {}
            self.files[path] = base64.b64decode(body["content"])
            if self.ambiguous_upload:
                raise OSError("simulated connection loss after commit")
            return 201, {}
        raise AssertionError((method, path))


class IntakeChecks(unittest.TestCase):
    def setUp(self):
        self.github = FakeGitHub()
        self.intake = Intake(self.github)
    def test_bundle_keeps_image_description_and_log(self):
        report, data = bundle(json.dumps(fixture()))
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            self.assertEqual(set(archive.namelist()), {"report.json", "screenshot.png"})
            self.assertEqual(archive.read("screenshot.png"), PNG + b"fixture")
            self.assertEqual(json.loads(archive.read("report.json")), report)
        reordered = dict(reversed(list(fixture().items())))
        self.assertEqual(data, bundle(json.dumps(reordered))[1])
    def test_optional_image_and_reject_unknown_data(self):
        report = fixture()
        report.pop("screenshot")
        with zipfile.ZipFile(io.BytesIO(bundle(json.dumps(report))[1])) as archive:
            self.assertEqual(archive.namelist(), ["report.json"])
        report["cookies"] = "not allowed"
        with self.assertRaises(Rejected):
            bundle(json.dumps(report))
    def test_bounds_and_invalid_payloads(self):
        for field, value in [("schema", True), ("schema", 1.0), ("id", "../../elsewhere"), ("description", " "), ("description", "x" * 8001),
                             ("diagnostics", {"x": "y" * 4097}), ("events", "x" * 65537), ("screenshot", "not-base64"),
                             ("screenshot", base64.b64encode(b"not a png").decode())]:
            report = fixture(); report[field] = value
            with self.subTest(field=field), self.assertRaises(Rejected):
                bundle(json.dumps(report))
        for raw in ["null", "[]", "{", '"string"']:
            with self.assertRaises(Rejected):
                bundle(raw)
    def test_retry_creates_one_bundle_and_one_issue(self):
        raw = json.dumps(fixture())
        self.assertTrue(self.intake.submit(raw)["issueCreated"])
        self.assertTrue(self.intake.submit(raw)["duplicate"])
        self.assertEqual(len(self.github.files), 1)
        self.assertEqual(len(self.github.issues), 1)
        changed = fixture(); changed["description"] = "Changed after sending"
        with self.assertRaises(Rejected) as error:
            self.intake.submit(json.dumps(changed))
        self.assertEqual(error.exception.status, 409)
    def test_public_repo_never_receives_reports(self):
        self.github.private = False
        with self.assertRaises(Rejected):
            self.intake.submit(json.dumps(fixture()))
        self.assertFalse(self.github.files)
        self.assertFalse(self.github.issues)
    def test_ambiguous_upload_and_issue_responses_do_not_duplicate(self):
        self.github.ambiguous_upload = True
        raw = json.dumps(fixture())
        with self.assertRaises(OSError):
            self.intake.submit(raw)
        self.assertTrue(self.intake.submit(raw)["stored"])
        self.assertFalse(self.github.issues)
        self.github = FakeGitHub(); self.github.issue_failure = True
        self.intake = Intake(self.github)
        self.assertFalse(self.intake.submit(raw)["issueCreated"])
        self.assertTrue(self.intake.submit(raw)["duplicate"])
        self.assertEqual(len(self.github.issues), 1)
    def test_description_cannot_inject_github_mentions(self):
        report = fixture(); report["description"] = "@everyone [link](https://example.invalid/)"
        self.intake.submit(json.dumps(report))
        self.assertNotIn("@everyone", self.github.issues[0]["body"])
    def test_racing_create_returns_receipt_without_duplicate_issue(self):
        original = self.github.call
        def raced(method, path="", body=None):
            if method == "PUT":
                self.github.files[path] = base64.b64decode(body["content"])
                return 422, {}
            return original(method, path, body)
        self.github.call = raced
        self.assertTrue(self.intake.submit(json.dumps(fixture()))["duplicate"])
        self.assertEqual(len(self.github.files), 1)
        self.assertFalse(self.github.issues)
    def test_http_auth_size_receipt_and_retry(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.intake, server.intake_key = self.intake, b"test-intake-code"
        server.report_slot, server.accepted = threading.Lock(), []
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}/reports"
            def post(key="test-intake-code", length=None):
                headers = {"Content-Type": "application/json", "X-Relay-Intake-Key": key}
                if length is not None: headers["Content-Length"] = str(length)
                return urllib.request.urlopen(urllib.request.Request(url, data=json.dumps(fixture()).encode(), headers=headers), timeout=3)
            with self.assertRaises(urllib.error.HTTPError) as error:
                post("wrong")
            self.assertEqual(error.exception.code, 401)
            with self.assertRaises(urllib.error.HTTPError) as error:
                post(length=MAX_REQUEST + 1)
            self.assertEqual(error.exception.code, 413)
            with post() as response:
                self.assertTrue(json.load(response)["stored"])
            with post() as response:
                self.assertTrue(json.load(response)["duplicate"])
            self.assertEqual(len(self.github.issues), 1)
            server.report_slot.acquire()
            try:
                with self.assertRaises(urllib.error.HTTPError) as error:
                    post()
                self.assertEqual(error.exception.code, 429)
            finally:
                server.report_slot.release()
            with post() as response:
                self.assertTrue(json.load(response)["stored"])
        finally:
            server.shutdown(); server.server_close(); thread.join()


if __name__ == "__main__":
    unittest.main()
