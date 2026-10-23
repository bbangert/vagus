# Agent images

- `agent-base` — Claude Code (native installer) plus the BEAM toolchain, built `FROM` a `hexpm/elixir` tag.
- `agent-orchestrator` — the base plus the orchestrator entrypoint, loop, and `vagus` helper. Its `BASE` build arg is the base image ref.

Both are `linux/arm64` only and published to `ghcr.io/bbangert/vagus-agent-base` and `ghcr.io/bbangert/vagus-agent-orchestrator`. Boards only build thin per-task layers on top.

## Publishing

Push a tag `images-vX.Y.Z` (publishes `X.Y.Z`, `sha-<short>` and `latest`), or run the `images` workflow manually with a `tag` input (publishes that tag and `sha-<short>`, never `latest`).

## Bumping Claude Code

Edit `ARG CLAUDE_VERSION` in `images/agent-base/Containerfile`, confirm the native installer offers that version, then tag a new `images-v*`.

## Bumping the BEAM

The `BEAM_IMAGE` build arg (a `hexpm/elixir` tag) must match the OTP and Elixir pinned in `.github/workflows/release.yml` (`OTP_VERSION`, `ELIXIR_VERSION`).

## Local test builds

```sh
docker build --platform linux/arm64 -t agent-base images/agent-base   # needs QEMU/binfmt
docker build --platform linux/arm64 --build-arg BASE=agent-base -t agent-orchestrator images/agent-orchestrator

# directly on a board
podman build --network=host --platform linux/arm64 -t agent-base images/agent-base
```

## Pulling on a board

```sh
podman pull ghcr.io/bbangert/vagus-agent-orchestrator:<tag>
```
