"""Agent-facing tool: respond to a native JS dialog (alert/confirm/prompt).

Two backends, chosen automatically:

- **CDP supervisor** (Browserbase, local Chrome via ``/browser connect``, or
  ``browser.cdp_url`` in config): the agent reads ``pending_dialogs`` from
  ``browser_snapshot`` output, then calls ``browser_dialog(action=...)``.
- **Local headless Chromium** (the default QA backend): responds via the
  ``agent-browser dialog <accept|dismiss|status>`` CLI verb against the
  session daemon. Without this path a ``confirm()``/``prompt()`` in local
  mode could not be exercised at all — the delete/leave confirmation appeared
  to "do nothing" and confirm-gated flows were untestable.

See ``website/docs/developer-guide/browser-supervisor.md`` for the full
supervisor design.
"""

from __future__ import annotations

import json
import logging
from typing import Any, Dict, Optional

from tools.browser_supervisor import SUPERVISOR_REGISTRY
from tools.registry import registry

logger = logging.getLogger(__name__)


BROWSER_DIALOG_SCHEMA: Dict[str, Any] = {
    "name": "browser_dialog",
    "description": (
        "Respond to a native JavaScript dialog (alert / confirm / prompt / "
        "beforeunload) that is currently blocking the page.\n\n"
        "**Workflow:** call ``browser_snapshot`` first — if a dialog is open, "
        "it appears in the ``pending_dialogs`` field with ``id``, ``type``, "
        "and ``message``. Then call this tool with ``action='accept'`` or "
        "``action='dismiss'``.\n\n"
        "**Prompt dialogs:** pass ``prompt_text`` to supply the response "
        "string. Ignored for alert/confirm/beforeunload.\n\n"
        "**Multiple dialogs:** if more than one dialog is queued (rare — "
        "happens when a second dialog fires while the first is still open), "
        "pass ``dialog_id`` from the snapshot to disambiguate.\n\n"
        "**action='status'** just reports whether a dialog is currently open "
        "(local backend) without responding to it.\n\n"
        "**Availability:** the default local headless Chromium and every "
        "CDP-capable backend (Browserbase, local Chrome via "
        "``/browser connect``, ``browser.cdp_url``). Not available on Camofox "
        "(REST-only)."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": ["accept", "dismiss", "status"],
                "description": (
                    "'accept' clicks OK / returns the prompt text. "
                    "'dismiss' clicks Cancel / returns null from prompt(). "
                    "'status' only reports whether a dialog is open. "
                    "For ``beforeunload`` dialogs: 'accept' allows the "
                    "navigation, 'dismiss' keeps the page."
                ),
            },
            "prompt_text": {
                "type": "string",
                "description": (
                    "Response string for a ``prompt()`` dialog. Ignored for "
                    "other dialog types. Defaults to empty string."
                ),
            },
            "dialog_id": {
                "type": "string",
                "description": (
                    "Specific dialog to respond to, from "
                    "``browser_snapshot.pending_dialogs[].id``. Required "
                    "only when multiple dialogs are queued."
                ),
            },
        },
        "required": ["action"],
    },
}


def _browser_dialog_local(
    effective_task_id: str,
    action: str,
    prompt_text: Optional[str],
) -> str:
    """Respond via the ``agent-browser dialog`` CLI verb (local backend).

    Works against the session daemon without a CDP supervisor. These control
    commands operate at the browser level, so they succeed even while the
    page's JS thread is blocked on a synchronous ``confirm()``/``prompt()``.
    """
    from tools.browser_tool import _last_session_key, _run_browser_command

    session_key = _last_session_key(effective_task_id)
    cli_args = [action]
    if action == "accept" and prompt_text is not None:
        cli_args.append(str(prompt_text))
    try:
        res = _run_browser_command(session_key, "dialog", cli_args, timeout=10)
    except Exception as exc:
        return json.dumps({"success": False, "error": f"dialog {action} failed: {exc}"})
    if res.get("success"):
        return json.dumps(
            {"success": True, "action": action, "dialog": res.get("data", {})}
        )
    return json.dumps(
        {"success": False, "action": action, "error": res.get("error", "no dialog / command failed")}
    )


def browser_dialog(
    action: str,
    prompt_text: Optional[str] = None,
    dialog_id: Optional[str] = None,
    task_id: Optional[str] = None,
) -> str:
    """Respond to a pending dialog — CDP supervisor if attached, else local CLI."""
    effective_task_id = task_id or "default"
    supervisor = SUPERVISOR_REGISTRY.get(effective_task_id)
    if supervisor is None:
        # No supervisor: fall back to the local CLI dialog verb, which is the
        # normal case for the default headless-Chromium QA backend.
        return _browser_dialog_local(effective_task_id, action, prompt_text)

    if action == "status":
        # Supervisor exposes pending dialogs via browser_snapshot; no explicit
        # status probe needed there.
        return json.dumps(
            {
                "success": True,
                "action": "status",
                "note": "Read pending_dialogs from browser_snapshot for supervisor-backed sessions.",
            }
        )

    result = supervisor.respond_to_dialog(
        action=action,
        prompt_text=prompt_text,
        dialog_id=dialog_id,
    )
    if result.get("ok"):
        return json.dumps(
            {
                "success": True,
                "action": action,
                "dialog": result.get("dialog", {}),
            }
        )
    return json.dumps({"success": False, "error": result.get("error", "unknown error")})


def _browser_dialog_check() -> bool:
    """Gate: offered on the local backend and on any CDP-capable backend.

    The local path uses the ``agent-browser dialog`` CLI verb (no supervisor
    required); the supervisor path covers Browserbase / ``browser.cdp_url`` /
    ``/browser connect``. Only Camofox (REST-only, no dialog verb) is excluded.
    """
    try:
        from tools.browser_tool import _is_camofox_mode, _is_local_backend
        if _is_camofox_mode():
            return False
        if _is_local_backend():
            return True
    except Exception as exc:  # pragma: no cover — defensive
        logger.debug("browser_dialog check: browser_tool import failed: %s", exc)
    try:
        from tools.browser_cdp_tool import _browser_cdp_check  # type: ignore[import-not-found]
    except Exception as exc:  # pragma: no cover — defensive
        logger.debug("browser_dialog check: browser_cdp_tool import failed: %s", exc)
        return False
    return _browser_cdp_check()


registry.register(
    name="browser_dialog",
    toolset="browser-cdp",
    schema=BROWSER_DIALOG_SCHEMA,
    handler=lambda args, **kw: browser_dialog(
        action=args.get("action", ""),
        prompt_text=args.get("prompt_text"),
        dialog_id=args.get("dialog_id"),
        task_id=kw.get("task_id"),
    ),
    check_fn=_browser_dialog_check,
    emoji="💬",
)
