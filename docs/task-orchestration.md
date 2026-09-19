# Task dependencies and schedules

Part of the [documentation index](../README.md).

## Task dependencies

Roadmap item 5: `delegate` on its own is a one-shot, fire-and-forget hand-off
— the moment a child task is queued, the parent task completes. That is
still the default, unchanged, and is exactly what self_improve's
cross-agent proposals already rely on. `delegate` also now accepts
`"wait": true`: instead of completing, the
parent stays `running`, so its very next turn can delegate again (fanning
out to more agents) or call the new `await_children` action — which pauses
the task (`waiting_children`) until *every* task it has delegated, however
many, reaches a terminal state, then resumes with what each one actually
did (agent, status, output, error) appended to its own log. `await_children`
is rejected outright if there is nothing pending to wait on.

This is a real dependency edge, not a worker-memory illusion: the only
state involved is `tasks.status = 'waiting_children'` and the ordinary
`parent_task_id` link every delegated task already has. The wake side lives
in `fn_watchdog` (already polled every tick) as a plain re-scan — "is any
task `waiting_children` whose children are now all done" — so a worker or
database restart mid-wait loses nothing; the next tick just finds the same
row again. A `waiting_children` task counts toward `max_concurrent_tasks`
and `max_turn_seconds` exactly like `running`/`waiting_human` do (a child
that never finishes does not let its parent wait forever), and
`fn_cancel_session` reaches it the same way too.

Deliberately not in this slice: a single `delegate` call still spawns
exactly one child, so a genuine fan-out to several agents at once takes
several `wait: true` delegate calls across several of the parent's own
turns before the one `await_children`, not one call naming a list of
targets; and there is no dedicated dashboard view of the dependency graph
itself yet — a paused task and its children are visible today the same way
any other task is, through Audit → Sessions/Tasks.

## Schedules

Roadmap item 6: a schedule (Settings → Schedules) runs an agent against a
goal on a recurring interval — each firing calls `fn_create_session` exactly
as if an operator had typed the goal in by hand, so a fired run is an
ordinary session, visible and inspectable the same way any other one is
(Audit → Sessions). Firing is a plain `next_run_at <= now()` poll
(`fn_run_schedules`, called from `fn_pump` alongside `fn_watchdog`/
`fn_dispatch_tasks`) — no `pg_cron` or other external scheduler, and no
state held in worker memory, so a worker or database restart between ticks
loses nothing: the next tick just finds the same due row. A schedule that
missed several intervals (the extension was down, or simply never got a
tick) fires once to catch up, never in a burst — `next_run_at` is always
recomputed as `now() + interval_seconds`, never by walking forward in fixed
steps from where it was.

A schedule's own `name`/`goal` plus its `run_count`/`last_run_at`/
`last_session_id`/`spent_cost_usd` *are* the durable long-term-goal-tracking
record — how many times has this actually been checked on, most recently
when, against which session, how much has it spent — queryable in
PostgreSQL like everything else here, not a separate concept kept anywhere
else. Three independent, optional stop conditions — `max_runs` (a run
budget), `ends_at` (a wall-clock deadline), and `max_cost_usd` (a dollar
budget, below) — are enforced on every tick, not only at create time: a
schedule that reaches any of them is deactivated (`is_active = false`)
rather than fired one run past the limit. `schedules.run_now` fires one
immediately regardless of `next_run_at`, still subject to all three stop
conditions — the closest thing in this slice to a genuinely event-driven
trigger (an operator, or an external system calling the same RPC action, is
the "event").

**Cost budget.** Every successful `'llm'` outbound call has its response
body's own `usage` field parsed (`allgres_private.llm_usage_from_http` —
OpenAI-compatible `usage.prompt_tokens`/`completion_tokens` and Anthropic
`usage.input_tokens`/`output_tokens` are both recognized, normalized to one
shape) and stored on the call itself
(`outbound_calls.prompt_tokens`/`completion_tokens`). Priced against a
manual price sheet an admin maintains in Settings → Model prices
(`allgres_private.llm_model_prices`, one row per provider/model actually
priced — nothing populates this from a live pricing API), the resulting
dollar figure is frozen onto that same call as `cost_usd` at the moment it
completes, so a later price edit can never silently reprice a call that
already happened. A model with no price row leaves `cost_usd` — and every
budget computed from it — `NULL`, never a false `0`: an unpriced model's
spend is invisible to this feature entirely, not silently treated as free.

If the task that call belongs to traces back (via its session's
`schedule_id`, set the moment `fn_run_schedules`/`schedules.run_now` spawns
that session) to a schedule with `max_cost_usd` set, that cost accrues into
the schedule's own `spent_cost_usd` — and crossing `max_cost_usd` deactivates
the schedule immediately, in `fn_complete_outbound` itself, not only at
`fn_run_schedules`' next tick. An hourly schedule must not be able to run
for most of a day past its own budget before anything notices just because
nothing rechecked it until the next scheduled fire.

Deliberately not in this slice: a genuinely event/webhook-triggered
schedule (fired by an external condition, not a timer or a manual call) —
`schedules.run_now` covers the manual case today, a real inbound trigger is
future work. Also out of scope: a *per-agent* or *per-session* cost budget
independent of a schedule (every `outbound_calls.cost_usd` this feature
computes is queryable directly for that today, just not enforced as a stop
condition outside the schedule case above), and any live pricing API
integration — the price sheet is, and is expected to stay, something an
operator types in by hand.
