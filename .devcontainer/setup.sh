#!/usr/bin/env bash
set -euo pipefail

# Activate mise in interactive shells (must happen here, after devcontainer
# features like common-utils have finished writing ~/.bashrc / ~/.zshrc)
echo 'eval "$(mise activate bash)"' >> ~/.bashrc
echo 'eval "$(mise activate zsh)"'  >> ~/.zshrc

mise install

# Export tool paths for the rest of this script (mise activate relies on
# prompt hooks which don't fire in non-interactive scripts)
eval "$(mise env)"
mix local.hex --force
mix local.rebar --force
mix archive.install hex nerves_bootstrap --force
mix deps.get
