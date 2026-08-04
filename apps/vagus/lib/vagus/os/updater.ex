defmodule Vagus.OS.Updater do
  @moduledoc """
  Owner of the real `/os/update` path: supervises
  `NervesGithubUpdater.Supervisor` (the GitHub-releases OTA machinery)
  and adds the pieces the library deliberately doesn't own — the check
  cadence (`Vagus.OS.Updater.Checker`), the `supervisor_update`/`"os"`
  event push, a free-space precheck, and the fresh-check-then-install
  discipline the router relies on.

  Gated exactly like `Vagus.Core.Boot`: an unconditional child of
  `Vagus.Application` whose `start_link/1` returns `:ignore` unless
  `config :vagus, :os_updater` is set (only `config/target.exs` sets it —
  there is no firmware to update on `:host`/test). The public reads below
  stay nil-safe when the updater isn't running (`state/1` on a dead server
  answers an idle-shaped snapshot), so `Vagus.Backend.OS.Nerves` can call
  them unconditionally.

  ## Unsigned-firmware posture

  `verification_required: false` (the library's legacy `:asset_matcher`
  path): authenticity rests on GitHub TLS + account security, integrity
  on fwup's own archive validation + the A/B slot + StartupGuard — a
  corrupt download fails `fwup` apply and the board stays on the active
  slot. Enabling signing later is a TWO-release migration (first ship
  firmware carrying the public key, then flip `verification_required`) —
  never one step.

  ## Fresh-check-then-install

  The library's `install_latest/1` installs whatever `check/1` last
  cached — a stale cache could install a release the feed has since
  replaced. `install/2` therefore always runs a fresh check first and
  refuses (`{:error, {:check_failed, reason}}`) when that check fails,
  rather than falling back to the cache. `check/1` is a cast whose result
  lands asynchronously in `state/1`, so the fresh check is awaited by
  polling: casts and calls from one process are ordered, which makes the
  first `state/1` call block behind the in-flight check (its 5s
  call-timeout is caught by the library, surfacing the synthetic
  `:installing` busy phase) — the poll loop simply waits out the busy
  phases.

  ## Version strings

  Everything is a BARE semver string end to end: the release tag
  (`0.4.0`, no `v` — the library's `VersionCompare` parses tags as
  semver), `nerves_fw_version` (inherits `apps/vagus_platform/mix.exs`
  `@version`), and the `version`/`version_latest` pair `/os/info` serves.
  `update_available?/1` is `Vagus.Version.update_available?/2` — the same
  string inequality Core and add-ons use, no semantic ordering.
  """

  use Supervisor

  alias Vagus.Backend.Host.DiskUsage
  alias Vagus.Backend.OS.FirmwareKV

  @owner_repo "bbangert/vagus"

  # Real mount path, not the /data symlink — a runc bind/rootfs path
  # lesson generalized: keep on-device file plumbing on the real path
  # (see config/target.exs's :addon_data_root comment).
  @download_dir "/root/vagus/firmware"

  # `:installing` is the library's synthetic phase for "a state/1 call
  # timed out because the GenServer is blocked mid-install" — just as
  # busy as the real phases.
  @busy_phases [:checking, :verifying, :downloading, :flashing, :installing]

  # The fresh check in install/2 is one conditional GitHub API call
  # (ETag-cheap); 60s rides out a slow TLS handshake + redirect chain
  # without holding a wedged install attempt open forever.
  @check_settle_timeout_ms 60_000
  @check_poll_ms 500

  # Refuse an install that would squeeze /root below this much headroom
  # after the download — filling the data partition to the brim starves
  # Core/add-on writes (their .storage lives on the same filesystem),
  # which is worse than a refused update.
  @headroom_bytes 64 * 1024 * 1024

  @doc """
  Starts the updater subtree — `:ignore` (no process) unless
  `config :vagus, :os_updater` is truthy (target.exs only).
  """
  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts \\ []) do
    if Application.get_env(:vagus, :os_updater, false) do
      Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {NervesGithubUpdater.Supervisor, updater_opts()},
      Vagus.OS.Updater.Checker
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Assembled here (not config) so the closures resolve live KV state at
  # call time. `download_dir` is immutable for the library's lifetime.
  defp updater_opts do
    [
      owner_repo: @owner_repo,
      verification_required: false,
      asset_matcher: &match_firmware_asset/2,
      channel: :stable,
      target_fn: fn -> FirmwareKV.platform(FirmwareKV.active_slot()) end,
      current_version_fn: fn -> FirmwareKV.version(FirmwareKV.active_slot()) end,
      devpath_fn: fn -> Nerves.Runtime.KV.get("nerves_fw_devpath") end,
      reboot_fn: &Vagus.Host.Shutdown.reboot/0,
      download_dir: @download_dir,
      # Rollback-counter anchor persistence (unused on the unsigned path
      # today, but wiring it now means flipping verification on later
      # doesn't silently run without rollback protection).
      kv_get: &Nerves.Runtime.KV.get/1,
      kv_put: &Nerves.Runtime.KV.put/2
    ]
  end

  @doc """
  The exact-name asset matcher for the legacy (unsigned) install path:
  picks `vagus_<nerves_fw_platform>.fw` from the release's assets —
  the names `.github/workflows/release.yml` uploads.
  """
  @spec match_firmware_asset(String.t(), [map()]) :: {:ok, map()} | {:error, atom()}
  def match_firmware_asset(_tag, assets) do
    name = "vagus_#{FirmwareKV.platform(FirmwareKV.active_slot())}.fw"

    case Enum.find(assets, fn asset -> asset.name == name end) do
      nil -> {:error, :no_asset_for_target}
      asset -> {:ok, asset}
    end
  end

  ## Public reads (nil-safe with the updater not running / never checked)

  @doc """
  The latest release tag the feed advertised, or `nil` before the first
  successful check (and always `nil` on `:host`, where the updater is
  disabled — `state/1` on a dead server answers an idle snapshot).
  """
  @spec version_latest(keyword()) :: String.t() | nil
  def version_latest(opts \\ []) do
    case updater(opts).state().last_release do
      %{tag_name: tag} when is_binary(tag) -> tag
      _other -> nil
    end
  end

  @doc """
  Whether the feed advertises a version differing from the running
  firmware — `Vagus.Version.update_available?/2` string inequality,
  `false` while either side is unknown.
  """
  @spec update_available?(keyword()) :: boolean()
  def update_available?(opts \\ []) do
    current = current_version(opts)
    Vagus.Version.update_available?(current, version_latest(opts))
  end

  @doc "Whether a check or install is in flight (incl. the synthetic `:installing`)."
  @spec busy?(keyword()) :: boolean()
  def busy?(opts \\ []) do
    updater(opts).state().phase in @busy_phases
  end

  @doc """
  Fire-and-forget feed check (a cast; result lands in `state/1`). Hooked
  to the UI's "Check for updates" refresh routes alongside
  `Vagus.Core.Versions.invalidate/1`.
  """
  @spec check_now(keyword()) :: :ok
  def check_now(opts \\ []) do
    updater(opts).check()
  end

  @doc "The library's state snapshot — the router's install poller reads this."
  @spec state(keyword()) :: map()
  def state(opts \\ []), do: updater(opts).state()

  @doc """
  Fresh-check-then-install. `requested_version` mirrors `POST /os/update`'s
  optional body field: the library can only ever install the latest
  release, so any other requested tag is refused with
  `{:error, {:version_mismatch, latest}}` rather than silently installing
  something else.

  Returns `:ok` once the (asynchronous) download → flash → reboot pipeline
  is accepted; progress/terminal state is observable via `state/1`.

  Errors: `:busy` (check/install already in flight), `{:check_failed,
  reason}` (the fresh check errored — never falls back to a stale cache),
  `:no_release_cached` (feed has no release), `:no_asset_for_target`
  (release lacks `vagus_<target>.fw`), `{:version_mismatch, latest}`,
  `{:insufficient_space, needed, free}`.
  """
  @spec install(String.t() | nil, keyword()) :: :ok | {:error, term()}
  def install(requested_version \\ nil, opts \\ []) do
    updater = updater(opts)

    if busy?(opts) do
      {:error, :busy}
    else
      :ok = updater.check()

      with {:ok, release} <- await_check(updater, opts),
           :ok <- validate_requested(requested_version, release.tag_name),
           {:ok, asset} <- match_firmware_asset(release.tag_name, release.assets),
           :ok <- check_free_space(asset, opts) do
        updater.install_latest()
      end
    end
  end

  ## install/2 plumbing

  # Waits for the just-cast check to settle. The cast/call ordering
  # guarantee means the first state() call can't observe the PRE-check
  # idle state — it either blocks behind the check (timing out into the
  # synthetic :installing busy snapshot) or sees :checking.
  defp await_check(updater, opts) do
    timeout_ms = Keyword.get(opts, :settle_timeout_ms, @check_settle_timeout_ms)
    poll_ms = Keyword.get(opts, :poll_ms, @check_poll_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_check(updater, deadline, poll_ms)
  end

  defp poll_check(updater, deadline, poll_ms) do
    state = updater.state()

    cond do
      state.phase in [:checking, :installing] ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :busy}
        else
          Process.sleep(poll_ms)
          poll_check(updater, deadline, poll_ms)
        end

      state.phase == :error ->
        {:error, {:check_failed, state.last_error}}

      is_nil(state.last_release) ->
        {:error, :no_release_cached}

      true ->
        {:ok, state.last_release}
    end
  end

  defp validate_requested(nil, _latest), do: :ok
  defp validate_requested(version, version), do: :ok
  defp validate_requested(_version, latest), do: {:error, {:version_mismatch, latest}}

  # 2.3: the matched asset's size (from the release's own asset metadata —
  # no manifest on the unsigned path) vs the download filesystem's free
  # bytes. Refusing here is honest and cheap; letting the download fill
  # /root would starve Core/add-on .storage writes on the same filesystem.
  defp check_free_space(asset, opts) do
    needed = Map.get(asset, :size, 0) + @headroom_bytes
    free = free_bytes(opts)

    if free >= needed do
      :ok
    else
      {:error, {:insufficient_space, needed, free}}
    end
  end

  defp free_bytes(opts) do
    case Keyword.get(opts, :free_bytes_fn) do
      fun when is_function(fun, 0) ->
        fun.()

      nil ->
        # The library's Updater.init already mkdir_p!'s the download dir,
        # and install/2 can't reach this line unless that GenServer is up
        # — but `df` on a missing path reads as {0, 0} free (permanently
        # blocking updates as :insufficient_space), so don't lean on that
        # ordering invariant from another module (Copilot, PR #4).
        _ = File.mkdir_p(@download_dir)
        {_total, free} = DiskUsage.usage_bytes(@download_dir)
        free
    end
  end

  defp current_version(opts) do
    case Keyword.get(opts, :current_version_fn) do
      fun when is_function(fun, 0) -> fun.()
      nil -> FirmwareKV.version(FirmwareKV.active_slot())
    end
  end

  # The library-module seam (`:updater` opt / app env) — tests stub the
  # whole `check/0`+`state/0`+`install_latest/0` module boundary instead
  # of starting the library GenServer.
  defp updater(opts) do
    Keyword.get(
      opts,
      :updater,
      Application.get_env(:vagus, :os_updater_mod, NervesGithubUpdater.Updater)
    )
  end
end
