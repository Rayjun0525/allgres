# Memory and semantic search

Part of the [documentation index](../README.md).

## Memory

An agent can emit `{"action":"remember","content":"...","memory_type":
"semantic|episodic|preference|instruction|relationship|working",
"importance":0.0-1.0,"subject_id":"...","expires_in_days":N}` alongside its
other actions. `content` and a valid `memory_type` are the only required
fields; `memory_type` and `importance` default to `semantic`/`0.5`,
`subject_id` is free text (there is no user-accounts system yet — see
[Security model](security.md) — so it can't be tied to a real identity,
only tagged by the agent), and `expires_in_days` is optional.

Every future turn, `fn_next_step` reads that agent's own memories back —
live ones only, ranked by importance then recency, capped at 15 rows and 500
characters each — into a `# memory` block in the same system message that
already carries its policy and permission bounds. Recall is strictly scoped
to `agent_id`: nothing an agent remembers is ever visible to another agent's
own prompt, delegation included. A memory does not need any resource
permission the way `execute_sql` (a view) or `delegate` (a target agent) do
— an agent can only ever write to its own memory, which cannot expand its
privileges or touch anything another agent owns, the same reasoning that
already lets `propose_change`/`await_human` skip a permission grant.

A fixed cap (500 rows per agent) evicts the least important, then oldest,
memories on write, so an agent cannot grow its own prompt context — or the
table — without bound; there is no operator-configurable policy field for
this in the current slice. `fn_watchdog` separately garbage-collects any row
past its `expires_in_days`, though an expired row is already excluded from
recall regardless of whether it has been swept yet.

An operator can also seed or remove a memory directly from the **Memories**
dashboard page (`fn_remember`/`fn_forget`, exposed as `memories.create`/
`memories.remove`) — useful for correcting something an agent got wrong, or
telling it something once rather than waiting for it to learn the fact
itself.

The same page's **Search history** panel (`history.search`) searches past
work, decisions, and failures across three sources at once — an agent's own
explicit memories, a task's `role='error'` log entries, and a completed
session's `final_answer` — and every result links back to the session/task
it came from. It is a plain PostgreSQL text search (`tsvector`/`ILIKE`, the
`simple` config so it works on non-English content too), not a vector
search, and is scoped exactly like `memories.list`: a regular user sees only
their own assigned agents' history, an admin sees everything, and either can
narrow further to one agent or one project.

Deliberately not in this slice: semantic (embedding/vector) search — recall
is importance/recency ranking over structured rows only, no `pgvector`
dependency; an explicit `recall` action for an agent to query beyond what is
already injected automatically; and row-level security on
`agent_memories` — like most of this project's tables, it is gated by a
`SECURITY DEFINER` function's own `agent_id` parameter rather than Postgres
RLS (see [Per-agent roles](security.md#per-agent-roles) for the one place RLS
is actually used today).

## Semantic delegate search

`delegate` has always required an agent to already know the exact
`agent_name` of who to hand a task to. A new `search_agents` action lets
it describe the task instead: register a `purpose='embedding'` provider in
Settings (`kind` must be `openai_compat` — an OpenAI-shaped `/embeddings`
endpoint, real or a local server), and every agent's name + system_prompt
is embedded and kept current automatically whenever it's created or its
prompt changes. `search_agents` embeds the query the same way and ranks
every agent the caller actually holds an `agent` permission for by cosine
similarity — the identical permission check `delegate` itself enforces, so
a search can never surface a name the caller could not actually delegate
to — returning the ranked list as a `function_result` on the next step.

Embeddings are stored as a plain array (`agents.embedding`), never
[pgvector](https://github.com/pgvector/pgvector)'s own `vector` type, so
none of this requires pgvector at all — ranking falls back to an unindexed
but exactly-correct SQL cosine similarity. Installing pgvector
(`CREATE EXTENSION vector;`, entirely the operator's own opt-in step —
allgres never runs it, the same as `pgcrypto`; the Docker image installs
the package so it's available if wanted) only adds an HNSW index for
speed, built and kept in sync with whatever embedding dimension is
actually in use automatically the first time it would help. See
KNOWN_ISSUES.md item 35 for the full mechanism and two real bugs this
found (a missing worker grant, and pgvector's own `sum(vector)` overload
breaking the SQL sandbox's unrelated function allowlist).

## Semantic memory recall

[Memory](#memory)'s automatic every-turn injection stays exactly what it
was — an agent's own live memories, ranked by importance then recency,
capped at 15 rows — because that has to run synchronously while a prompt
is being assembled, and a query embedding is itself an outbound HTTP call
that cannot complete inline. `recall` is the explicit alternative for
"find something specific," reusing the identical embedding infrastructure
[semantic delegate search](#semantic-delegate-search) already built: the
same shape (`{"action":"recall","query":"..."}`), the same queue-then-
continue flow (`outbound_calls` kind `'recall'` instead of `'embedding'`),
the same plain-array-not-pgvector storage, and the same automatic
opportunistic HNSW indexing once pgvector is installed.

Every `agent_memories` row gets its own embedding (`agent_memories.
embedding`/`embedding_model`), generated the moment it's written —
`write_memory`, the one insertion point both the agent's own `remember`
action and the operator-authored `fn_remember`/`memories.create` share —
via the same `embedding_calls` queue agent-identity embeddings already
use, generalized to carry either an agent or a memory as its target.
`allgres_private.rank_memories_by_embedding` then ranks by cosine
similarity, scoped strictly to the calling agent's own memories (`WHERE
agent_id =`, not a cross-agent search — this is semantic search over an
agent's own private store, never another agent's) and excluding anything
already expired, with the same dimension/model mismatch guards
`rank_agents_by_embedding` already enforces so a since-changed embedding
provider can never silently rank across two incomparable vector spaces.

An optional feature's absence is never fatal: `recall` with no
`purpose='embedding'` provider configured is a friendly `continue`, the
same as `search_agents`, and a memory written before one existed simply
stays ineligible for semantic ranking (still fully recalled by importance/
recency) until it is re-embedded.
