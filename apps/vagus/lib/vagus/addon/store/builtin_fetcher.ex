defmodule Vagus.Addon.Store.BuiltinFetcher do
  @moduledoc """
  A `Vagus.Addon.Store` fetcher that injects Vagus's built-in "virtual add-ons"
  (M5) into the catalog alongside the git-backed repositories.

  The store fetcher seam is duck-typed (`fetch/1` → `{:ok, [{path, content}]}` |
  `{:error, term}`), so this module needs no `Store` changes: it recognises a
  repository marked `%{builtin: :mqtt}` and returns an embedded `config.json`
  for the native mqttx broker; every other repository is delegated verbatim to
  `Vagus.Addon.Store.HTTPFetcher`. Wire it in by setting the store's `:fetcher`
  to this module and adding `%{slug: "core", builtin: :mqtt}` to
  `:store_repositories` — the store slug is then `core_mqtt` (matching the
  `core_mosquitto` convention it replaces as the default MQTT provider at P5).

  The embedded config declares `backend: native` (→ `Vagus.Addon.Backend.Native`)
  and a placeholder `image:` (never pulled — `Native.pull/1` is a no-op — but
  present so the manager's `image_ref/2` doesn't raise on a nil image).
  """

  @builtin %{
    mqtt: %{
      "name" => "MQTT Broker (native)",
      "version" => "1.0.0",
      "slug" => "mqtt",
      "description" =>
        "In-process MQTT 3.1.1 broker (mqttx) — a native virtual add-on, no container.",
      "arch" => ["amd64", "aarch64", "armv7", "armhf", "i386"],
      "backend" => "native",
      "image" => "local/core_mqtt",
      "startup" => "services",
      "boot" => "auto",
      "init" => false,
      "host_network" => false,
      "ports" => %{"1883/tcp" => 1883},
      "services" => ["mqtt:provide"],
      "discovery" => ["mqtt"],
      "auth_api" => true,
      "docker_api" => false,
      "options" => %{},
      "schema" => %{}
    }
  }

  @doc "Returns the embedded files for a builtin repo, else delegates to the HTTP fetcher."
  @spec fetch(map()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def fetch(%{builtin: which}) when is_map_key(@builtin, which) do
    {:ok, [{"#{which}/config.json", Jason.encode!(@builtin[which])}]}
  end

  def fetch(repo), do: Vagus.Addon.Store.HTTPFetcher.fetch(repo)

  @doc "The raw embedded config map for a builtin key (exposed for tests)."
  @spec config(atom()) :: map() | nil
  def config(which), do: Map.get(@builtin, which)
end
