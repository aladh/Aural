import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import mcp_guard


HEAD = "a" * 40
META = {
    "owner": "aladh",
    "name": "Spotty",
    "repo": "aladh/Spotty",
    "pr": 268,
    "base": "b" * 40,
    "head": HEAD,
    "run": 17,
    "attempt": 2,
    "policy_sha": "d" * 40,
    "diff_lines": {"file.py": [2, 4, 8]},
}


def call(tool, arguments, request_id=1):
    return {"jsonrpc": "2.0", "id": request_id, "method": "tools/call",
            "params": {"name": tool, "arguments": arguments}}


def result(value=None):
    return {"jsonrpc": "2.0", "id": 1, "result": {} if value is None else value}


class MCPGuardPolicyTests(unittest.TestCase):
    def setUp(self):
        self.policy = mcp_guard.AuthorizationPolicy(META)
        self.common = {"owner": "aladh", "repo": "Spotty", "pullNumber": 268}

    def test_reads_are_pinned_to_repository_pull_request_and_head(self):
        self.policy.validate_call(call("pull_request_read", {**self.common, "method": "get"}))
        self.policy.validate_call(call("get_file_contents", {"owner": "aladh", "repo": "Spotty",
                                                               "path": "Sources/Spotty.swift", "sha": HEAD}))
        for bad in (
            call("unknown", self.common),
            call("pull_request_read", {**self.common, "pullNumber": 269}),
            call("get_file_contents", {"owner": "other", "repo": "Spotty", "path": "file.py", "sha": HEAD}),
            call("get_file_contents", {"owner": "aladh", "repo": "Spotty", "path": "file.py", "sha": "c" * 40}),
            call("get_file_contents", {"owner": "aladh", "repo": "Spotty", "path": "../file.py", "sha": HEAD}),
        ):
            with self.subTest(tool=bad["params"]["name"]):
                with self.assertRaises(ValueError):
                    self.policy.validate_call(bad)

    def test_direct_review_is_comment_only_pinned_and_single_use(self):
        create = {**self.common, "method": "create", "commitID": HEAD,
                  "event": "COMMENT", "body": "overview"}
        self.policy.validate_call(call("pull_request_review_write", create))
        self.assertTrue(self.policy.complete_call(result()))
        self.assertTrue(self.policy.direct_created)
        for mutation in (
            {**self.common, "method": "create", "commitID": HEAD, "event": "APPROVE", "body": "bad"},
            {**self.common, "method": "delete", "commitID": HEAD},
            {**create},
        ):
            with self.subTest(method=mutation["method"], event=mutation.get("event")):
                with self.assertRaises(ValueError):
                    self.policy.validate_call(call("pull_request_review_write", mutation))

    def test_pending_review_requires_successful_create_inline_anchor_and_comment_submit(self):
        create = {**self.common, "method": "create", "commitID": HEAD}
        self.policy.validate_call(call("pull_request_review_write", create))
        self.assertFalse(self.policy.complete_call({"jsonrpc": "2.0", "id": 1,
                                                     "error": {"code": 500, "message": "failed"}}))
        self.assertFalse(self.policy.pending_created)
        with self.assertRaises(ValueError):
            self.policy.validate_call(call("pull_request_review_write", {
                **self.common, "method": "submit_pending", "event": "COMMENT", "body": "overview"}))

        # A failed create consumes the one-create budget and cannot be retried.
        with self.assertRaises(ValueError):
            self.policy.validate_call(call("pull_request_review_write", create))

        policy = mcp_guard.AuthorizationPolicy(META)
        policy.validate_call(call("pull_request_review_write", create))
        self.assertTrue(policy.complete_call({"jsonrpc": "2.0", "id": 1,
                                               "result": {"reviewID": "r1"}}))
        with self.assertRaises(ValueError):
            policy.validate_call(call("pull_request_review_write", {
                **self.common, "method": "submit_pending", "event": "COMMENT", "body": "overview"}))
        inline = {**self.common, "path": "file.py", "line": 4, "side": "RIGHT",
                  "subjectType": "LINE", "body": "finding"}
        policy.validate_call(call("add_comment_to_pending_review", inline))
        self.assertTrue(policy.complete_call(result()))
        policy.validate_call(call("pull_request_review_write", {
            **self.common, "method": "submit_pending", "event": "COMMENT",
            "reviewID": "r1", "body": "overview"}))
        self.assertTrue(policy.complete_call(result()))
        with self.assertRaises(ValueError):
            policy.validate_call(call("add_comment_to_pending_review", inline))

    def test_inline_locations_and_budgets_are_bounded(self):
        create = {**self.common, "method": "create", "commitID": HEAD}
        self.policy.validate_call(call("pull_request_review_write", create))
        self.policy.complete_call(result())
        for bad in (
            {**self.common, "path": "file.py", "line": 3, "side": "RIGHT", "subjectType": "LINE", "body": "x"},
            {**self.common, "path": "file.py", "line": 4, "side": "LEFT", "subjectType": "LINE", "body": "x"},
            {**self.common, "path": "file.py", "line": 4, "side": "RIGHT", "subjectType": "FILE", "body": "x"},
            {**self.common, "path": "file.py", "line": 4, "side": "RIGHT", "subjectType": "LINE", "body": "x" * 20_001},
            {**self.common, "path": "file.py", "line": 4, "side": "RIGHT", "subjectType": "LINE", "startLine": 2, "startSide": "LEFT", "body": "x"},
        ):
            with self.subTest(value=bad):
                with self.assertRaises(ValueError):
                    self.policy.validate_call(call("add_comment_to_pending_review", bad))
        for index in range(mcp_guard.MAX_INLINE_COMMENTS):
            inline = {**self.common, "path": "file.py", "line": 4, "side": "RIGHT",
                      "subjectType": "LINE", "body": str(index)}
            self.policy.validate_call(call("add_comment_to_pending_review", inline))
            self.policy.complete_call(result())
        with self.assertRaises(ValueError):
            self.policy.validate_call(call("add_comment_to_pending_review", inline))

    def test_write_is_blocked_before_forwarding_while_in_flight(self):
        create = {**self.common, "method": "create", "commitID": HEAD}
        self.policy.validate_call(call("pull_request_review_write", create))
        with self.assertRaises(ValueError):
            self.policy.validate_call(call("pull_request_review_write", create))
        self.policy.abort_call()


class MCPGuardProtocolTests(unittest.TestCase):
    def test_proxy_forwards_only_handshake_and_allowed_calls(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata = root / "meta.json"
            token = root / "token"
            trace = root / "trace.json"
            server = root / "server.py"
            metadata.write_text(json.dumps(META), encoding="utf-8")
            token.write_text("secret-token", encoding="utf-8")
            server.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "seen=[]\n"
                "def save():\n"
                " open(os.environ['TRACE'], 'w').write(json.dumps({'args':sys.argv[1:], 'token':os.environ.get('GITHUB_PERSONAL_ACCESS_TOKEN'), 'gh':os.environ.get('GH_TOKEN'), 'github':os.environ.get('GITHUB_TOKEN'), 'seen':seen}))\n"
                "for line in sys.stdin:\n"
                " request=json.loads(line); seen.append(request.get('method'))\n"
                " save()\n"
                " if 'id' not in request: continue\n"
                " result={'tools':[{'name':'pull_request_read'},{'name':'not_allowed'}]} if request.get('method')=='tools/list' else {}\n"
                " print(json.dumps({'jsonrpc':'2.0','id':request.get('id'),'result':result}), flush=True)\n"
                "save()\n",
                encoding="utf-8",
            )
            server.chmod(server.stat().st_mode | stat.S_IXUSR)
            requests = [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
                call("get_file_contents", {"owner": "aladh", "repo": "Spotty", "path": "file.py", "sha": HEAD}, 3),
                call("get_file_contents", {"owner": "aladh", "repo": "Spotty", "path": "file.py", "sha": "c" * 40}, 4),
                call("not_allowed", {}, 5),
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
            ]
            env = {**os.environ, "TRACE": str(trace), "GH_TOKEN": "outer-secret", "GITHUB_TOKEN": "outer-github"}
            process = subprocess.run(
                [sys.executable, "-B", str(Path(__file__).with_name("mcp_guard.py")),
                 str(metadata), str(token), str(server)],
                input="".join(json.dumps(item) + "\n" for item in requests),
                text=True, capture_output=True, env=env, timeout=5,
            )
            self.assertEqual(process.returncode, 0, process.stderr)
            output = [json.loads(line) for line in process.stdout.splitlines() if line.strip()]
            self.assertEqual([item["id"] for item in output], [1, 2, 3, 4, 5])
            self.assertEqual(output[0]["result"], {})
            self.assertEqual([tool["name"] for tool in output[1]["result"]["tools"]],
                             ["pull_request_read"])
            self.assertEqual(output[2]["result"], {})
            for item in output[3:]:
                self.assertEqual(item["error"]["code"], -32602)
                self.assertEqual(item["error"]["message"], "Invalid request")
            observed = json.loads(trace.read_text(encoding="utf-8"))
            self.assertEqual(observed["args"], ["stdio", "--tools=" + ",".join(sorted(mcp_guard.ALLOWED_TOOLS))])
            self.assertEqual(observed["token"], "secret-token")
            self.assertIsNone(observed["gh"])
            self.assertIsNone(observed["github"])
            self.assertEqual(observed["seen"], ["initialize", "tools/list", "tools/call", "notifications/initialized"])
            self.assertNotIn("secret-token", process.stdout + process.stderr)
            self.assertNotIn("outer-secret", process.stdout + process.stderr)


if __name__ == "__main__":
    unittest.main()
