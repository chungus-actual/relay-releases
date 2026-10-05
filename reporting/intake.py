"""Private Relay intake. Run behind an HTTPS reverse proxy; see docs/bug-reports.md.

No third-party packages. Credentials live on the host, never in app bundles.
Each report becomes one immutable ZIP on the private repository's reports branch.
GitHub's atomic create-file operation also deduplicates concurrent/retried sends.
"""
import base64
import hashlib
import hmac
import io
import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_REQUEST = 9 * 1024 * 1024
MAX_IMAGE = 6 * 1024 * 1024
PNG = b"\x89PNG\r\n\x1a\n"


class Rejected(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def bundle(raw):
    """Validate a bounded schema and build deterministic bytes for safe retries."""
    try:
        report = json.loads(raw)
        if not isinstance(report, dict) or set(report) - {"schema", "id", "created", "description", "diagnostics", "events", "screenshot"}:
            raise ValueError()
        if type(report.get("schema")) is not int or report["schema"] != 1 or not re.fullmatch(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", report.get("id", "")):
            raise ValueError()
        for key, limit in [("created", 64), ("description", 8000), ("events", 65536)]:
            if not isinstance(report.get(key), str) or len(report[key]) > limit:
                raise ValueError()
        if not report["description"].strip():
            raise ValueError()
        diagnostics = report.get("diagnostics")
        if not isinstance(diagnostics, dict) or len(diagnostics) > 40:
            raise ValueError()
        if any(not isinstance(k, str) or len(k) > 64 or not isinstance(v, str) or len(v) > 4096 for k, v in diagnostics.items()):
            raise ValueError()
        screenshot = report.pop("screenshot", None)
        image = None
        if screenshot is not None:
            image = base64.b64decode(screenshot, validate=True)
            if not image.startswith(PNG) or len(image) > MAX_IMAGE:
                raise ValueError()
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            archive.writestr(zipfile.ZipInfo("report.json"), json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2).encode())
            if image is not None:
                archive.writestr(zipfile.ZipInfo("screenshot.png"), image)
        return report, data.getvalue()
    except (ValueError, TypeError, KeyError, RecursionError):
        raise Rejected(400, "Invalid report. Expected schema 1 and an optional PNG up to 6 MB.") from None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self, repo, token):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise ValueError("Invalid repository")
        self.repo, self.token = repo, token
        self.opener = urllib.request.build_opener(NoRedirect())

    def call(self, method, path="", body=None):
        request = urllib.request.Request("https://api.github.com/repos/" + self.repo + path,
            data=None if body is None else json.dumps(body).encode(), method=method,
            headers={"Authorization": "Bearer " + self.token, "Accept": "application/vnd.github+json",
                     "Content-Type": "application/json", "User-Agent": "Relay-private-intake",
                     "X-GitHub-Api-Version": "2022-11-28"})
        try:
            with self.opener.open(request, timeout=25) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            # Neither upstream bodies nor secrets are returned to submitters.
            return error.code, {}


class Intake:
    def __init__(self, github, branch="bug-reports"):
        if not re.fullmatch(r"[A-Za-z0-9_-]+", branch):
            raise ValueError("Use a simple reports branch name")
        self.github, self.branch = github, branch

    def submit(self, raw):
        report, archive = bundle(raw)
        status, repo = self.github.call("GET")
        if status != 200 or repo.get("private") is not True or repo.get("archived") is True:
            raise Rejected(503, "Private repository is unavailable; report was not accepted.")
        path = "/contents/reports/" + report["id"] + ".zip"
        # Git blob SHA verifies bytes on retry without downloading the attachment.
        digest = hashlib.sha1(b"blob " + str(len(archive)).encode() + b"\0" + archive).hexdigest()
        def existing():
            code, content = self.github.call("GET", path + "?ref=" + self.branch)
            if code == 200:
                if content.get("sha") != digest:
                    raise Rejected(409, "This report ID already contains different data. Save it and start a new report.")
                return True
            if code != 404:
                raise Rejected(503, "Could not check report receipt. Retry the same report.")
            return False
        if existing():
            return {"id": report["id"], "stored": True, "duplicate": True}
        status, _ = self.github.call("PUT", path, {"branch": self.branch,
            "message": "Bug report " + report["id"], "content": base64.b64encode(archive).decode()})
        if status != 201:
            if existing():
                return {"id": report["id"], "stored": True, "duplicate": True}
            raise Rejected(503, "Report storage could not be confirmed. Retry the same report.")
        # Only the request that created the ZIP may create an issue. A retry never
        # creates a second issue after an ambiguous network failure. The ZIP is
        # the durable receipt; issue creation is best effort and can be reconciled.
        link = f"https://github.com/{self.github.repo}/blob/{self.branch}/reports/{report['id']}.zip"
        issue_status = 0
        try:
            issue_status, _ = self.github.call("POST", "/issues", {
                "title": "Relay bug report " + report["id"],
                # Keep untrusted descriptions out of Markdown mentions/links.
                "body": f"Private report received. [Download report and optional screenshot]({link}).\n\nReport ID: `{report['id']}`\n\nThe ZIP contains the description, diagnostics, event log, and any submitted screenshot."})
        except (OSError, ValueError):
            pass
        return {"id": report["id"], "stored": True, "issueCreated": issue_status == 201}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args):
        pass  # No descriptions, images, intake codes, addresses, or tokens in logs.

    def respond(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def do_POST(self):
        self.connection.settimeout(30)
        try:
            if self.path != "/reports":
                raise Rejected(404, "Not found")
            supplied = self.headers.get("X-Relay-Intake-Key", "").encode()
            if not hmac.compare_digest(supplied, self.server.intake_key):
                raise Rejected(401, "Invalid intake code")
            if self.headers.get("Content-Type", "").split(";")[0].lower() != "application/json" or self.headers.get("Transfer-Encoding"):
                raise Rejected(400, "Expected JSON with Content-Length")
            try:
                size = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                size = 0
            if not 0 < size <= MAX_REQUEST:
                raise Rejected(413, "Report exceeds 9 MB")
            # Single process-wide write slot bounds resource use and GitHub writes.
            if not self.server.report_slot.acquire(blocking=False):
                raise Rejected(429, "Another report is being received. Retry shortly.")
            try:
                now = time.monotonic()
                self.server.accepted = [t for t in self.server.accepted if now - t < 60]
                if len(self.server.accepted) >= 10:
                    raise Rejected(429, "Intake limit reached. Retry in a minute.")
                self.server.accepted.append(now)
                raw = self.rfile.read(size)
                if len(raw) != size:
                    raise Rejected(400, "Incomplete report")
                result = self.server.intake.submit(raw)
            finally:
                self.server.report_slot.release()
            self.respond(200, result)
        except Rejected as error:
            self.respond(error.status, {"error": error.message})
        except (OSError, ValueError):
            self.respond(503, {"error": "Could not confirm receipt. Retry the same report."})


def main():
    key = os.environ["RELAY_INTAKE_KEY"]
    if len(key) < 24:
        raise ValueError("Use a random intake code of at least 24 characters")
    github = GitHub(os.environ.get("RELAY_REPORT_REPOSITORY", "chungus-actual/relay"), os.environ["GITHUB_TOKEN"])
    intake = Intake(github, os.environ.get("RELAY_REPORT_BRANCH", "bug-reports"))
    status, repo = github.call("GET")
    if status != 200 or repo.get("private") is not True:
        raise RuntimeError("Intake requires an accessible private GitHub repository")
    status, _ = github.call("GET", "/branches/" + intake.branch)
    if status != 200:
        raise RuntimeError("Create the private bug-reports branch before starting intake")
    server = ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("PORT", "8787"))), Handler)
    server.intake, server.intake_key = intake, key.encode()
    server.report_slot, server.accepted = threading.Lock(), []
    print("Relay private intake listening on loopback; HTTPS reverse proxy required.", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
