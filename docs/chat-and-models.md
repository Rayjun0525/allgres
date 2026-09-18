# Model configuration and chat

Part of the [documentation index](../README.md).

## Model configuration and conversations

A fresh agent's `llm_config` starts empty — `{}` — whether it was just
created or is the seeded `analyst` demo agent. Nothing runs until an
operator explicitly picks a provider and model; there is no fallback
provider or model name baked in anywhere, so an agent with nothing
configured fails closed with a clear error (`agent has no llm_config.provider
configured`) instead of quietly reaching a real endpoint.

Providers are managed from **Settings**: `provider.create`
(`fn_create_provider`) adds a new one (name, kind, base URL, an optional API
key, and whether it may point at a loopback/private-network address) — not
just the five seeded ones (`xai`, `openai`, `anthropic`, `ollama`,
`openai_compat`) — and `provider.update` (`fn_set_provider`) edits an
existing one, including OAuth fields and connecting via the OAuth flow (see
[Secrets at rest](security.md#secrets-at-rest)). In the agent editor, Provider is a dropdown populated from
currently-enabled providers, not a free-text field an agent could be
pointed at a nonexistent name with; Model stays free text, since one
provider can host many model names, but every Model field (agent editor,
bulk-apply, model prices) offers real fetched names through a `<datalist>`
once a provider has been probed at least once.

**Test connection** (`providers.probe_start`/`providers.probe_status`,
`fn_provider_probe_start`/`fn_claim_provider_probe`/
`fn_complete_provider_probe`) queues a plain `GET {base_url}/models`
(`/v1/models` for an `anthropic`-kind provider) through the same runtime
worker HTTP pool as everything else, for any provider kind, not just
OAuth -- `is_enabled` only ever meant "an operator turned this on," never
"this endpoint actually answers with the stored credential," and an
operator previously had no way to tell the two apart short of running an
agent turn and watching it fail. A 2xx response is stored as
`last_probe_status='ok'` (the Settings list's Status column reflects this,
not just `is_enabled`) and its body -- OpenAI, xAI, and Anthropic's
`/models`/`/v1/models` all return the same `{"data":[{"id":...}]}` shape --
becomes `available_models`, which is exactly what backs the datalist above.
An error is stored as `last_probe_status='error'` with the response body
(or a transport error, e.g. a TLS failure) as `last_probe_error`, and never
overwrites a previously-fetched model list.

A session is no longer a single one-shot exchange. `fn_continue_session`
adds a follow-up message to an existing session — a new task in the same
session, sharing its `agent_id` — and `fn_next_step` assembles the full
conversation for it: every root-level task's log in that session, in
chronological order, not just the one task currently running. A delegated
sub-agent task (`parent_task_id` set — see `delegate` in [The SQL
sandbox](sql-sandbox.md)) stays scoped to only its own log, so a sub-agent's turn
never sees the parent conversation, or a sibling delegate's, just because
they share a `session_id`. A session that already finished is reopened
(`status` back to `open`) by a new message, the same way a chat thread
resumes when someone replies to it; sending a second message while an
earlier turn in the same session is still in flight is rejected outright
rather than racing it. Wired into `dashboard_rpc` as `sessions.continue`.

A real login gates the dashboard on top of the token above, not instead of
it: the token still decides whether a browser reaches the HTTP surface at
all, login decides who, having reached it, is using it. An **admin**
account sees every existing page plus **Users** (create an account,
activate/deactivate it, change its role, and manage which agents it can
reach), **Chat**, and **Messenger**. A **user** account sees only three
pages: **Chat** (a plain, continuing 1:1 conversation with one of their
assigned agents at a time — `fn_chat_send`/`fn_chat_history`, one ongoing
session per (user, agent) pair, resumed via `fn_continue_session` above),
**Messenger** (a Slack-style shared channel — a plain post is just stored;
a post containing `@agent_name` additionally routes that message to the
agent the same way Chat would, sharing the same conversation rather than
starting a second, divergent one — `fn_messenger_post`/`messenger.list`),
and **My Agents** (their assigned agents, each with an inline Provider/
Model editor — `fn_set_my_model` — never the full agent editor's
prompt/budget/permission fields). Chat's own General and Project modes now
carry that same inline Provider/Model editor above the message thread --
General for the seeded `general` agent, Project for whichever agent that
project is bound to -- so switching model/provider no longer means
leaving the conversation for My Agents first; Messenger has no picker,
since an `@mention` can route to any of several agents. Which agents a regular user can reach at
all is an explicit allow-list (`allgres_private.user_agent_assignments`,
managed by an admin from the Users page), not everything minus a
block-list. See KNOWN_ISSUES.md, item 30, for what this deliberately does
not change: the pre-existing shared-token `dashboard_rpc` surface (agent
CRUD, permissions, providers, the SQL sandbox allowlist) is untouched and
still reachable by anyone holding that one token, same as every version
before this — login adds a second, narrower identity layer for chat/
messenger/my-model specifically, not a retrofit of the first one (that
remains KNOWN_ISSUES.md, item 10).

## Chat: General, Messenger, and Project modes

The Chat page is one page with three mode buttons, not three separate nav
entries: **General** (a plain, continuing 1:1 conversation — unchanged from
before), **Messenger** (the Slack-style shared channel — unchanged, now
also delivering to every agent a post `@mentions`, in text order, when more
than one is addressed), and **Project** — a project (Settings/Projects,
admin-managed) may be bound to one agent with a `preset_prompt` appended
after that agent's own system prompt (`fn_next_step`), giving it a focused,
reusable context (e.g. "only ever answer about the Seoul region") without
touching the agent's own policy. Project mode has its own continuing
session per (user, project) pair (`user_project_chat_sessions`,
`fn_project_chat_send`/`fn_project_chat_history`) — deliberately separate
from that same agent's General-mode conversation, so a project's preset
context never leaks into a plain chat with the same agent or vice versa.
