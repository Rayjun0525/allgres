# Procedures

Part of the [documentation index](../README.md).

Roadmap item 4: a **procedure** (`allgres_private.procedures`) is a named,
versioned, reusable "how to do X" an operator curates once from the
**Settings → Procedures** panel. It has two independent halves: `content`,
free text an agent reads in its own prompt (a checklist, background, when
to use this — whatever shape is useful), and `body`, real PL/pgSQL code
the agent can actually *run* (see "Running a procedure" below). A
procedure with only `content` and no `body` works exactly as it always
did — read-only guidance the agent acts on turn by turn. It is distinct
from a memory in every way that matters here: shared rather than private
to one agent, explicitly granted rather than automatically written, and
versioned — `fn_set_procedure` snapshots the previous `content`/`body`
into `procedure_history` only on an actual change (the same "only a real
change bumps generation" rule `fn_set_policy` already applies to an
agent's own policy), and `fn_rollback_procedure` restores a past version
(both halves) by creating a *new* one that happens to match it, the same
non-destructive shape `fn_rollback_policy` uses — nothing is ever
overwritten in place, and restoring an old `body` re-queues its build the
same way any other edit does.

An agent sees a procedure's current `content` in its own prompt, on every
turn, only once granted the matching permission — `resource_type =
'procedure'`, `resource_ref = '<name>'` — through the exact same
`agent_has_permission`/`agent_permission_refs` machinery (inheritance
through a system agent's parent chain included) that already gates a view
or a function. A disabled procedure (`is_active = false`) never shows even
to an agent holding the grant, the same way a disabled `llm_providers` row
stops being reachable without losing its history. Running a `body` with
`run_procedure` requires that exact same grant — there is no separate
permission to run one versus merely read its description.

Deliberately not in this slice: no agent-authored procedures yet — an
operator is the only one who can create, edit, or roll one back today
(unlike a plpgsql Function, which any agent may also author itself — see
[Functions](#functions) below). Letting an agent *propose* a new or
improved procedure (through the same admin_approval/self_approve/auto
autonomy-level flow `propose_change` already gives an agent for its own
policy) is real future work, not done here.

## Functions

A procedure may also bind one or more named **Functions**
(`allgres_private.functions`, `procedure_function_bindings`). A Function is
the callable half of a procedure: its name and description (and, for the
`plpgsql` handler, its `param_schema`) are shown with the procedure in the
agent's `functions` bounds (the `call_function` action).

Two handlers exist:

- **`http_get`** — deliberately narrow: one fixed, operator-reviewed HTTPS
  URL. An agent calls the function name (for example, `seoul_weather`) with
  an empty argument object; `fn_submit_result` replaces any returned
  arguments with the saved `args_template` before queuing the request, then
  still runs the usual outbound URL validation. A procedure grant therefore
  authorizes precisely the reviewed operation without also granting
  arbitrary `http_get` access or an open-ended host permission.
- **`plpgsql`** — a real PL/pgSQL function body. Authoring it (`body`, a
  `param_schema` documenting the expected `args` shape) queues an
  asynchronous build: the runtime worker itself issues
  `CREATE OR REPLACE FUNCTION allgres_functions.<generated ident>(p_args
  jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER AS $$<body>$$` as a
  top-level SPI statement under `SET LOCAL ROLE allgres_function_admin` —
  the same "SET ROLE is illegal inside a SECURITY DEFINER function" split
  `execute_sql`'s own sandbox already uses (see
  [The SQL sandbox](sql-sandbox.md)), applied to DDL instead of a validated
  `SELECT`. Once built (`functions.build_status = 'built'`), a `call_function`
  against it is queued into `allgres_private.function_calls` and run the
  same way: `SET LOCAL ROLE <the calling agent's own Postgres role>` before
  calling it, so the body can only ever do what that specific agent's own
  grants already allow. This is the real security boundary — not a
  procedural check re-derived on every call, but the engine's own privilege
  system, confirmed live: a body that tries to read a table no ordinary
  agent role has access to fails with a genuine `permission denied`, the
  same error any other role-scoped query would raise (see
  KNOWN_ISSUES.md's Phase 3b entry for the exact reproduction).
  `validate_function_body` rejects a body that tries to declare
  `SECURITY DEFINER` or change role before it ever reaches `CREATE
  FUNCTION`, as defense in depth — the real boundary is still the role
  switch above, not this check.
- **`mcp_call`** — calls one remote tool on a registered MCP server over
  HTTP, via a JSON-RPC `tools/call` request. Reuses
  `allgres_private.api_connections` for the server registration rather
  than a second connection registry — an MCP server is just another named
  HTTP endpoint with an optional credential, the same shape
  `http_request`'s own connection already is. `args_template` holds only
  `{"tool":"<remote tool name>"}`, fixed at creation like `http_get`'s own
  single field; the agent's own `call_function` args become the JSON-RPC
  request's `arguments` object, never fixed — closer to `http_request`'s
  "operator fixes the destination, the agent supplies the request
  content" split than to `http_get`'s fully-fixed shape. No build step:
  unlike `plpgsql`, there is no dynamically-compiled Postgres object here,
  just a JSON-RPC envelope built at call time. A JSON-RPC-level `error`
  and the MCP-specific `result.isError` tool failure are both reported
  back as a plain error, never mistaken for a successful `function_result`
  — confirmed live against a real HTTP endpoint (see KNOWN_ISSUES.md's
  Phase 3d entry). Deliberately narrow, the same way `http_get` was at
  first: a direct `tools/call` request with no prior MCP session
  handshake (`initialize`), so it works against a stateless MCP-over-HTTP
  server but not one that requires establishing a session first — a real
  interoperability gap for some servers, not yet addressed.

Create or edit a Function via the `functions.create` / `functions.update` /
`functions.bind` dashboard_rpc actions — there is no dedicated Settings
panel for authoring them yet, only the read-only Function model experiments
panel. **Any agent** may also author or edit one itself, through
`create_function` / `update_function` actions gated by that agent's own
`autonomy_level` (`admin_approval` queues a `change_proposals` row for an
operator to decide; `self_approve`/`auto` apply immediately) — unlike
`create_agent`, this is not restricted to one named system agent, since a
Function's real security boundary (SECURITY INVOKER plus the calling
agent's own role) holds regardless of who authored the body.

The seeded `seoul-weather` procedure demonstrates the `http_get` pattern: it
binds `seoul_weather` to `https://wttr.in/Seoul?format=j1` and grants the
procedure to the General agent. To make a new Function usable via
`call_function`, bind it to a procedure, then grant that procedure to the
intended agent in the usual permission UI — binding is advisory for this
purpose only (which Functions to show alongside a procedure's `content`),
never an enforcement gate: a procedure's own `body` (below) may call any
Function it likes, bound or not, since the real enforcement is the
Postgres role the call actually runs under, not this table.

## Running a procedure

A procedure's `body` is real PL/pgSQL, built the identical way a plpgsql
Function's `body` is (queued, then `CREATE OR REPLACE PROCEDURE
allgres_functions.<generated ident>(p_args jsonb, INOUT p_result jsonb)
LANGUAGE plpgsql SECURITY INVOKER AS $$<body>$$` issued by the runtime
worker as a top-level SPI statement under `SET LOCAL ROLE
allgres_function_admin`) — a procedure has no `RETURNS` clause of its
own, so the body is expected to assign `p_result` before it ends, the way
a Function's body ends in `RETURN`.

An agent runs one with `run_procedure` (`{"action":"run_procedure",
"procedure":"<name>","args":{...}}`), queued into
`allgres_private.procedure_calls` and executed the same way a
`call_function` is: `SET LOCAL ROLE <the calling agent's own Postgres
role>` before the `CALL`. The crucial difference from `call_function` is
what happens *inside* that one role-scoped session: the procedure's own
body calls whichever Functions it needs directly, as ordinary nested
statements, in order, with real `IF`/`LOOP` branching — not one LLM turn
per Function call the way an agent following a procedure's `content` by
hand would. There is no second queue round trip for a Function called
this way: the queue and `SET ROLE` only exist to get *into* the
role-scoped session in the first place, not for every statement run once
inside it. This also means the body can only call something synchronous
directly as a nested statement — another plpgsql Function, ordinary SQL,
or `allgres_private.fn_llm_complete` (below) — never an `http_get`/
`http_request`/`mcp_call` Function, which requires an outbound HTTP round
trip a single blocking procedure call cannot wait on; that capability
remains future work. The result comes back once, as a `procedure_result`
(its own `execution_logs` role, distinct from a Function's
`function_result`) — confirmed live: a procedure whose body called a
Function and branched on its result returned the correctly-branched
value, and a procedure whose body tried to read a table its calling
agent's role has no grant on failed with the identical genuine
`permission denied` a plpgsql Function would (see KNOWN_ISSUES.md's Phase
3c entry).

### A Procedure body's own `call_llm`-style helper: `fn_llm_complete`

A Procedure body can ask an LLM something mid-pipeline, synchronously,
with `p_result := allgres_private.fn_llm_complete(p_messages, p_llm_config)`
— `p_messages` the same `[{"role":"user","content":"..."}]` shape
`fn_next_step`'s own turn loop builds, `p_llm_config` a required
`{"provider":"...","model":"..."}` naming a real, enabled provider (no
default from the calling agent's own policy: a Procedure body has no
readily available "which agent is this" once `SET LOCAL ROLE` has
already erased that from the role system for this session, so the
provider/model is fixed at authoring time, the same way `http_get`'s URL
or `mcp_call`'s tool name is). Named `fn_llm_complete`, not `call_llm` —
that string is already `fn_next_step`'s own `"action"` value for a
completely different thing (the main turn loop's own next-step verb),
and reusing it here would make every future mention ambiguous. Returns
`{"ok": true, "content": "...", "parsed": <jsonb-or-null>}` on success or
`{"ok": false, "error": "..."}` on a network-level failure (bad status,
timeout, unparsable body) — a plain value the body branches on with an
`IF`, not an exception; a misconfigured `p_llm_config` (no such provider,
disabled, no model) still raises, since that is an authoring bug to fix,
not a runtime condition. Unlike a Function or Procedure call, this is not
logged into `execution_logs` or `outbound_calls` — it is the Procedure's
own internal utility call, not a step in the visible agent/LLM
conversation, and (a known gap) its cost is not yet attributed to any
schedule's `spent_cost_usd` budget. Confirmed live: a real Procedure body
called `fn_llm_complete` against a real local HTTP endpoint and returned
its actual response, unwrapped, in the `procedure_result` log (see
KNOWN_ISSUES.md's Phase 3e entry).

This keeps the naming model clear: **Procedure** is the reusable
capability, now real code as well as a description; a **Function** is one
operation inside it — fixed for `http_get`, a real role-scoped PL/pgSQL
body for `plpgsql`, one remote tool call for `mcp_call`. A Procedure body
may only call something synchronous this way (another `plpgsql` Function,
ordinary SQL, or `fn_llm_complete`) — an `http_get`/`http_request`/
`mcp_call` Function needs a real outbound HTTP round trip, which a single
blocking `CALL` cannot wait on; that remains future work (see the v2
redesign notes in KNOWN_ISSUES.md).
