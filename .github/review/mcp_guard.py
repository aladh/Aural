#!/usr/bin/env python3
"""Small, deny-by-default JSON-RPC proxy for the review MCP server."""

from __future__ import annotations

import json
import os
import select
import subprocess
import sys
import time
from pathlib import Path

from contract import safe_path


ALLOWED_TOOLS = frozenset(
    {
        "pull_request_read",
        "get_file_contents",
        "pull_request_review_write",
        "add_comment_to_pending_review",
    }
)
FORWARDED_METHODS = frozenset(
    {"initialize", "tools/list", "ping", "notifications/initialized"}
)
MAX_REQUEST_BYTES = 2_000_000
MAX_RESPONSE_BYTES = 10_000_000
MAX_REVIEW_BODY = 20_000
MAX_INLINE_COMMENTS = 20
SERVER_TIMEOUT = 60
TOKEN_ENV = "GITHUB_PERSONAL_ACCESS_TOKEN"


def _require(condition: bool, message: str = "invalid request") -> None:
    if not condition:
        raise ValueError(message)


def _positive_int(value: object) -> bool:
    return type(value) is int and value > 0


def _successful_response(response: object) -> bool:
    if not isinstance(response, dict) or "error" in response or "result" not in response:
        return False
    result = response["result"]
    return not (isinstance(result, dict) and result.get("isError") is True)


class AuthorizationPolicy:
    """Stateful pre-call policy; it never performs network or subprocess work."""

    def __init__(self, meta: dict):
        _require(isinstance(meta, dict), "metadata must be an object")
        self.meta = dict(meta)
        self.owner = meta.get("owner")
        _require(isinstance(self.owner, str) and self.owner, "invalid owner")

        name, repo = meta.get("name"), meta.get("repo")
        _require(isinstance(name, str) and name and "/" not in name, "invalid repository")
        _require(repo == f"{self.owner}/{name}", "repository metadata mismatch")
        self.repo = name

        self.pr = meta.get("pr")
        _require(_positive_int(self.pr), "invalid pull request number")
        self.head = meta.get("head")
        _require(isinstance(self.head, str) and len(self.head) == 40
                 and all(char in "0123456789abcdef" for char in self.head), "invalid head")

        for key in ("base", "policy_sha"):
            value = meta.get(key)
            _require(isinstance(value, str) and len(value) == 40
                     and all(char in "0123456789abcdef" for char in value),
                     f"invalid {key}")
        for key in ("run", "attempt"):
            value = meta.get(key)
            _require(_positive_int(value), f"invalid {key}")

        raw_lines = meta.get("diff_lines")
        _require(isinstance(raw_lines, dict), "invalid diff anchors")
        anchors = {}
        for path, lines in raw_lines.items():
            _require(safe_path(path), "invalid diff path")
            if isinstance(lines, dict):
                lines = lines.get("right", lines.get("lines"))
            _require(isinstance(lines, (list, tuple)), "invalid diff anchors")
            values = frozenset(line for line in lines if _positive_int(line))
            _require(len(values) == len(lines), "invalid diff anchor")
            anchors[path] = values
        self.anchors = anchors

        self.create_seen = False
        self.pending_created = False
        self.direct_created = False
        self.inline_count = 0
        self.successful_inline_count = 0
        self.submit_seen = False
        self.submitted = False
        self.review_id = None
        self._inflight = None

    def _meta(self, arguments: dict, pull_number: bool = False) -> None:
        _require(isinstance(arguments, dict), "arguments must be an object")
        _require(arguments.get("owner") == self.owner and arguments.get("repo") == self.repo,
                 "repository is outside the review")
        if pull_number:
            _require(arguments.get("pullNumber") == self.pr, "pull request is outside the review")
        elif "pullNumber" in arguments:
            _require(arguments.get("pullNumber") == self.pr, "pull request is outside the review")

    def _review_body(self, arguments: dict, required: bool = False) -> None:
        if "body" not in arguments:
            _require(not required, "review body is required")
            return
        body = arguments["body"]
        _require(isinstance(body, str) and len(body) <= MAX_REVIEW_BODY,
                 "review body is too large")

    def _validate_tool(self, tool: str, arguments: dict) -> str:
        _require(tool in ALLOWED_TOOLS, "tool is not allowed")
        _require(isinstance(arguments, dict), "arguments must be an object")
        if tool == "get_file_contents":
            self._meta(arguments)
            _require(arguments.get("sha") == self.head
                     and ("ref" not in arguments or arguments.get("ref") == self.head),
                     "file read is not pinned to head")
            _require(safe_path(arguments.get("path")), "file path is not safe")
        elif tool == "pull_request_read":
            self._meta(arguments, pull_number=True)
        elif tool == "pull_request_review_write":
            self._validate_review_write(arguments)
        else:
            self._validate_inline(arguments)
        return tool

    def _validate_review_write(self, arguments: dict) -> None:
        self._meta(arguments, pull_number=True)
        method = arguments.get("method")
        _require(method in {"create", "submit_pending"}, "review mutation is not allowed")
        _require(not self._inflight, "review write already in flight")
        if method == "create":
            _require(not self.create_seen, "only one review create is allowed")
            _require(arguments.get("commitID") == self.head, "review is not pinned to head")
            event = arguments.get("event")
            _require(event is None or event == "COMMENT", "only COMMENT reviews are allowed")
            self._review_body(arguments, required=event == "COMMENT")
            self.create_seen = True
            self._inflight = "pending_create" if event is None else "direct_create"
            return

        _require(not self.submit_seen and not self._inflight and self.pending_created
                 and self.successful_inline_count > 0,
                 "pending review is not ready to submit")
        _require(arguments.get("event") == "COMMENT", "only COMMENT reviews are allowed")
        self._review_body(arguments, required=True)
        requested_id = arguments.get("reviewID", arguments.get("reviewId"))
        _require(requested_id is None or self.review_id is None
                 or str(requested_id) == str(self.review_id), "pending review is outside this session")
        self.submit_seen = True
        self._inflight = "submit_pending"

    def _validate_inline(self, arguments: dict) -> None:
        self._meta(arguments, pull_number=True)
        _require(self.pending_created and not self.submitted and not self._inflight,
                 "inline comments require an open pending review")
        _require(self.inline_count < MAX_INLINE_COMMENTS, "inline comment limit exceeded")
        path, line = arguments.get("path"), arguments.get("line")
        _require(arguments.get("subjectType") == "LINE" and arguments.get("side") == "RIGHT",
                 "only right-side line comments are allowed")
        _require(safe_path(path) and _positive_int(line) and line in self.anchors.get(path, ()),
                 "inline location is outside the trusted diff")
        self._review_body(arguments, required=True)
        if "startLine" in arguments or "startSide" in arguments:
            start = arguments.get("startLine")
            _require(arguments.get("startSide") == "RIGHT" and _positive_int(start)
                     and start <= line and start in self.anchors.get(path, ()),
                     "inline range is outside the trusted diff")
        self.inline_count += 1
        self._inflight = "inline"

    def validate_call(self, request_or_tool: object, arguments: dict | None = None) -> None:
        """Validate a tools/call request, or ``(tool_name, arguments)`` pair."""
        if isinstance(request_or_tool, str):
            tool, params = request_or_tool, arguments
        else:
            request = request_or_tool
            _require(isinstance(request, dict) and request.get("method") == "tools/call",
                     "not a tools/call request")
            params = request.get("params")
            _require(isinstance(params, dict), "invalid tools/call parameters")
            tool, params = params.get("name"), params.get("arguments")
        _require(isinstance(tool, str) and isinstance(params, dict), "invalid tools/call")
        self._validate_tool(tool, params)

    def complete_call(self, request_or_tool: object, response: dict | None = None) -> bool:
        """Commit state only after a successful server response."""
        if response is None:
            response = request_or_tool
        if self._inflight is None:
            return True  # read-only tools have no state to commit
        state, self._inflight = self._inflight, None
        success = _successful_response(response)
        if state == "pending_create" and success:
            self.pending_created = True
            self.review_id = _review_id(response)
        elif state == "direct_create" and success:
            self.direct_created = True
        elif state == "inline" and success:
            self.successful_inline_count += 1
        elif state == "submit_pending" and success:
            self.submitted = True
        return success

    def abort_call(self) -> None:
        self._inflight = None

    # Compact aliases make the policy convenient for focused unit tests.
    validate = validate_call
    complete = complete_call


def _review_id(response: dict):
    result = response.get("result")
    if not isinstance(result, dict):
        return None
    for key in ("reviewID", "reviewId", "id"):
        value = result.get(key)
        if isinstance(value, (str, int)) and not isinstance(value, bool):
            return value
    return None


GuardPolicy = AuthorizationPolicy
MCPGuardPolicy = AuthorizationPolicy


def load_meta(path: str | Path) -> dict:
    raw = Path(path).read_bytes()
    _require(len(raw) <= MAX_REQUEST_BYTES, "metadata is too large")
    value = json.loads(raw)
    _require(isinstance(value, dict), "metadata must be an object")
    return value


def _error(request_id=None) -> bytes:
    return json.dumps(
        {"jsonrpc": "2.0", "id": request_id,
         "error": {"code": -32602, "message": "Invalid request"}},
        separators=(",", ":"),
    ).encode()


def _json_line(value: dict) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=True).encode()


class MCPProxy:
    def __init__(self, policy: AuthorizationPolicy, token_path: str | Path,
                 mcp_binary: str | Path, timeout: float = SERVER_TIMEOUT):
        self.policy = policy
        self.token_path = Path(token_path)
        self.mcp_binary = Path(mcp_binary)
        self.timeout = timeout
        self.process = None
        self._server_buffer = bytearray()

    def _token(self) -> str:
        raw = self.token_path.read_bytes()
        _require(0 < len(raw) <= 4096 and b"\n" not in raw and b"\r" not in raw,
                 "invalid token file")
        token = raw.decode("utf-8")
        _require(token.strip() == token and token, "invalid token file")
        return token

    def start(self) -> None:
        _require(self.mcp_binary.is_file() and os.access(self.mcp_binary, os.X_OK),
                 "MCP binary is not executable")
        env = os.environ.copy()
        for key in ("GH_TOKEN", "GITHUB_TOKEN", TOKEN_ENV):
            env.pop(key, None)
        env[TOKEN_ENV] = self._token()
        tools = ",".join(sorted(ALLOWED_TOOLS))
        self.process = subprocess.Popen(
            [str(self.mcp_binary), "stdio", "--tools=" + tools],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
        )

    def _read_server_line(self) -> bytes:
        _require(self.process is not None and self.process.stdout is not None,
                 "MCP server is unavailable")
        fd = self.process.stdout.fileno()
        deadline = time.monotonic() + self.timeout
        while b"\n" not in self._server_buffer:
            remaining = deadline - time.monotonic()
            _require(remaining > 0, "MCP server timed out")
            ready, _, _ = select.select([fd], [], [], remaining)
            _require(ready, "MCP server timed out")
            chunk = os.read(fd, 65_536)
            _require(chunk, "MCP server closed stdout")
            self._server_buffer.extend(chunk)
            _require(len(self._server_buffer) <= MAX_RESPONSE_BYTES + 1,
                     "MCP response is too large")
        line, _, rest = self._server_buffer.partition(b"\n")
        self._server_buffer = bytearray(rest)
        _require(len(line) <= MAX_RESPONSE_BYTES, "MCP response is too large")
        return bytes(line).rstrip(b"\r")

    def _server_call(self, request: dict) -> dict:
        _require(self.process is not None and self.process.stdin is not None,
                 "MCP server is unavailable")
        self.process.stdin.write(_json_line(request) + b"\n")
        self.process.stdin.flush()
        if "id" not in request:
            return {}
        while True:
            raw = self._read_server_line()
            if not raw.strip():
                continue
            value = json.loads(raw)
            _require(isinstance(value, dict) and value.get("jsonrpc") == "2.0",
                     "invalid MCP response")
            if "id" not in value:
                continue  # server notification
            _require(value.get("id") == request.get("id"), "MCP response id mismatch")
            return value

    @staticmethod
    def _filter_tools(response: dict) -> dict:
        result = response.get("result")
        if not isinstance(result, dict) or not isinstance(result.get("tools"), list):
            return response
        filtered = dict(result)
        filtered["tools"] = [item for item in result["tools"]
                             if isinstance(item, dict) and item.get("name") in ALLOWED_TOOLS]
        output = dict(response)
        output["result"] = filtered
        return output

    def handle(self, request: object) -> bytes | None:
        if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
            return _error()
        request_id = request.get("id")
        method = request.get("method")
        if not isinstance(method, str):
            return _error(request_id)
        has_id = "id" in request
        if method not in FORWARDED_METHODS and method != "tools/call":
            return None if not has_id else _error(request_id)
        if method == "notifications/initialized":
            if has_id:
                return _error(request_id)
            try:
                self._server_call(request)
            except Exception:
                pass
            return None
        if method in FORWARDED_METHODS:
            try:
                response = self._server_call(request)
            except Exception:
                return None if not has_id else _error(request_id)
            if not has_id:
                return None
            if "error" in response:
                return _error(request_id)
            if method == "tools/list":
                response = self._filter_tools(response)
                return _json_line(response)
            return _json_line(response)

        if not has_id:
            return None
        try:
            self.policy.validate_call(request)
        except Exception:
            return _error(request_id)
        try:
            response = self._server_call(request)
        except Exception:
            self.policy.abort_call()
            return _error(request_id)
        try:
            self.policy.complete_call(request, response)
        except Exception:
            self.policy.abort_call()
            return _error(request_id)
        if "error" in response:
            return _error(request_id)
        return _json_line(response)

    def run(self) -> int:
        self.start()
        try:
            while True:
                raw = sys.stdin.buffer.readline(MAX_REQUEST_BYTES + 1)
                if not raw:
                    return 0
                if len(raw) > MAX_REQUEST_BYTES:
                    return 1
                if not raw.strip():
                    continue
                try:
                    request = json.loads(raw)
                except (TypeError, ValueError):
                    sys.stdout.buffer.write(_error())
                    sys.stdout.buffer.write(b"\n")
                    sys.stdout.buffer.flush()
                    continue
                response = self.handle(request)
                if response is not None:
                    _require(len(response) <= MAX_RESPONSE_BYTES, "response is too large")
                    sys.stdout.buffer.write(response + b"\n")
                    sys.stdout.buffer.flush()
        finally:
            if self.process is not None:
                if self.process.stdin is not None:
                    self.process.stdin.close()
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.terminate()
                    try:
                        self.process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
                        self.process.wait()


def main(argv: list[str]) -> int:
    _require(len(argv) == 4, "usage: mcp_guard.py META_PATH TOKEN_PATH MCP_BINARY")
    policy = AuthorizationPolicy(load_meta(argv[1]))
    return MCPProxy(policy, argv[2], argv[3]).run()


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except (ValueError, OSError, UnicodeError, json.JSONDecodeError,
            subprocess.SubprocessError):
        print("mcp guard failed", file=sys.stderr)
        raise SystemExit(1)
