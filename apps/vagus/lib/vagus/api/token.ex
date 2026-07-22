defmodule Vagus.API.Token do
  @moduledoc """
  Resolves and caches the bearer token `Vagus.API.Auth` checks incoming
  requests against.

  Resolution order (first match wins):

    1. `VAGUS_SUPERVISOR_TOKEN` env var — always wins over the persisted
       file, e.g. for one-off overrides without touching disk.
    2. The token persisted at `config :vagus, :token_path` (target:
       `/data/vagus/token`; host: an absolute path under the umbrella root,
       matching the file `scripts/dev-core.sh` itself reads/writes so both
       sides agree on the same secret without any handshake).
    3. If the file doesn't exist yet, a fresh 32-byte token is generated
       (`:crypto.strong_rand_bytes/1`, hex-encoded) and persisted there.

  The resolved token is cached in `:persistent_term` after first read —
  cheap to read repeatedly from any process, and correctly scoped to the
  lifetime of the BEAM instance (a fresh instance re-resolves, picking up
  env var / file changes made between runs).
  """

  @persistent_term_key {__MODULE__, :token}

  @doc "Returns the resolved bearer token, resolving and caching it on first call."
  @spec get() :: String.t()
  def get do
    case :persistent_term.get(@persistent_term_key, nil) do
      nil ->
        token = resolve()
        :persistent_term.put(@persistent_term_key, token)
        token

      token ->
        token
    end
  end

  defp resolve do
    case System.get_env("VAGUS_SUPERVISOR_TOKEN") do
      nil -> read_or_generate(token_path())
      env_token -> env_token
    end
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp read_or_generate(path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      {:error, _reason} -> generate_and_persist(path)
    end
  end

  # path is internal/config-derived, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp generate_and_persist(path) do
    token = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    :ok = File.mkdir_p(Path.dirname(path))
    :ok = File.write(path, token)
    :ok = File.chmod(path, 0o600)
    token
  end

  defp token_path do
    Application.get_env(:vagus, :token_path) ||
      raise "config :vagus, :token_path is not set (expected from config/host.exs or config/target.exs)"
  end
end
