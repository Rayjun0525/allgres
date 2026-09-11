#!/usr/bin/env python3
"""Regenerate sql/rpc_catalog.json from allgres.dashboard_rpc's own CASE
statement in sql/control_plane.sql.

This is the frozen public contract for the dashboard/API surface: every
action dashboard_rpc accepts, which guard function (if any) its own branch
calls directly, and which p_request keys it reads. It is generated, not
hand-maintained, so it can never silently drift from the real dispatch --
run this after adding, removing, or renaming an action, then update the
matching frozen action-name array in fn_selftest's
'dashboard_rpc_actions_match_frozen_catalog' case (sql/control_plane.sql)
to match. That selftest case is what actually enforces the freeze: it
fails loudly if the two ever disagree.

A guard reported here is only what the branch calls *directly* -- some
actions (project_chat.send/history, agents.set_my_model, chat.*,
messenger.post) delegate their own access check to the SQL function they
call (fn_project_chat_send's own require_project_access, etc.) instead of
guarding inline, so they show an empty guard list here without being
open. This script cannot see into a called function's own body -- read
the function it calls if a branch's security model isn't obvious from an
empty guard list here.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SQL_FILE = ROOT / "sql" / "control_plane.sql"
OUT_FILE = ROOT / "sql" / "rpc_catalog.json"

GUARD_NAMES = [
    "require_admin_for_system_agent",
    "require_admin_if_accounts_exist",
    "require_admin",
    "require_agent_access_if_accounts_exist",
    "require_agent_access",
    "require_project_access",
    "visible_agent_ids",
    "session_user",
]
GUARD_PAT = re.compile(
    r"allgres_private\.(" + "|".join(GUARD_NAMES) + r")\("
)
PARAM_PAT = re.compile(r"p_request(?:->>|->)'([a-zA-Z_]+)'")
WHEN_PAT = re.compile(r"\s*WHEN '([^']+)' THEN")


def extract_dashboard_rpc_body(lines):
    start = None
    for i, l in enumerate(lines):
        if "CREATE OR REPLACE FUNCTION allgres.dashboard_rpc" in l:
            start = i
            break
    if start is None:
        sys.exit("could not find allgres.dashboard_rpc in control_plane.sql")
    end = None
    for i in range(start, len(lines)):
        if lines[i].strip() == "$fn$;" and i > start + 10:
            end = i
            break
    if end is None:
        sys.exit("could not find the end of allgres.dashboard_rpc")
    return lines[start:end]


def main():
    lines = SQL_FILE.read_text().splitlines(keepends=True)
    body = extract_dashboard_rpc_body(lines)

    whens = []
    for i, l in enumerate(body):
        m = WHEN_PAT.match(l)
        if m:
            whens.append((m.group(1), i))

    catalog = []
    for idx, (name, lineno) in enumerate(whens):
        nxt = whens[idx + 1][1] if idx + 1 < len(whens) else len(body)
        branch_text = "".join(body[lineno:nxt])
        guards = sorted(set(GUARD_PAT.findall(branch_text)))
        params = sorted(set(PARAM_PAT.findall(branch_text)))
        catalog.append({"action": name, "guards": guards, "params": params})

    OUT_FILE.write_text(json.dumps(catalog, indent=2) + "\n")
    print(f"wrote {len(catalog)} actions to {OUT_FILE.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
