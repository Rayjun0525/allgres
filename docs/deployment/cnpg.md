# CNPG (CloudNativePG)

Part of the [documentation index](../../README.md). See also the main
[README's Quick start](../../README.md#quick-start) for the condensed version.

CNPG doesn't take a full custom Postgres image the way plain Docker does
(see [Docker install, in detail](docker.md)) — its own operand images
(`ghcr.io/cloudnative-pg/postgresql:*`) are what actually run, and building
a whole separate one just to add allgres would mean keeping that image in
sync with CNPG's own releases forever. Instead, `cnpg/Dockerfile` builds
allgres as its own small **extension image** — just `allgres.so` and its
`.control`/`.sql` files, nothing else — using CNPG's [Image Volume
Extensions](https://cloudnative-pg.io) mechanism: the official operand
image runs unmodified, and Kubernetes mounts this image's files read-only
at `/extensions/allgres` alongside it.

This needs PostgreSQL 18+ (the mechanism relies on a `postgresql`-conf-
`extension_control_path`-style GUC CNPG contributed upstream for exactly
this, only there from PG18 on) and Kubernetes 1.33+ (with the `ImageVolume`
feature gate enabled manually on 1.33–1.34; default-on from 1.35) running
on a **containerd 2.1+ or CRI-O 1.31+** node specifically — confirmed live,
Rancher Desktop's `dockerd` (moby) container engine does not support
`ImageVolume` at all and fails the mount with "invalid volume
specification"; switch Rancher Desktop's engine to containerd (Preferences
→ Container Engine) if you hit that. Also needs the CNPG operator itself
already installed on the target cluster — `Cluster`/`Database` are CRDs
it registers, so applying `cnpg/cluster-example.yaml` against a cluster
without it fails with "no matches for kind Cluster ... ensure CRDs are
installed first" (confirmed live too). See that file's own header comment
for the one-line Helm install if you don't already have it running.

A pre-built image is published to GHCR the same way the plain-Docker image
is (`.github/workflows/publish-image.yml`): `:main` on every push to
main, plus a real version tag and `:latest` once one is actually pushed
(no version has been tagged yet as of this writing, so use `:main` for
now):

```bash
docker pull ghcr.io/rayjun0525/allgres-cnpg-ext:main
```

Use that directly as `cnpg/cluster-example.yaml`'s `image.reference` and
skip building anything yourself. A personal build pushed to your own GHCR
namespace defaults to **private** — Kubernetes pulling it anonymously
fails with `403 Forbidden` (confirmed live) unless you make that package
public yourself or configure an image pull secret; using the
project-published image above avoids that entirely. To build it yourself
instead (a fork, a local change to try before it's tagged):

```bash
# Run from the repo root -- the build context (the trailing `.`) must be
# the whole repo (Cargo.toml, Cargo.lock, src/, sql/), not the cnpg/
# directory itself. Building with cnpg/ as the context (e.g. running this
# from inside cnpg/) fails immediately with a clear "Cargo.toml not found"
# error -- confirmed live, this is the one mistake real testing against
# this Dockerfile actually hit.
docker build -t ghcr.io/you/allgres:0.1.0 -f cnpg/Dockerfile .
docker push ghcr.io/you/allgres:0.1.0
```

`cnpg/cluster-example.yaml` wires the built image into a real `Cluster`:
`.spec.postgresql.extensions` mounts it (and alone is not enough —
`shared_preload_libraries` in the same `postgresql` block is still
required separately, since allgres registers two background workers at
preload time, which the image-volume mechanism doesn't provide on its
own), and a companion `Database` CR is what actually runs `CREATE
EXTENSION allgres;` once CNPG reconciles it. Read that file's own header
comment for what each field does before applying it.

Not verified end to end against a real running cluster as of this
writing — no Kubernetes cluster was available in the environment this was
built in. The image build itself has since been confirmed by a real test:
the assumption that the base image's apt sources carry
`postgresql-server-dev-${PG_MAJOR}` the same way they carry the
`postgresql-${PG_MAJOR}` packages CNPG's own extension images (e.g.
`pgvector`) install from there held up fine; the one real mistake that
build hit was passing the wrong build context (see the `docker build`
block above), now caught early by `cnpg/Dockerfile`'s own check instead of
surfacing as a confusing `cargo-pgrx` error.
