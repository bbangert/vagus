defmodule Vagus.Ingress.Panels do
  @moduledoc """
  Ingress sidebar panel listing + the push-to-Core notification
  (`docs/contract-2026.7-m4b-ingress-watchdog.md` §B4). A plain, process-free
  module — unlike `Vagus.Ingress` (sessions/dynamic ports), there's no state
  to own here: `list/1` reads straight from `Vagus.Addon.State`, and
  `update_hass_panel/2` is a stateless fire-and-forget side effect.

  ## `GET /ingress/panels` (§B4.1)

  `list/1` returns one entry per **installed add-on with `config.ingress ==
  true`** — every ingress-capable add-on, not just ones currently toggled on;
  `"enable"` reflects the per-install `ingress_panel` toggle and is present
  (`false`) even for an ingress add-on whose panel isn't enabled.

  Plus `Vagus.API.AdminPanel`'s synthetic `vagus` entry, which has no add-on
  behind it and so is merged in independently of `Vagus.Addon.State`.

  All four keys (`title`/`icon`/`admin`/`enable`) must be present on every
  entry: `aiohasupervisor` parses this response with a strict model, and one
  missing key fails panel registration for **all** add-ons, not just the
  offending one.

  ## Push to Core (§B4.2/§B4.4)

  `update_hass_panel/2` mirrors the real Supervisor's `Ingress.update_hass_panel`
  naming: `POST` if the add-on's `ingress_panel` is true, `DELETE` otherwise,
  against `api/hassio_push/panel/{slug}` via `Vagus.Core.Client.request/3`.

  Real Supervisor `await`s this push inside the `POST /addons/{slug}/options`
  request (§B4.4 — "the push to Core happens synchronously inside the
  options-handler request"). This emulator deliberately doesn't: the push
  runs in a detached `Task.start/1` by default (`opts[:sync] == true` runs it
  inline instead, for deterministic tests) so a 1GB device's options POST
  never blocks on Core's reachability. This is safe because Core's own POST
  handler **re-fetches the full panel list itself** rather than trusting
  the (empty) push body (§B4.3, "fact 10" in the M4b addendum) — our push is
  purely a "hey, something changed" nudge, never a data carrier, so firing it
  a few milliseconds after the response already went out changes nothing
  observable to Core.

  An unknown slug (no `Vagus.Addon.State` entry) resolves to a DELETE push —
  this is what lets `Vagus.Addon.Manager.uninstall/2` call this *after* the
  `State` entry has already been purged and still get the right verb,
  mirroring upstream forcing `ingress_panel = false` + pushing on uninstall.
  """

  require Logger

  alias Vagus.Addon.State
  alias Vagus.API.AdminPanel
  alias Vagus.Core.Client

  @admin_slug AdminPanel.slug()

  @doc """
  The §B4.1 panels map: `%{slug => %{"title", "icon", "admin", "enable"}}`,
  one entry per installed add-on with `config.ingress == true`, plus
  `Vagus.API.AdminPanel`'s synthetic entry. `panel_title` falls back to the
  add-on's `name` when unset.
  """
  @spec list(GenServer.server()) :: %{String.t() => map()}
  def list(state_server \\ State) do
    state_server
    |> State.list()
    |> Enum.filter(fn %{config: config} -> config.ingress end)
    |> Map.new(fn %{config: config, ingress_panel: ingress_panel} ->
      {config.slug,
       %{
         "title" => config.panel_title || config.name,
         "icon" => config.panel_icon,
         "admin" => config.panel_admin,
         "enable" => ingress_panel
       }}
    end)
    # Merged last, so the reserved slug always resolves to the synthetic
    # panel even if an add-on claims it. Same precedence as
    # `Vagus.Ingress.resolve_token/2` and `Vagus.API.Router`'s
    # `/addons/:slug/info`: an add-on can never shadow `vagus`, in any of
    # the three places the slug is interpreted.
    |> Map.put(AdminPanel.slug(), AdminPanel.panel_entry())
  end

  @doc """
  The §B4.2 push: `POST`/`DELETE` `api/hassio_push/panel/{slug}` on Core,
  depending on `slug`'s current `ingress_panel` setting (`false` for an
  unknown/untracked slug).

  `opts`:

    * `:state` - the `Vagus.Addon.State` server to read `ingress_panel` from
      (default `Vagus.Addon.State`).
    * `:client` - forwarded as `Vagus.Core.Client.request/3`'s `:server` opt
      (default `Vagus.Core.Client`). When omitted *and* the default-named
      client isn't running (isolated unit tests, a host devcontainer with no
      Core wired up), the push is skipped entirely rather than attempted
      against a process that doesn't exist — the same `Process.whereis`
      best-effort style the rest of this codebase's optional side effects
      use. Passing `:client` explicitly (as tests do, pointing at a fixture)
      always attempts the push, regardless of whether the default-named
      client happens to be running.
    * `:sync` - `true` runs the push inline instead of in a detached `Task`
      (default `false`). Production callers keep the default; tests that
      need to observe the push's outcome deterministically pass `true`.

  Always returns `:ok` — a failed/unreachable Core push is logged at
  `warning` and never raised or surfaced to the caller (see moduledoc).
  """
  @spec update_hass_panel(String.t(), keyword()) :: :ok
  def update_hass_panel(slug, opts \\ []) do
    if client_available?(opts) do
      state_server = Keyword.get(opts, :state, State)
      method = push_method(slug, state_server)
      push = fn -> do_push(method, slug, opts) end

      if Keyword.get(opts, :sync, false), do: push.(), else: Task.start(push)
    end

    :ok
  end

  defp client_available?(opts) do
    case Keyword.fetch(opts, :client) do
      {:ok, _client} -> true
      :error -> is_pid(Process.whereis(Client))
    end
  end

  # Defensive: the synthetic panel has no `Vagus.Addon.State` entry, so the
  # clause below would resolve it to a DELETE and un-register our own
  # sidebar panel if anything ever pushed for this slug.
  defp push_method(@admin_slug, _state_server), do: :post

  defp push_method(slug, state_server) do
    case State.get(slug, state_server) do
      {:ok, %{ingress_panel: true}} -> :post
      _not_enabled_or_untracked -> :delete
    end
  end

  defp do_push(method, slug, opts) do
    client = Keyword.get(opts, :client, Client)

    case Client.request(method, "/api/hassio_push/panel/#{slug}", server: client) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status}} ->
        Logger.warning("Vagus.Ingress.Panels: #{method} panel push for #{slug} -> HTTP #{status}")

      {:error, reason} ->
        Logger.warning(
          "Vagus.Ingress.Panels: #{method} panel push for #{slug} failed: #{inspect(reason)}"
        )
    end
  end
end
