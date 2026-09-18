# Evaluation-gated self-improvement

Part of the [documentation index](../README.md). See also: [System
agents](system-agents.md) for `self_improve` itself.

Roadmap item 7: every prior slice let `self_improve` (or an operator)
change an agent's policy, but nothing ever recorded whether that change
actually helped. **What this measures is task throughput (the
completed/failed ratio of an agent's own root-level tasks), not semantic
correctness** — a task can finish `completed` having produced a wrong or
useless answer, and nothing here can tell the difference. Read `improved`/
`regressed` as "this policy finishes more (or fewer) of its own tasks than
the one before it," not "this policy is smarter." A real correctness judge
would need task-specific success criteria (something to grade the actual
output against) and is out of scope here — see "Deliberately out of
scope" below.

`agent_recent_success_rate(agent_id, limit=20)` is the coarse version of
that signal: the completed/failed ratio over an agent's most recent
root-level tasks (`parent_task_id IS NULL`), regardless of which policy
version they ran under. It excludes delegated children (a child's own
outcome never blurs the delegating agent's own score) and any session
whose `goal LIKE 'selftest%'`, and returns `NULL` (not `0`) when there is
no evaluable data yet, so a brand new agent is never read as "0% success."
It still backs `v_agent_health`'s "how is this agent doing lately,
overall" column, but an outside review pointed out it is the wrong tool
for judging one specific change: "most recent 20 tasks" can span several
policy versions, so a handful of tasks from just before a change and a
handful from just after can land in the same window and get averaged
together — enough to call a real regression "unchanged," or the reverse.

`allgres_private.agent_success_rate_for_generation(agent_id, generation,
limit=20)` is the fix: every root task is stamped at creation time
(`tasks.policy_generation`) with whichever `policies.generation` was live
when it was queued, and this computes the same completed/failed ratio
scoped to exactly one generation's own tasks. `fn_set_policy` now snapshots
`policy_history.success_rate_at_change` from this (the outgoing
generation's own rate, not a mixed recent window) at the exact moment a
version is replaced. `fn_evaluate_last_change(agent_id, min_samples=5)`
compares the agent's current-generation rate against its immediately
prior generation's rate — both computed fresh from their own isolated
task sets, live, every time this is called, not a frozen snapshot on one
side — and returns one of five verdicts: `improved`, `regressed`,
`unchanged`, `insufficient_data`, or `no_change_recorded_yet` (the agent
has never had a policy change at all). `insufficient_data` fires whenever
either side has fewer than `min_samples` evaluable tasks (default 5, not
just "any data at all") — a single task on either side is not enough to
call a trend, and the response reports `current_sample_size`/
`before_sample_size` alongside the verdict so a caller can see exactly why
judgment was withheld. Right after a change, before the new generation has
run a single task yet, this correctly reports `insufficient_data` — never
a false `unchanged` implying "checked, no difference."

`v_agent_health` is the same permission-gated shape as `v_system_health`,
one row per agent instead of a single aggregate, and `self_improve` is
granted read access to it by default (both at seed time and, for an
existing install, via an unconditional grant so upgrading picks it up
too). `self_improve`'s system prompt now points it at both
`v_agent_health` and `fn_evaluate_last_change` so it can check the outcome
of its own prior proposals before making a new one.

Both are exposed read-only, the same way `policy.history` already is:
`dashboard_rpc` action `agents.evaluate` (wraps `fn_evaluate_last_change`
directly) and the extended `policy.history` output (`success_rate_at_change`
per version). The Agents page's edit modal has a new "Evaluate last
change" button next to History that shows the verdict and both rates, and
the History modal itself now shows each version's `success_rate_at_change`
inline.

Deliberately out of scope: a mechanical block on `self_improve` proposing
a change (e.g. refusing a new proposal until the last one shows
`improved`) — `self_improve`'s stated purpose is token/time cost, not
correctness, and a hard gate on that basis would be enforcing something
this feature was never meant to guarantee. This makes a change's outcome
*evaluable*, not automatically enforced: no automatic rollback on
`regressed` either, only a computed verdict for a human, or a future
`self_improve` turn reading its own history, to act on. Also deferred: a
per-task correctness judge (grading actual output against a task-specific
success criterion, rather than just "did the task finish"), and a real
cost-based signal (tokens or dollars per change, the same deferred item
[Schedules](task-orchestration.md#schedules) above already named) — nothing in this codebase prices a
provider or parses token usage out of a response yet, so a cost dimension
here would only ever compare against a number nothing populates.
