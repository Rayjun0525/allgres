# The SQL sandbox

Part of the [documentation index](../README.md). See also: [Security
model](security.md) for the roles this executes under.

This page is about *agent*-issued SQL, gated the way the rest of it
describes. The dashboard's own admin SQL console (its own nav page) is a
different, deliberately unsandboxed thing — see [Security model,
"The SQL console"](security.md#the-sql-console).

Agents can emit `{"action":"execute_sql","sql":"SELECT ..."}`. What that
statement is allowed to touch is decided from **PostgreSQL's own parse tree**:
`allgres.analyze_sql` calls `raw_parser` and reads the resulting nodes. Nothing
is planned, rewritten, or executed during analysis.

This replaced a regex layer. Text scanning has to re-implement lexing, and every
piece of that is a way to be wrong in one direction or the other — comment
injection (`FROM v_sales --x\n, allgres_private.sessions`), quoted identifiers,
comma joins, `extract(year FROM col)`, dollar quotes, a schema name that is
really just a string literal. The grammar has already settled all of it.

Validated statements do not run inline. PostgreSQL refuses `SET ROLE` inside a
security-definer function (`cannot set parameter "role" within
security-definer function`, SQLSTATE 42501), and `fn_validate_sql` is
`SECURITY DEFINER` — it has to be, since it reads `allgres_private.permissions`
and `pg_proc` regardless of who is asking. So it only validates and returns
the normalized statement text; it queues that text in `allgres_private.sql_calls`
and the runtime worker's SPI thread claims it and runs it as a **top-level**
statement, issued directly by the worker with no enclosing `SECURITY DEFINER`
frame — the same claim/complete shape already used for outbound LLM and function
calls. `SET ROLE sandbox` is legal there.

Layered, strongest first:

1. the statement only ever executes as `sandbox`, never as `fn_validate_sql`'s
   owner;
2. `search_path = pg_temp`, so an unqualified relation name cannot resolve to
   anything at all;
3. the agent-visible views return no rows unless the current agent holds the
   matching permission (`allgres_private.agent_may_read`), so authorisation does
   not depend on the analysis being complete;
4. `transaction_read_only` and a 5s `statement_timeout` — both real now that
   execution is a top-level statement instead of nested inside one;
5. a function must be on `allgres_private.sql_function_allowlist` — a seeded,
   positive allowlist of the aggregate, string, math, date and json
   functions an analyst actually needs — **and** pass every other gate:
   non-volatile (the property that separates a read from a side effect;
   `pg_read_file`, `pg_ls_dir`, `lo_import`, `dblink`, `nextval` and
   `pg_sleep` are all volatile), `pg_catalog` only (rules out every
   user-defined `SECURITY DEFINER` function, Allgres's own control-plane
   functions included, and every extension function such as `pgcrypto`'s or
   `dblink`'s), `NOT prosecdef` as defense in depth, and not on an explicit
   denylist as one more backstop. The allowlist is the one that actually
   matters: a denylist can only ever name what is already known to be
   dangerous, and volatility alone is not a security boundary either —
   `current_setting('allgres.secret_key', true)` and
   `pg_show_all_settings()` are both `STABLE`, not volatile, and both
   confirmed live (before each was closed) to hand back the key that
   encrypts every provider secret in the system, or every GUC on the server
   outright. A denylist has to be told about each of those by name; an
   allowlist doesn't. Unknown names, and anything failing any of these
   gates, are rejected rather than assumed safe;
6. the parse tree must be exactly one non-writing `SELECT` (this also catches
   `SELECT ... INTO` and data-modifying CTEs, which are `SelectStmt` nodes);
7. every relation named must be schema-qualified, outside the reserved schemas,
   and present in the allowlist ∩ that agent's permissions.
