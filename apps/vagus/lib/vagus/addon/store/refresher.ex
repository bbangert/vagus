defmodule Vagus.Addon.Store.Refresher do
  @moduledoc """
  Populates the add-on store once, shortly after boot.

  `Vagus.Addon.Store` starts with an empty catalog and, before this existed,
  `POST /store/reload` was the **only** thing in the tree that ever filled it
  (`Store.reload/1` had exactly one caller, in the router). So every reboot
  left the add-on store blank — no add-ons, and no icons, since
  `Store.asset_lookup/2` resolves through the catalog and answers `:error`
  until it is populated. Retained assets on disk didn't help: the bytes were
  there, nothing could name them. It looked exactly like the asset feature
  having broken again.

  Upstream doesn't need this because its store *is* a git checkout on disk
  that `StoreData.update()` reads at startup, no network involved. Vagus
  holds no checkout, so re-fetching is our equivalent of loading it.

  ## What it deliberately doesn't do

  **It doesn't run on a schedule.** One refresh, at boot, then it idles. A
  periodic re-fetch would pull every repository's archive on a timer forever
  (~2.5 MB and a ~42 MB memory dip for the four defaults, measured on the
  rpi3) to fix staleness nobody reported; `POST /store/reload` and the
  frontend's reload button already exist for that.

  **It doesn't block boot.** The first attempt is delayed and runs in this
  process, so a slow or absent network delays the store, not the supervision
  tree — Core, the engine and add-on boot all come up regardless.

  ## Retry

  A device that boots without a network yet — the normal case, since WiFi
  association and DHCP race the supervision tree — gets an empty catalog on
  the first attempt. `Store.reload/1` reports that as `{:ok, 0}` rather than
  an error (it logs each repository's failure and skips it), so **an empty
  catalog is the retry signal**, not a return value. Backoff is capped and
  the attempts are finite: a device genuinely offline shouldn't re-attempt
  forever, and one that is merely slow has minutes of grace.

  Gated by `config :vagus, :store_boot_refresh`, so `:host` and `:test` never
  reach out to github and `start_link/1` returns `:ignore` — the same
  convention `Vagus.Addon.BootStarter` uses.
  """

  use GenServer

  require Logger

  alias Vagus.Addon.Store

  # Long enough that VintageNet has usually associated and DHCP has landed,
  # short enough that the store is there before anyone opens the page.
  @initial_delay_ms 10_000
  @backoff_ms [30_000, 60_000, 120_000, 300_000]

  def start_link(opts \\ []) do
    if enabled?() or Keyword.get(opts, :force, false) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  defp enabled?, do: Application.get_env(:vagus, :store_boot_refresh, false) == true

  @impl GenServer
  def init(opts) do
    delay = Keyword.get(opts, :initial_delay_ms, @initial_delay_ms)
    backoff = Keyword.get(opts, :backoff_ms, @backoff_ms)
    Process.send_after(self(), :refresh, delay)
    {:ok, %{store: Keyword.get(opts, :store, Store), backoff: backoff}}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    {:noreply, attempt(state)}
  end

  defp attempt(state) do
    case Store.reload(state.store) do
      {:ok, 0} -> retry(state)
      {:ok, count} -> done(state, count)
    end
  rescue
    # `reload/1` shouldn't raise, but a boot-time helper that takes the
    # supervision tree down with it because github returned something odd
    # would be a worse bug than a stale store.
    error ->
      # With the stacktrace: this branch exists for the *unexpected*, and a
      # bare message would leave a boot-time failure on a device with no
      # attached console essentially undiagnosable.
      Logger.warning(
        "Vagus.Addon.Store.Refresher: reload raised\n" <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      retry(state)
  catch
    # `reload/1` opens with a `GenServer.call` to the store, so a device busy
    # enough to blow the 5s default exits rather than raising — and an exit
    # skips `rescue` entirely. Letting it crash would work (the supervisor
    # restarts us) but throws away the backoff and restarts the initial delay,
    # so a loaded boot would retry *sooner* and add load. Retry in place.
    :exit, reason ->
      Logger.warning(
        "Vagus.Addon.Store.Refresher: reload exited #{inspect(reason)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      retry(state)
  end

  defp done(state, count) do
    Logger.info("Vagus.Addon.Store.Refresher: store populated with #{count} add-on(s)")
    %{state | backoff: []}
  end

  defp retry(%{backoff: []} = state) do
    Logger.warning(
      "Vagus.Addon.Store.Refresher: store still empty and out of retries — " <>
        "POST /store/reload once the network is up"
    )

    state
  end

  defp retry(%{backoff: [delay | rest]} = state) do
    Logger.info("Vagus.Addon.Store.Refresher: store empty, retrying in #{div(delay, 1000)}s")
    Process.send_after(self(), :refresh, delay)
    %{state | backoff: rest}
  end
end
