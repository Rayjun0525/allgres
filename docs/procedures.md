# Procedures

Part of the [documentation index](../README.md).

Roadmap item 4: a **procedure** (`allgres_private.procedures`) is a named,
versioned, reusable "how to do X" an operator curates once from the
**Settings → Procedures** panel — free text: a checklist, a SQL template, a
delegation plan, whatever shape is useful. It is distinct from a memory in
every way that matters here: shared rather than private to one agent,
explicitly granted rather than automatically written, and versioned —
`fn_set_procedure` snapshots the previous content into `procedure_history`
only on an actual change (the same "only a real change bumps generation"
rule `fn_set_policy` already applies to an agent's own policy), and
`fn_rollback_procedure` restores a past version by creating a *new* one
that happens to match it, the same non-destructive shape `fn_rollback_policy`
uses — nothing is ever overwritten in place.

An agent sees a procedure's current content in its own prompt, on every
turn, only once granted the matching permission — `resource_type =
'procedure'`, `resource_ref = '<name>'` — through the exact same
`agent_has_permission`/`agent_permission_refs` machinery (inheritance
through a system agent's parent chain included) that already gates a view
or a function. A disabled procedure (`is_active = false`) never shows even
to an agent holding the grant, the same way a disabled `llm_providers` row
stops being reachable without losing its history.

Deliberately not in this slice: no agent-authored procedures yet — an
operator is the only one who can create, edit, or roll one back today.
Letting an agent *propose* a new or improved procedure (through the same
admin_approval/self_approve/auto autonomy-level flow `propose_change`
already gives an agent for its own policy) is real future work, not done
here.

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
procedure to the General agent. To make a new Function usable, bind it to a
procedure, then grant that procedure to the intended agent in the usual
permission UI. This keeps the naming model clear: **Procedure** is the
reusable capability; a **Function** is one operation inside it — fixed for
`http_get`, a real role-scoped PL/pgSQL body for `plpgsql`. An MCP-client
handler is planned next (see the v2 redesign notes in KNOWN_ISSUES.md).
