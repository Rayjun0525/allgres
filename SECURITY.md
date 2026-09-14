# Security policy

Allgres is early alpha (see README.md's own banner and
[Security model](README.md#security-model)) -- it has not had an external
security audit, and its default configuration (`docker-compose.yml`) is
built for local evaluation, not for serving real traffic. Read
[Security model](README.md#security-model) and
`docker-compose.prod.yml` before running this anywhere reachable by anyone
you don't trust.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for a security vulnerability.

Use GitHub's private vulnerability reporting instead: on
<https://github.com/Rayjun0525/allgres>, go to the **Security** tab ->
**Report a vulnerability**. That opens a private draft advisory visible
only to the maintainer and you, so details, a proof of concept, and a fix
can be discussed before anything is public.

If that's not available for some reason, opening an issue with as few
specifics as possible (just "possible security issue, will share details
privately") and asking for another contact channel is the fallback.

Please include, as far as you're able:

- What component is affected (the SQL sandbox, the SSRF guard, the
  dashboard's own auth/CORS/CSRF handling, secret storage, the RPC
  contract, a specific `dashboard_rpc` action, etc.)
- Steps to reproduce, or a minimal repro against a fresh
  `docker compose up`
- What you'd expect to happen instead, and why the actual behavior is a
  security issue rather than a correctness bug

## Scope

In scope: anything that lets a party without the dashboard token (or
without the permissions their account/agent assignment should carry) read
or change data they shouldn't, execute SQL or make an outbound HTTP
request outside the sandbox/SSRF guard's intended boundary, or escalate
from the `sandbox`/`worker` role toward `allgres_owner` or superuser.

Out of scope (already tracked, not news): anything already named as a
known limitation in README's [Known limitations](README.md#known-limitations)
or in `KNOWN_ISSUES.md` -- reporting one of those is still welcome if you
have a stronger exploit than what's written down, but the gap itself is
already known. Also out of scope: denial of service against your own
self-hosted instance, and social-engineering an operator who already holds
the dashboard token into misusing their own access -- the token *is* the
trust boundary in the default single-operator mode (see
[Exposure](README.md#exposure)).

## What to expect

This project has one maintainer and no SLA. A genuine vulnerability report
will get a response and, once fixed, a mention in `KNOWN_ISSUES.md` and/or
a release note -- credited by name or handle if you'd like, anonymous if
you'd rather not be. There is currently no bug bounty.
