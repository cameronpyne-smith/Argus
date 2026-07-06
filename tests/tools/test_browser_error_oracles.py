"""Tests for the passive JS-error / HTTP-5xx oracles (_attach_new_error_signals)."""

import os
import sys
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))


def _cmd_router(errors=None, requests=None):
    """Build a _run_browser_command side-effect keyed on the verb."""
    errors = errors or []
    requests = requests or []

    def _run(task_id, command, args=None, timeout=None):
        if command == "errors":
            return {"success": True, "data": {"errors": errors}}
        if command == "network":
            return {"success": True, "data": {"requests": requests}}
        return {"success": True, "data": {}}

    return _run


def _reset_state(bt, task="t"):
    bt._seen_console_errors.pop(task, None)
    bt._seen_server_errors.pop(task, None)


class TestServerErrorOracle:
    def test_query_string_deduped_as_one_fault(self):
        import tools.browser_tool as bt
        _reset_state(bt)
        reqs = [
            {"status": 500, "method": "GET", "url": "https://x/api/poll?t=1"},
            {"status": 500, "method": "GET", "url": "https://x/api/poll?t=2"},
        ]
        resp = {}
        with patch.object(bt, "_run_browser_command", side_effect=_cmd_router(requests=reqs)):
            bt._attach_new_error_signals("t", resp)
        assert len(resp["new_server_errors"]) == 1
        # Full URL (with query) is preserved as evidence.
        assert "?t=1" in resp["new_server_errors"][0]

    def test_distinct_endpoints_both_surface(self):
        import tools.browser_tool as bt
        _reset_state(bt)
        reqs = [
            {"status": 500, "method": "POST", "url": "https://x/api/save"},
            {"status": 503, "method": "GET", "url": "https://x/api/load"},
        ]
        resp = {}
        with patch.object(bt, "_run_browser_command", side_effect=_cmd_router(requests=reqs)):
            bt._attach_new_error_signals("t", resp)
        assert len(resp["new_server_errors"]) == 2

    def test_overflow_beyond_cap_resurfaces_next_poll(self):
        import tools.browser_tool as bt
        _reset_state(bt)
        reqs = [
            {"status": 500, "method": "GET", "url": f"https://x/api/e{i}"}
            for i in range(8)
        ]
        resp1 = {}
        with patch.object(bt, "_run_browser_command", side_effect=_cmd_router(requests=reqs)):
            bt._attach_new_error_signals("t", resp1)
        assert len(resp1["new_server_errors"]) == 5
        # The 3 not surfaced were NOT marked seen — a second poll surfaces them.
        resp2 = {}
        with patch.object(bt, "_run_browser_command", side_effect=_cmd_router(requests=reqs)):
            bt._attach_new_error_signals("t", resp2)
        assert len(resp2["new_server_errors"]) == 3

    def test_poll_failure_warns_once(self):
        import tools.browser_tool as bt
        _reset_state(bt)
        bt._server_error_poll_warned = False

        def _run(task_id, command, args=None, timeout=None):
            if command == "errors":
                return {"success": True, "data": {"errors": []}}
            if command == "network":
                return {"success": False, "error": "unknown verb"}
            return {"success": True, "data": {}}

        with patch.object(bt, "_run_browser_command", side_effect=_run), \
             patch.object(bt.logger, "warning") as warn:
            bt._attach_new_error_signals("t", {})
            bt._attach_new_error_signals("t", {})
        assert warn.call_count == 1


class TestJsErrorOracle:
    def test_reads_text_field(self):
        import tools.browser_tool as bt
        _reset_state(bt)
        errs = [{"text": "Uncaught TypeError: x", "line": 1}]
        resp = {}
        with patch.object(bt, "_run_browser_command", side_effect=_cmd_router(errors=errs)):
            bt._attach_new_error_signals("t", resp)
        assert resp["new_js_errors"] == ["Uncaught TypeError: x"]

    def test_overflow_beyond_cap_resurfaces_next_poll(self):
        import tools.browser_tool as bt
        _reset_state(bt)
        errs = [{"text": f"Error {i}"} for i in range(8)]
        resp1 = {}
        with patch.object(bt, "_run_browser_command", side_effect=_cmd_router(errors=errs)):
            bt._attach_new_error_signals("t", resp1)
        assert len(resp1["new_js_errors"]) == 5
        resp2 = {}
        with patch.object(bt, "_run_browser_command", side_effect=_cmd_router(errors=errs)):
            bt._attach_new_error_signals("t", resp2)
        assert len(resp2["new_js_errors"]) == 3
