import base64
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import review


REPO = "acme/spotty"
PATH = "Sources/Changed.swift"
BASE = "b" * 40
HEAD = "a" * 40
OLD_HEAD = "d" * 40
OLD_ID = "F0123456789ab"
NEW_ID = "Fabcdef012345"


def validation_meta(previous=()):
    return {
        "previous": list(previous),
        "changed": [PATH],
        "files": {PATH: 4},
    }


def finding(identity="", title="A concrete bug"):
    return {
        "id": identity,
        "path": PATH,
        "line": 2,
        "severity": "P2",
        "title": title,
        "body": "The changed code has a concrete consequence.",
    }


def result(findings=(), resolved=(), summary="Review complete"):
    return {"summary": summary, "findings": list(findings), "resolved": list(resolved)}


def render_meta():
    return {
        "schema": 1,
        "repo": REPO,
        "pr": 7,
        "base": BASE,
        "head": HEAD,
        "run": 11,
        "attempt": 2,
        "policy": "policy-digest",
        "mode": "full",
        "model": "model",
        "variant": "xhigh",
        "omitted": [],
        "omitted_before": [],
        **validation_meta(),
    }


def encoded_state_body(state):
    encoded = base64.b64encode(json.dumps(state, separators=(",", ":")).encode()).decode()
    return review.MARKER + "\n<!-- state:" + encoded + " -->"


class ReviewTests(unittest.TestCase):
    def test_compatible_requires_matching_identity_and_ancestry(self):
        meta = {"repo": REPO, "pr": 7, "base": BASE, "head": HEAD, "policy": "p"}
        state = {"repo": REPO, "pr": 7, "base": BASE, "policy": "p", "head": OLD_HEAD}
        ancestor_calls = []

        def ancestor(base, head):
            ancestor_calls.append((base, head))
            return True

        self.assertTrue(review.compatible(state, meta, ancestor))
        self.assertEqual(ancestor_calls, [(OLD_HEAD, HEAD)])

        for key, value in (("repo", "other/repo"), ("pr", 8), ("base", "c" * 40), ("policy", "other")):
            candidate = dict(state)
            candidate[key] = value
            self.assertFalse(review.compatible(candidate, meta, ancestor), key)

        ancestor_calls.clear()
        self.assertFalse(review.compatible(state, meta, lambda *_: False))
        invalid_head = dict(state, head="not-a-sha")
        self.assertFalse(review.compatible(invalid_head, meta, ancestor))
        self.assertEqual(ancestor_calls, [])

    def test_check_current_rejects_closed_or_moved_pull_request(self):
        meta = {"repo": REPO, "pr": 7, "base": BASE, "head": HEAD}
        current = {"state": "open", "head": {"sha": HEAD}, "base": {"sha": BASE}}
        with patch.object(review, "api", return_value=current) as api:
            review.check_current(meta, "token")
        api.assert_called_once_with("repos/acme/spotty/pulls/7", "token")

        stale = [
            dict(current, state="closed"),
            dict(current, head={"sha": "c" * 40}),
            dict(current, base={"sha": "c" * 40}),
        ]
        for response in stale:
            with self.subTest(response=response), patch.object(review, "api", return_value=response):
                with self.assertRaises(ValueError):
                    review.check_current(meta, "token")

    def baseline_comment(self, **overrides):
        metadata = render_meta()
        metadata.update(head=OLD_HEAD, **overrides)
        body = review.render({"meta": metadata, "result": result([finding(OLD_ID)])})
        return {"user": {"login": review.BOT}, "body": body}

    def test_find_baseline_requires_successful_run_provenance(self):
        meta = {"repo": REPO, "pr": 7, "base": BASE, "head": HEAD, "policy": "policy-digest"}
        item = self.baseline_comment()
        proof = {
            "conclusion": "success",
            "event": "pull_request",
            "head_sha": OLD_HEAD,
            "path": review.WORKFLOW,
            "head_repository": {"full_name": REPO},
        }
        with patch.object(review, "is_ancestor", return_value=True), patch.object(
            review, "api", return_value=proof
        ) as api:
            state = review.find_baseline([item], meta, "token")
        self.assertEqual(state["head"], OLD_HEAD)
        api.assert_called_once_with("repos/acme/spotty/actions/runs/11/attempts/2", "token")

        invalid_proofs = (
            ("conclusion", "failure"),
            ("event", "push"),
            ("head_sha", HEAD),
            ("path", ".github/workflows/other.yml"),
            ("head_repository", {"full_name": "other/repo"}),
        )
        for key, value in invalid_proofs:
            candidate = dict(proof, **{key: value})
            with self.subTest(key=key), patch.object(review, "is_ancestor", return_value=True), patch.object(
                review, "api", return_value=candidate
            ):
                self.assertIsNone(review.find_baseline([item], meta, "token"))

    def test_find_baseline_rejects_null_or_malformed_prior_findings(self):
        meta = {"repo": REPO, "pr": 7, "base": BASE, "head": HEAD, "policy": "policy-digest"}
        malformed = (
            None,
            {"schema": 1, "findings": [None]},
            {"schema": 1, "findings": [{"id": OLD_ID}]},
        )
        for state in malformed:
            item = {"user": {"login": review.BOT}, "body": encoded_state_body(state)}
            with self.subTest(state=state), patch.object(review, "api") as api:
                self.assertIsNone(review.find_baseline([item], meta, "token"))
                api.assert_not_called()

    def test_find_baseline_falls_back_after_proof_lookup_error(self):
        meta = {"repo": REPO, "pr": 7, "base": BASE, "head": HEAD, "policy": "policy-digest"}
        latest = self.baseline_comment(run=12, attempt=1)
        older = self.baseline_comment(run=10, attempt=1)
        older_proof = {
            "conclusion": "success",
            "event": "pull_request",
            "head_sha": OLD_HEAD,
            "path": review.WORKFLOW,
            "head_repository": {"full_name": REPO},
        }
        with patch.object(review, "is_ancestor", return_value=True), patch.object(
            review, "api", side_effect=[RuntimeError("proof unavailable"), older_proof]
        ) as api:
            state = review.find_baseline([older, latest], meta, "token")
        self.assertEqual(state["run"], 10)
        self.assertEqual(api.call_count, 2)

    def test_validate_rejects_finding_outside_source_or_with_invalid_location_or_severity(self):
        meta = validation_meta()
        invalid_findings = (
            dict(finding(), path="Sources/Unchanged.swift"),
            dict(finding(), line=0),
            dict(finding(), line=5),
            dict(finding(), severity="P0"),
        )
        for invalid in invalid_findings:
            with self.subTest(finding=invalid):
                with self.assertRaises(ValueError):
                    review.validate_result(result([invalid]), meta)

    def test_snapshot_reads_raw_blobs_and_omits_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Review tests"], cwd=repo, check=True)
            (repo / ".gitattributes").write_text("hidden.txt export-ignore\n")
            (repo / "hidden.txt").write_text("source remains visible\n")
            (repo / "visible.txt").write_text("plain source\n")
            (repo / "link.txt").symlink_to("visible.txt")
            subprocess.run(["git", "add", "-A"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "snapshot fixture"], cwd=repo, check=True)
            revision = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True
            ).stdout.strip()
            destination = repo / "out"
            previous_cwd = Path.cwd()
            os.chdir(repo)
            try:
                files, omitted = review.snapshot(revision, destination)
            finally:
                os.chdir(previous_cwd)

            self.assertEqual(set(files), {".gitattributes", "hidden.txt", "visible.txt"})
            self.assertEqual(omitted, ["link.txt"])
            self.assertEqual((destination / "hidden.txt").read_text(), "source remains visible\n")
            self.assertFalse((destination / "link.txt").exists())

    def test_validate_generates_canonical_id_and_accepts_revalidation(self):
        meta = validation_meta()
        raw = result([finding(title="<unsafe> title")])
        validated = review.validate_result(raw, meta)
        expected = "F" + hashlib.sha256(
            (PATH + "\0<unsafe> title".casefold()).encode()
        ).hexdigest()[:12]
        self.assertEqual(validated["findings"][0]["id"], expected)
        self.assertEqual(review.validate_result(validated, meta), validated)

    def test_validate_preserves_previous_findings_or_requires_resolution(self):
        previous = finding(OLD_ID, "Old finding")
        meta = validation_meta([previous])
        active = finding(OLD_ID, "Updated wording")
        resolved = {"id": OLD_ID, "reason": "The changed code removed the condition."}

        for current in (result([active]), result(resolved=[resolved])):
            with self.subTest(current=current):
                self.assertEqual(
                    {item["id"] for item in review.validate_result(current, meta)["findings"]}
                    | {item["id"] for item in current["resolved"]},
                    {OLD_ID},
                )

        with self.assertRaises(ValueError):
            review.validate_result(result(), meta)
        with self.assertRaises(ValueError):
            review.validate_result(result([active, active]), meta)
        with self.assertRaises(ValueError):
            review.validate_result(result([active], [resolved]), meta)

    def test_parse_events_requires_valid_complete_error_free_stream(self):
        payload = json.dumps({"summary": "ok", "findings": [], "resolved": []})
        raw = "\n".join(
            [
                json.dumps({"type": "text", "part": {"text": payload}}),
                json.dumps({"type": "step_finish", "part": {"reason": "stop"}}),
            ]
        )
        parsed, events = review.parse_events(raw)
        self.assertEqual(parsed["summary"], "ok")
        self.assertEqual(len(events), 2)

        invalid_streams = (
            "{not-json}\n",
            json.dumps({"type": "text", "part": {"text": payload}}),
            "\n".join(
                [
                    json.dumps({"type": "text", "part": {"text": payload}}),
                    json.dumps({"type": "step_finish", "part": {"reason": "length"}}),
                ]
            ),
            "\n".join(
                [
                    json.dumps({"type": "error", "message": "provider failed"}),
                    json.dumps({"type": "step_finish", "part": {"reason": "stop"}}),
                ]
            ),
        )
        for stream in invalid_streams:
            with self.subTest(stream=stream):
                with self.assertRaises(ValueError):
                    review.parse_events(stream)

    def test_render_escapes_comment_content_roundtrips_state_and_owns_only_bot_comments(self):
        report = {
            "meta": render_meta(),
            "result": result(
                [finding(NEW_ID, "<script>@everyone</script>")],
                [{"id": OLD_ID, "reason": "<img src=x onerror=alert(1)> @here"}],
                summary="<script>alert(1)</script> & @here",
            ),
        }
        body = review.render(report)
        self.assertNotIn("@", body)
        self.assertNotIn("<script>", body)
        self.assertIn("&lt;script&gt;", body)
        self.assertIn("&#64;here", body)

        state = review.decode_state(body)
        self.assertEqual(state["head"], HEAD)
        self.assertEqual([item["id"] for item in state["findings"]], [NEW_ID])
        owned = {"user": {"login": review.BOT}, "body": body}
        comments = [
            owned,
            {"user": {"login": "alice"}, "body": body},
            {"user": {"login": review.BOT}, "body": review.MARKER},
            {"user": {"login": review.BOT}, "body": "quoted\n" + body},
        ]
        self.assertEqual(review.owned_comments(comments), [owned])

    def test_run_model_passes_scrubbed_environment_to_subprocess(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            (work / "input").mkdir()
            (work / "output").mkdir()
            meta = render_meta()
            (work / "meta.json").write_text(json.dumps(meta))
            binary = work / "opencode"
            binary.write_text("placeholder")

            def fake_run(command, **kwargs):
                kwargs["stdout"].write(
                    json.dumps({"type": "text", "part": {"text": json.dumps(result())}}) + "\n"
                )
                kwargs["stdout"].write(
                    json.dumps({"type": "step_finish", "part": {"reason": "stop"}}) + "\n"
                )
                return subprocess.CompletedProcess(command, 0)

            with patch.dict(
                os.environ,
                {"PATH": "/safe/bin", "GH_TOKEN": "secret", "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "secret"},
            ), patch.object(review.subprocess, "run", side_effect=fake_run) as run:
                review.run_model(work, binary)

            environment = run.call_args.kwargs["env"]
            self.assertEqual(environment["PATH"], "/safe/bin")
            self.assertNotIn("GH_TOKEN", environment)
            self.assertNotIn("ACTIONS_ID_TOKEN_REQUEST_TOKEN", environment)
            config = json.loads(environment["OPENCODE_CONFIG_CONTENT"])
            self.assertEqual(config["share"], "disabled")
            self.assertEqual(config["permission"]["*"], "deny")
            report = json.loads((work / "output/report.json").read_text())
            self.assertEqual(report["result"]["findings"], [])

    def test_publish_rechecks_revision_before_comment_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            event_path = work / "event.json"
            summary_path = work / "summary.md"
            event_path.write_text(
                json.dumps({
                    "pull_request": {
                        "number": 7,
                        "head": {"sha": HEAD},
                        "base": {"sha": BASE},
                    }
                })
            )
            report = {"meta": dict(render_meta(), policy=review.policy_digest()), "result": result()}
            (work / "report.json").write_text(json.dumps(report))
            api_calls = []

            def fake_api(path, token, method="GET", data=None):
                api_calls.append((path, method, data))
                if path.startswith("repos/acme/spotty/pulls/"):
                    return {"state": "open", "head": {"sha": "c" * 40}, "base": {"sha": BASE}}
                return {}

            environment = {
                "GITHUB_EVENT_PATH": str(event_path),
                "GITHUB_REPOSITORY": REPO,
                "GITHUB_RUN_ID": "11",
                "GITHUB_RUN_ATTEMPT": "2",
                "GH_TOKEN": "scoped-token",
                "GITHUB_STEP_SUMMARY": str(summary_path),
            }
            with patch.dict(os.environ, environment), patch.object(review, "request") as request, patch.object(
                review, "api", side_effect=fake_api
            ):
                with self.assertRaises(ValueError):
                    review.publish(work)

            request.assert_not_called()
            self.assertEqual([path for path, _, _ in api_calls], ["repos/acme/spotty/pulls/7"])
            self.assertFalse(any("/comments" in path for path, _, _ in api_calls))
            self.assertFalse(summary_path.exists())

    def test_publish_upserts_owned_comment_and_rechecks_revision(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            event_path = work / "event.json"
            summary_path = work / "summary.md"
            event_path.write_text(
                json.dumps({
                    "pull_request": {
                        "number": 7,
                        "head": {"sha": HEAD},
                        "base": {"sha": BASE},
                    }
                })
            )
            report = {"meta": dict(render_meta(), policy=review.policy_digest()), "result": result()}
            (work / "report.json").write_text(json.dumps(report))
            existing = dict(self.baseline_comment(), id=123)
            current = {"state": "open", "head": {"sha": HEAD}, "base": {"sha": BASE}}
            calls = []
            expected_body = review.render(report)

            def fake_api(path, token, method="GET", data=None):
                calls.append((path, method, data))
                if path == "repos/acme/spotty/pulls/7":
                    return current
                if path == "repos/acme/spotty/issues/7/comments?per_page=100&page=1":
                    return [existing]
                if path == "repos/acme/spotty/issues/comments/123":
                    self.assertEqual(method, "PATCH")
                    self.assertEqual(data, {"body": expected_body})
                    return {"html_url": "https://github.example/comment/123"}
                raise AssertionError(f"unexpected API path: {path}")

            environment = {
                "GITHUB_EVENT_PATH": str(event_path),
                "GITHUB_REPOSITORY": REPO,
                "GITHUB_RUN_ID": "11",
                "GITHUB_RUN_ATTEMPT": "2",
                "GH_TOKEN": "scoped-token",
                "GITHUB_STEP_SUMMARY": str(summary_path),
            }
            with patch.dict(os.environ, environment), patch.object(review, "api", side_effect=fake_api):
                review.publish(work)

            self.assertEqual(
                [path for path, _, _ in calls],
                [
                    "repos/acme/spotty/pulls/7",
                    "repos/acme/spotty/issues/7/comments?per_page=100&page=1",
                    "repos/acme/spotty/issues/comments/123",
                    "repos/acme/spotty/pulls/7",
                ],
            )
            self.assertEqual(summary_path.read_text(), "[Advisory review](https://github.example/comment/123) for `" + HEAD + "`; no approval issued.\n")


if __name__ == "__main__":
    unittest.main()
