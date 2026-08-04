#!/usr/bin/env bash
set -euo pipefail

# Activate mise in interactive shells (must happen here, after devcontainer
# features like common-utils have finished writing ~/.bashrc / ~/.zshrc)
echo 'eval "$(mise activate bash)"' >> ~/.bashrc
echo 'eval "$(mise activate zsh)"'  >> ~/.zshrc

# oh-my-zsh's interactive update prompt has no business in a devcontainer
echo "zstyle ':omz:update' mode disabled" >> ~/.zshrc

mise install

# A GLOBAL default (not just the project .mise.toml) is required for Nerves
# system (Buildroot) rebuilds: post-createfs.sh runs `mix generate_fwup_conf`
# from the system dir, which has no .mise.toml — without a global fallback the
# mise shim fails with "No version is set for shim: mix" and the image build
# dies at target-post-image.
mise settings set experimental true
mise use -g erlang@29.0.3 elixir@1.20.2-otp-29

# Export tool paths for the rest of this script (mise activate relies on
# prompt hooks which don't fire in non-interactive scripts)
eval "$(mise env)"
mix local.hex --force
mix local.rebar --force
mix archive.install hex nerves_bootstrap --force
mix deps.get
