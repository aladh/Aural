import importlib.util
import json
from pathlib import Path
import tempfile
from unittest import TestCase, mock


SPEC = importlib.util.spec_from_file_location("mcp_trial", Path(__file__).with_name("mcp_trial.py"))
mcp_trial = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mcp_trial)


HEAD = "a" * 40
META = {"owner": "aladh", "name": "Spotty", "repo": "aladh/Spotty", "pr": 268,
        "base": "b" * 40, "head": HEAD, "run": 17, "attempt": 2,
        "title": "fixture", "body": "", "body_truncated": False}


def tool(name, value, output="ok"):
    return {"type": "tool_use", "part": {"tool": name,
            "state": {"status": "completed", "input": value, "output": output}}}


def direct_events(**changes):
    marker = f"<!-- spotty-opencode-mcp:v1 run={META['run']} attempt={META['attempt']} head={HEAD} -->"
    create = {"method": "create", "owner": META["owner"], "repo": META["name"],
              "pullNumber": META["pr"], "commitID": HEAD, "event": "COMMENT",
              "body": marker + "\nOpenCode GitHub MCP experiment (Actions, advisory)\n"
                     "Verdict: clean\nCorrectness: clean\nQuality: clean\nLimits: fixture\nHead: " + HEAD}
    tasks = [tool("subagent", {"agent": role}, '<subagent sessionID="ses_fixture" state="completed">{}</subagent>'.format(role))
             for role in mcp_trial.ROLES]
    events = [{"type": "step_start"}, *tasks, tool("github_pull_request_review_write", create),
              {"type": "text", "part": {"text": "published"}},
              {"type": "step_finish", "part": {"reason": "stop"}}]
    for event in events:
        if event.get("type") == "tool_use" and event["part"]["tool"] == "subagent":
            event["part"]["state"]["input"].update(changes.get("subagent", {}))
    return events


class MCPTrialTests(TestCase):
    def test_attach_diffs_keeps_distinct_inputs_and_deduplicates_equal(self):
        separate = mcp_trial.attach_diffs("audit", "FULL", "DELTA")
        self.assertEqual(separate.count("FULL"), 1)
        self.assertEqual(separate.count("DELTA"), 1)
        self.assertIn("UNTRUSTED", separate)
        same = mcp_trial.attach_diffs("audit", "FULL", "FULL")
        self.assertEqual(same.count("FULL"), 1)
        self.assertIn("byte-identical", same)

    def test_parse_events_rejects_non_object_json(self):
        with self.assertRaises(ValueError):
            mcp_trial.parse_events(b"[]\n")

    def test_validate_events_accepts_two_foreground_children_and_comment(self):
        mcp_trial.validate_events(direct_events(), META)

    def test_validate_events_rejects_background_child_or_stale_write(self):
        with self.assertRaises(ValueError):
            mcp_trial.validate_events(direct_events(subagent={"background": True}), META)
        events = direct_events()
        events[3]["part"]["state"]["input"]["commitID"] = "c" * 40
        with self.assertRaises(ValueError):
            mcp_trial.validate_events(events, META)

    def test_bounded_diff_refuses_oversized_output(self):
        with mock.patch.object(mcp_trial, "git", return_value=b"x" * (mcp_trial.MAX_DIFF + 1)):
            with self.assertRaises(ValueError):
                mcp_trial.bounded_diff(Path("/tmp/repo"), META["base"], META["head"])

    def test_config_exposes_only_parent_mcp_and_child_deny(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.dict(mcp_trial.os.environ, {"MODEL": "opencode/muse", "VARIANT": "xhigh"}):
                path = mcp_trial.config(META, Path("/tmp/github-mcp"), "FULL", "FULL", Path(directory))
            data = json.loads(path.read_text())
            self.assertEqual(data["mcp"]["servers"]["github"]["environment"]["GITHUB_PERSONAL_ACCESS_TOKEN"],
                             "{env:SPOTTY_MCP_TOKEN}")
            self.assertEqual(data["mcp"]["servers"]["github"]["command"][-1],
                             "--tools=add_comment_to_pending_review,get_file_contents,pull_request_read,pull_request_review_write")
            self.assertIn({"action": "github_pull_request_review_write", "resource": "*", "effect": "allow"}, data["agents"]["thermos-parent"]["permissions"])
            for role in mcp_trial.ROLES:
                self.assertNotIn({"action": "github_pull_request_review_write", "resource": "*", "effect": "allow"}, data["agents"][role]["permissions"])


    def test_export_completion_and_child_permissions_are_required(self):
        events = direct_events()
        for event in events: event["sessionID"] = "ses_root"
        exports = {}
        for session, role in [("ses_root", "thermos-parent"), ("ses_correct", mcp_trial.ROLES[0]), ("ses_quality", mcp_trial.ROLES[1])]:
            exports[session] = {"info": {"id": session, "agent": role, "parentID": "ses_root",
                "model": {"providerID": "opencode", "id": "muse", "variant": "xhigh"},
                "outcome": "succeeded", "time": {"created": 1, "idle": 3}}, "messages": []}
        for event, session in zip(events[1:3], ("ses_correct", "ses_quality")):
            event["part"]["state"]["output"] = f'<subagent sessionID="{session}" state="completed">done</subagent>'
        mcp_trial.validate_sessions(events, exports, "opencode/muse", "xhigh")
        exports["ses_quality"]["messages"] = [{"content": [{"type": "tool", "name": "shell"}]}]
        with self.assertRaises(ValueError):
            mcp_trial.validate_sessions(events, exports, "opencode/muse", "xhigh")
        exports["ses_quality"]["messages"] = []
        exports["ses_root"]["info"]["outcome"] = "failed"
        with self.assertRaises(ValueError):
            mcp_trial.validate_sessions(events, exports, "opencode/muse", "xhigh")

    def test_file_reads_require_exact_head(self):
        events = direct_events()
        events.insert(1, tool("github_get_file_contents", {"owner": META["owner"], "repo": META["name"], "ref": "main"}))
        with self.assertRaises(ValueError): mcp_trial.validate_events(events, META)
        events[1]["part"]["state"]["input"]["sha"] = HEAD
        mcp_trial.validate_events(events, META)
