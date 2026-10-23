# Agent images

- `agent-base` — Claude Code (native installer) plus the BEAM toolchain, built `FROM` a `hexpm/elixir` tag.
- `agent-orchestrator` — the base plus the orchestrator entrypoint, loop, and the `vagus` and `worker-config` helpers. Its `BASE` build arg is the base image ref.

Both are `linux/arm64` only and published to `ghcr.io/bbangert/vagus-agent-base` and `ghcr.io/bbangert/vagus-agent-orchestrator`. Boards only build thin per-task layers on top.

## Size

The budget is 2 GB. Measured: the base is 739 MB as docker reports it and 752 MB as podman reports it on the board; the orchestrator adds about 16 KB.

## Publishing

Push a tag `images-vX.Y.Z` (publishes `X.Y.Z`, `sha-<short>` and `latest`), or run the `images` workflow manually with a `tag` input (publishes that tag and `sha-<short>`, never `latest`).

## Bumping Claude Code

Edit `ARG CLAUDE_VERSION` in `images/agent-base/Containerfile`, confirm the native installer offers that version, then tag a new `images-v*`.

## Python pins

`agent-base/requirements.txt` pins every Python dependency except `edlclient`. Regenerate it from a built image: `docker run --rm vagus-agent-base:<tag> /opt/venv/bin/pip freeze | grep -v '^edlclient'`.

## Bumping the BEAM

The `BEAM_IMAGE` build arg (a `hexpm/elixir` tag) must match the OTP and Elixir pinned in `.github/workflows/release.yml` (`OTP_VERSION`, `ELIXIR_VERSION`).

The match is by OTP release, not erts patch: hexpm's OTP 29.0.3 ships erts 17.0.3 while the board runs erts 17.0.6. Distribution only needs the same major.

## Local test builds

```sh
docker build --platform linux/arm64 -t agent-base images/agent-base   # needs QEMU/binfmt
docker build --platform linux/arm64 --build-arg BASE=agent-base -t agent-orchestrator images/agent-orchestrator

# directly on a board
podman build --network=host --platform linux/arm64 -t agent-base images/agent-base
```

## Pulling on a board

GHCR creates a package private on its first push. Make `vagus-agent-base` and `vagus-agent-orchestrator` public once in each package's settings, or a board's `podman pull` needs a login.

```sh
podman pull ghcr.io/bbangert/vagus-agent-orchestrator:<tag>
```
