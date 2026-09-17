# Working in this repo (read this before editing anything)

This file is written for an AI coding agent, not a human onboarding doc.
It states the rules this codebase actually runs on, each with the failure
it prevents, so you apply them instead of just reading them. If you are
about to touch `sql/*.sql` or `src/*.rs`, read this fully first.

## What this project is

`allgres` is a PostgreSQL extension (Rust, `pgrx`) that turns a Postgres
database into an agent control plane: two background workers
(`allgres runtime`, `allgres web`), a large hand-written PL/pgSQL API
surface across `sql/*.sql`, and a single-page dashboard (`web/index.html`)
talking to it over `allgres.dashboard_rpc`. Almost all real logic lives in
SQL, not Rust — `src/*.rs` is the native facade (background workers, HTTP,
SQL parsing via Postgres's own grammar) that the SQL layer calls into.

## Non-negotiable verification loop

Never report a SQL or Rust change as done without actually running this.
Every regression this project has hit in practice was caught by one step
of this loop, not by reading the diff:

1. `cargo pgrx install --no-default-features --features pg<NN> --pg-config <path>`
   (rebuilds and installs into the live PostgreSQL install).
2. Fresh install: `DROP EXTENSION IF EXISTS allgres CASCADE;` (or a new
   database) → `CREATE EXTENSION pgcrypto; CREATE EXTENSION allgres;` →
   `SELECT allgres_public.fn_selftest();` → confirm `"failed": 0`.
3. **Idempotent rerun**: call `fn_selftest()` again in a genuinely separate
   connection (`psql -c` twice, not `fn_selftest(), fn_selftest()` in one
   `SELECT` — two calls in the same transaction share `SET LOCAL` state
   and produce a false failure that looks real; this has actually happened
   in this project). Must still be `"failed": 0`.
4. `cargo test --lib` (Rust unit tests — unaffected by SQL-only changes,
   but confirm anyway if you touched `src/`).
5. For anything touching auth, permissions, background workers, or new
   external calls: verify live over real HTTP/psql, not just via
   `fn_selftest`. A permission or role-scoping bug can pass `fn_selftest`
   (often run as a superuser-equivalent role) while failing for the actual
   restricted role in production — this has happened twice: a
   `pg_read_all_settings`/`pg_read_all_stats` gap that only showed up
   calling as the real restricted role, not as `allgres_owner`.

Only after all of the above passes, commit.

## Comment style: why, never what

Default to no comments. Add one only for a non-obvious constraint, a
workaround for a specific bug, or an invariant a reader would not expect —
never to restate what the next line already says. If removing a comment
wouldn't confuse a future reader, don't write it. This codebase leans
heavily on this: read any existing function's comments before adding your
own, to match density and tone, not just syntax.

## Adding a new SECURITY DEFINER function that needs a broad privilege

If a new function needs something powerful — `CREATEROLE`,
`pg_signal_backend`, `pg_read_all_settings`, `pg_read_all_stats`, anything
broader than what it strictly does — do **not** grant it to `allgres_owner`
(which owns most of the SQL surface; a bug in any one function would then
carry that privilege too). Instead:

1. Create a new `NOLOGIN NOINHERIT` role that owns nothing but this one
   function (see `allgres_signal_admin`, `allgres_settings_reader` in
   `sql/control_plane.sql` for the pattern).
2. Grant it only the exact privilege needed, `WITH INHERIT TRUE` if it's a
   predefined role membership (PG16+ syntax — a `NOINHERIT` role's own
   memberships are otherwise invisible to itself).
3. Add the function's name to the ownership-exclusion list in
   `sql/grants_and_facade.sql` **twice** — there are two ownership-fixing
   passes in that file (one early, one at the very end, to catch native
   `#[pg_extern]` functions pgrx splices in late). Missing the second list
   silently reassigns the function back to `allgres_owner` moments after
   the first pass sets it correctly. This is a real bug that shipped and
   was only caught by step 5 of the verification loop above.
4. Grant EXECUTE explicitly to whatever else needs to call it (e.g.
   `fn_selftest` itself runs as `allgres_owner` and needs its own grant if
   it calls the new function).

## `sql/selftest.sql` variable hygiene

Every new test fixture gets its **own** declared variable
(`v_my_new_thing`), never a reused generic scratch variable (`v_provider`,
`sub`, `ok`, `v` are fine to reuse for pure booleans/throwaway results —
not for anything a *later* test section still depends on). Reusing a
shared variable for a new, textually-earlier fixture has broken a later
section's assumption about that variable's value at least twice in this
project's history. If in doubt, use a dedicated variable.

## Changing the `dashboard_rpc` surface

Adding, removing, or renaming a `dashboard_rpc` action means updating three
places in the same commit, or CI's frozen-catalog check fails:

1. The action's own branch in `allgres.dashboard_rpc`
   (`sql/grants_and_facade.sql`).
2. `sql/rpc_catalog.json` — regenerate with
   `python3 scripts/gen_rpc_catalog.py`, don't hand-edit.
3. `fn_selftest`'s own `dashboard_rpc_actions_match_frozen_catalog` case in
   `sql/selftest.sql` (two hardcoded arrays: "missing" and "extra").

See `CONTRACT.md` for the full contract this protects and why it exists.

## Docs are part of the change, not an afterthought

- `KNOWN_ISSUES.md` gets a new numbered item for every real gap fixed or
  feature added — past-tense engineering-log style: what was wrong, what
  changed, exactly how it was verified (fresh + idempotent selftest
  counts, live verification steps, what broke along the way and how it
  was actually caught). Read a recent entry before writing a new one to
  match the register.
- `README.md` gets updated in the relevant section, same commit.
- When closing a gap `README.md`'s "Known limitations" or "Not yet built"
  section mentions, **update both**, not just one — this exact pair of
  locations has gone stale independently at least twice (an already-closed
  gap kept being listed as open in one of the two long after the other was
  fixed).

## What not to do

- Don't add abstractions, config flags, or generality beyond what the
  current task needs. Three similar lines beats a shared helper built for
  a hypothetical future case.
- Don't add error handling or validation for scenarios that can't occur
  given this codebase's own invariants (e.g. don't re-validate something
  a caller's own `CHECK` constraint or an earlier guard already ensures).
- Don't guess at whether something works. If you can build it and run it,
  do that before claiming success — this project's own history is full of
  bugs that looked correct on read-through and were only caught by
  actually rebuilding, reinstalling, and calling the thing.
- Don't leave a stale doc claim in place because the code changed and
  three other things needed fixing first. Doc lag has been the single
  most repeated category of externally-caught bug in this project.
- Never mention model identity (which AI, which model) in commit
  messages, PR descriptions, or code comments — attribution footers are
  handled separately by whatever tooling is committing.
