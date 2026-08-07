defmodule Vagus.Provisioner do
  @moduledoc """
  First-boot provisioning (issue #40): flash → power → network →
  `http://board/` shows the HA onboarding wizard (`:8123` 307-redirects there
  during onboarding), zero console commands.
  Runs an ordered, idempotent list of steps — today `[:expand_data,
  :provision_core]` — once per boot, retrying whatever isn't ready yet.

  ## The 4Kn prohibition

  `fwup`'s `gpt_write()` is 512-LBA-only. Running the `expand-data` fwup task
  on a disk whose logical block size isn't 512 bytes (the UFS-backed Q6A
  reports 4096) writes a GPT built for the wrong sector size and CORRUPTS
  it. The sector gate in `:expand_data` below is therefore mandatory, not an
  optimization — it is the only thing standing between this module and a
  bricked board. 4Kn/UFS images are generation-time sized to their target
  disk anyway, so there is genuinely nothing to expand there; skipping is
  correct, not just safe.

  ## The p5-data layout assumption

  `:expand_data` assumes the data partition is `<rootdisk>p5` — true on the
  Q6A, but not universal: rpi3_64 mounts `/root` from `mmcblk0p7`, and its
  p5 is an unrelated 133 MiB partition. The tail-size math above is only
  meaningful on p5-data layouts; run it against the wrong partition and,
  had rpi3_64's `ops.fw` ever grown an `expand-data` task, the GPT rewrite
  would have eaten p6/p7 instead. The data-partition identity gate at the
  top of `expand_data/1` checks `/root`'s actual mount source against the
  assumed `<rootdisk>p5` before the unconditional `resize2fs` pass or the
  sector/tail gates run at all — on a layout mismatch, the whole step is a
  logged no-op.

  ## Ordering: expand before Core

  `:expand_data` must run (and complete, across the reboot it triggers)
  before `:provision_core`. The HA Core image pull is ~2 GB, and an
  unexpanded `/data` is 512 MiB — too small to hold it. Attempting the pull
  first produces a confusing `{:error, {:pull, ...}}` with no obvious link
  back to disk space. Expanding first means Core provisioning always has
  room.

  ## StartupGuard safety

  `init/1` returns immediately with `{:continue, :run}` — no blocking work
  runs before the process is alive and supervised, mirroring
  `Vagus.Core.Boot`. All provisioning happens post-init, message-driven.
  Post-v0.3.1 flashes boot with `nerves_fw_validated=1` already set (the
  StartupGuard fix), so the guard passes in seconds and the `:expand_data`
  reboot can never race it into a reboot-cycle.

  ## Gate + lifecycle

  Gated by `config :vagus, :first_boot_provision`, read at `start_link/1`
  time (not compile time) — same convention as `Vagus.Core.Boot`. `:host`
  and `mix test` never enable it; `start_link/1` returns `:ignore` rather
  than starting a GenServer with nothing to do.

  ## Crash isolation (issue #45)

  This GenServer is a direct child of `Vagus.Supervisor` (`one_for_one`,
  a small restart budget) sitting next to the engine, HA Core, and the API
  — an instant crash-loop here exhausts that budget and takes the whole
  `:vagus` app down with it, not just first-boot provisioning. Device-verified:
  `resize2fs` isn't shipped on rpi3_64, and `System.cmd/3` doesn't return a
  nonzero-status tuple for a missing binary — it *raises* `ErlangError`
  (`:enoent`), which bypassed every `{output, status}` clause below and took
  the app down on first boot. Two independent guards close this off: `cmd`'s
  default implementation rescues that raise into a fake exit-127 tuple, so a
  missing/unusable host binary degrades through the same log-and-skip path
  as a real nonzero exit; and `run_steps/2` rescues/catches around each step
  individually, so a bug anywhere in one step (`:expand_data` say) can never
  cost the others their turn (`:provision_core` still runs) or the process
  its life. The guarantee doesn't end at that synchronous pass: once
  `:provision_core` goes `:async`, the `handle_info/2` continuation
  (`:await_engine`'s ping, `:await_internet`'s connection check,
  `:attempt_update`'s update/start/await-healthy chain) runs through
  `safe_async/3`, the same rescue/catch shape — a raise anywhere in that
  chain abandons first-boot provisioning for this boot (no reschedule)
  instead of crash-looping the GenServer the next time `handle_info`
  replays the same message and hits the same raise. A first-boot
  convenience must never be able to fight its way into taking HA offline.
  """

  use GenServer

  require Logger

  @engine_interval 5_000
  @net_interval 5_000
  @retry_base 30_000
  @retry_cap 600_000

  @rootdisk "/dev/rootdisk0"
  @ops_fw "/usr/share/fwup/ops.fw"
  @sysfs_root "/sys"
  @mounts_path "/proc/mounts"

  # fwup's expand-data task is worth running only if there's a meaningful
  # amount of unpartitioned tail left on the disk; below this, treat the
  # partition as already expanded (idempotency — after a successful expand
  # the tail is gone, so this is also what makes a second pass a no-op).
  @tail_threshold_bytes 1_073_741_824

  @steps [:expand_data, :provision_core]

  @doc """
  Starts the first-boot provisioning GenServer — `:ignore` (no process)
  unless `config :vagus, :first_boot_provision` is truthy.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    if Application.get_env(:vagus, :first_boot_provision, false) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @impl GenServer
  def init(opts) do
    state = %{
      cmd: Keyword.get(opts, :cmd, &default_cmd/2),
      # On the expand-data first-boot path, no Core/add-ons are installed yet
      # in practice, so the facade's stop stages no-op fast — routed through
      # it anyway to keep the "no direct Nerves.Runtime reboot callers"
      # invariant (issue #39).
      reboot: Keyword.get(opts, :reboot, &Vagus.Host.Shutdown.reboot/0),
      sysfs_root: Keyword.get(opts, :sysfs_root, @sysfs_root),
      rootdisk: Keyword.get(opts, :rootdisk, @rootdisk),
      ops_fw: Keyword.get(opts, :ops_fw, @ops_fw),
      mounts_path: Keyword.get(opts, :mounts_path, @mounts_path),
      ping: Keyword.get(opts, :ping, &default_ping/0),
      connection: Keyword.get(opts, :connection, &default_connection/0),
      installed: Keyword.get(opts, :installed, &default_installed/0),
      update: Keyword.get(opts, :update, &default_update/0),
      start: Keyword.get(opts, :start, &default_start/0),
      await_healthy: Keyword.get(opts, :await_healthy, &default_await_healthy/0),
      engine_interval: Keyword.get(opts, :engine_interval, @engine_interval),
      net_interval: Keyword.get(opts, :net_interval, @net_interval),
      retry_base: Keyword.get(opts, :retry_base, @retry_base),
      retry_cap: Keyword.get(opts, :retry_cap, @retry_cap),
      steps: Keyword.get(opts, :steps, @steps),
      # Injectable like every other seam above — mainly so tests can make a
      # step return something other than `:ok | :halt | :async` directly,
      # to exercise `safe_run_step/2`'s normalization without needing a real
      # step to misbehave.
      run_step: Keyword.get(opts, :run_step, &default_run_step/2),
      retry_attempt: 0
    }

    {:ok, state, {:continue, :run}}
  end

  @impl GenServer
  def handle_continue(:run, state), do: {:noreply, run_steps(state.steps, state)}

  @impl GenServer
  def handle_info(:await_engine, state) do
    {:noreply, safe_async(:await_engine, state, &do_await_engine/1)}
  end

  def handle_info(:await_internet, state) do
    {:noreply, safe_async(:await_internet, state, &do_await_internet/1)}
  end

  def handle_info(:attempt_update, state) do
    {:noreply, safe_async(:attempt_update, state, &attempt_update/1)}
  end

  defp do_await_engine(state) do
    case state.ping.() do
      :ok ->
        Logger.info("Vagus.Provisioner: engine ready — awaiting internet connectivity")
        send(self(), :await_internet)

      {:error, _reason} ->
        Process.send_after(self(), :await_engine, state.engine_interval)
    end

    state
  end

  defp do_await_internet(state) do
    case state.connection.() do
      :internet ->
        Logger.info("Vagus.Provisioner: internet reachable — installing HA Core")
        send(self(), :attempt_update)

      _not_yet ->
        Process.send_after(self(), :await_internet, state.net_interval)
    end

    state
  end

  # Extends the #45 crash-isolation guarantee past the synchronous step pass
  # into the async continuation: once `:provision_core` goes `:async`, these
  # `handle_info/2` handlers call injected/side-effecting fns
  # (ping/connection/update/start/await_healthy) with no supervisor between
  # them and the GenServer — an unguarded raise here would crash-loop it
  # exactly like the original bug (the next `handle_info` for the same
  # message hits the same raise, burning the restart budget). A crash
  # abandons first-boot provisioning for this boot with NO reschedule —
  # retrying the same crash on a timer is just a slower crash-loop; the
  # next real boot gets a clean attempt instead.
  defp safe_async(label, state, fun) do
    fun.(state)
  rescue
    exception ->
      Logger.error(
        "Vagus.Provisioner: #{inspect(label)} crashed (" <>
          Exception.format(:error, exception, __STACKTRACE__) <>
          ") — abandoning first-boot provisioning for this boot"
      )

      state
  catch
    kind, reason ->
      Logger.error(
        "Vagus.Provisioner: #{inspect(label)} crashed (caught #{kind}: #{inspect(reason)}) — " <>
          "abandoning first-boot provisioning for this boot"
      )

      state
  end

  # Runs `steps` in order. `:ok` continues to the next step; `:halt` stops
  # the runner (a reboot is in flight for `:expand_data`); `:async` stops
  # the runner too — the step continues via `handle_info` messages instead
  # (there are no steps after `:provision_core` today, so nothing is lost).
  defp run_steps([], state), do: state

  defp run_steps([step | rest], state) do
    case safe_run_step(step, state) do
      :ok -> run_steps(rest, state)
      :halt -> state
      :async -> state
    end
  end

  # Isolates one step's crash from the rest of the pipeline (issue #45): a
  # bug in `:expand_data` must not cost `:provision_core` its turn, same
  # stage-isolation principle as `Vagus.Host.Shutdown.safe_stop_addons/1`. A
  # crashing step degrades to `:ok` — i.e. treated as done — so the runner
  # moves on to the next step rather than halting the whole pipeline.
  defp safe_run_step(step, state) do
    case state.run_step.(step, state) do
      result when result in [:ok, :halt, :async] ->
        result

      other ->
        Logger.error(
          "Vagus.Provisioner: step #{inspect(step)} returned unexpected #{inspect(other)} — " <>
            "treating as :ok"
        )

        :ok
    end
  rescue
    exception ->
      Logger.error(
        "Vagus.Provisioner: step #{inspect(step)} crashed (" <>
          Exception.format(:error, exception, __STACKTRACE__) <> ")"
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "Vagus.Provisioner: step #{inspect(step)} crashed (caught #{kind}: #{inspect(reason)})"
      )

      :ok
  end

  defp default_run_step(:expand_data, state), do: expand_data(state)
  defp default_run_step(:provision_core, state), do: provision_core(state)

  # --- :expand_data -------------------------------------------------------

  defp expand_data(state) do
    case check_data_partition(state) do
      :ok -> do_expand_data(state)
      {:skip, reason} -> skip_expand_data(reason)
    end
  end

  defp do_expand_data(state) do
    # Unconditional on every pass, regardless of the gates below: this is
    # the online ext4 grow that completes an expansion started by fwup on
    # a *previous* boot. It's a safe no-op when there's nothing to grow, so
    # there's no reason to gate it behind the same checks as the fwup call.
    # (Gated on `check_data_partition/1` above, though — resize2fs-ing a
    # partition that isn't actually the data partition is never a no-op.)
    p5 = state.rootdisk <> "p5"

    case state.cmd.("resize2fs", [p5]) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Logger.warning("Vagus.Provisioner: resize2fs #{p5} exited #{status}: #{inspect(output)}")
    end

    with {:ok, disk} <- parent_disk(state.rootdisk),
         :ok <- check_sector_gate(state, disk),
         {:ok, tail_bytes} <- tail_bytes(state, disk) do
      if tail_bytes > @tail_threshold_bytes do
        run_fwup_expand(state)
      else
        Logger.info(
          "Vagus.Provisioner: no tail to expand (#{tail_bytes} bytes) — skipping expand-data"
        )

        :ok
      end
    else
      {:skip, reason} -> skip_expand_data(reason)
    end
  end

  defp skip_expand_data(reason) do
    Logger.info("Vagus.Provisioner: skipping expand-data (#{reason})")
    :ok
  end

  # Data-partition identity gate (issue #41): `<rootdisk>p5` is only the
  # data partition on p5-data layouts like the Q6A's. On rpi3_64, p5 is a
  # 133 MiB unrelated partition and the real data partition is p7 — nothing
  # below this gate is meaningful there, and running it anyway would (once
  # rpi3_64's ops.fw grows an expand-data task) rewrite the GPT into p6/p7's
  # territory. `/root`'s mount source is ground truth for which partition is
  # actually in play, so check it against the assumed layout before touching
  # anything.
  #
  # `mounts_path` is the injectable seam (default `/proc/mounts`), always
  # config/test-controlled, never request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp check_data_partition(state) do
    expected = state.rootdisk <> "p5"

    with {:ok, contents} <- File.read(state.mounts_path),
         {:ok, actual} <- root_mount_device(contents) do
      if same_device?(actual, expected) do
        :ok
      else
        {:skip,
         "data partition is #{actual}, not #{expected} — this target doesn't use the " <>
           "p5-data layout"}
      end
    else
      {:error, reason} ->
        {:skip, "can't read #{state.mounts_path}: #{inspect(reason)}"}

      :error ->
        {:skip, "can't find /root in #{state.mounts_path}"}
    end
  end

  # `/proc/mounts` lines are "<device> <mountpoint> <fstype> <opts> <dump> <pass>"
  # (fstab(5) format) — split on whitespace and match the mountpoint column
  # exactly against "/root".
  defp root_mount_device(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.find_value(:error, fn line ->
      case String.split(line) do
        [device, "/root" | _rest] -> {:ok, device}
        _other -> false
      end
    end)
  end

  # `/dev/rootdisk0*` names are udev symlink aliases for the real device
  # (e.g. `/dev/mmcblk0p5`, `/dev/nvme0n1p5`) — resolve one `File.read_link/1`
  # hop on each side and compare basenames so a real-device mount and a
  # rootdisk-alias mount of the *same* partition still match, while a
  # different partition (rpi3_64's mmcblk0p7 vs. a would-be rootdisk0p5
  # alias resolving to mmcblk0p5) correctly doesn't.
  defp same_device?(a, b), do: resolve_device(a) == resolve_device(b)

  # `/proc/mounts` device fields aren't always absolute paths (`overlay`,
  # `tmpfs`, `none`, ...) — only attempt the symlink hop on absolute names.
  # `File.read_link/1` on a relative name resolves against the BEAM's CWD,
  # which has nothing to do with device identity; resolving it anyway could
  # coincidentally hit an unrelated symlink and produce a false match that
  # lets expand-data run when it must skip. Non-absolute names are used
  # as-is, so they simply never equal a `/dev/...` expected path — correct.
  defp resolve_device("/" <> _ = path) do
    case File.read_link(path) do
      {:ok, target} -> Path.basename(target)
      {:error, _reason} -> Path.basename(path)
    end
  end

  defp resolve_device(path), do: path

  defp parent_disk(rootdisk) do
    case File.read_link(rootdisk) do
      {:ok, target} -> {:ok, Path.basename(target)}
      {:error, reason} -> {:skip, "can't resolve #{rootdisk}: #{inspect(reason)}"}
    end
  end

  defp check_sector_gate(state, disk) do
    path = Path.join([state.sysfs_root, "block", disk, "queue", "logical_block_size"])

    case read_trimmed(path) do
      {:ok, "512"} ->
        :ok

      {:ok, other} ->
        {:skip,
         "logical_block_size=#{other} — fwup's gpt_write() is 512-LBA-only; " <>
           "expanding a 4Kn disk would corrupt its GPT"}

      {:error, reason} ->
        {:skip, "can't read #{path}: #{inspect(reason)}"}
    end
  end

  defp tail_bytes(state, disk) do
    disk_dir = Path.join([state.sysfs_root, "block", disk])

    with {:ok, disk_sectors} <- read_int(Path.join(disk_dir, "size")),
         {:ok, part_dir} <- partition_dir(disk_dir, disk),
         {:ok, part_start} <- read_int(Path.join(part_dir, "start")),
         {:ok, part_size} <- read_int(Path.join(part_dir, "size")) do
      tail_sectors = disk_sectors - (part_start + part_size)
      {:ok, tail_sectors * 512}
    else
      {:error, reason} -> {:skip, "can't compute tail size: #{inspect(reason)}"}
    end
  end

  # NVMe/mmc devices name their 5th partition "<disk>p5"; sd* devices name
  # it "<disk>5" — try both, in that order.
  defp partition_dir(disk_dir, disk) do
    p_form = Path.join(disk_dir, disk <> "p5")
    plain_form = Path.join(disk_dir, disk <> "5")

    cond do
      File.dir?(p_form) -> {:ok, p_form}
      File.dir?(plain_form) -> {:ok, plain_form}
      true -> {:error, :no_partition_dir}
    end
  end

  defp run_fwup_expand(state) do
    Logger.info("Vagus.Provisioner: expanding the data partition (fwup expand-data)")

    case state.cmd.("fwup", ["-t", "expand-data", "-d", state.rootdisk, state.ops_fw]) do
      {_output, 0} ->
        Logger.info("Vagus.Provisioner: expand applied — rebooting to complete the expansion")

        state.reboot.()
        :halt

      {output, status} ->
        Logger.error(
          "Vagus.Provisioner: fwup expand-data exited #{status} (not rebooting): " <>
            inspect(output)
        )

        :ok
    end
  end

  # path is a sysfs path built from the resolved disk name, not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp read_trimmed(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, String.trim(contents)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_int(path) do
    with {:ok, trimmed} <- read_trimmed(path),
         {int, ""} <- Integer.parse(trimmed) do
      {:ok, int}
    else
      {:error, reason} -> {:error, reason}
      _parse_error -> {:error, {:invalid_integer, path}}
    end
  end

  # --- :provision_core -----------------------------------------------------

  defp provision_core(state) do
    case state.installed.() do
      nil ->
        Logger.info("Vagus.Provisioner: no Core installed — starting first-boot provisioning")
        send(self(), :await_engine)
        :async

      version ->
        Logger.info(
          "Vagus.Provisioner: Core #{version} already installed — provisioning not needed"
        )

        :ok
    end
  end

  defp attempt_update(state) do
    case state.update.() do
      {:ok, version} ->
        Logger.info("Vagus.Provisioner: Core #{version} installed — starting it")
        start_and_await_healthy(state)
        state

      {:error, :version_installed} ->
        Logger.info("Vagus.Provisioner: Core install raced a concurrent install — already done")

        state

      {:error, reason} ->
        delay = min(state.retry_base * Integer.pow(2, state.retry_attempt), state.retry_cap)

        Logger.warning(
          "Vagus.Provisioner: Core install failed (#{inspect(reason)}) — retrying in #{delay}ms"
        )

        Process.send_after(self(), :attempt_update, delay)
        # Cap how far `retry_attempt` climbs once the delay has already
        # hit `retry_cap` — otherwise it keeps growing forever on a
        # persistently offline board and `2 ** retry_attempt` eventually
        # becomes a needlessly huge bignum for no behavioral gain.
        if delay < state.retry_cap do
          %{state | retry_attempt: state.retry_attempt + 1}
        else
          state
        end
    end
  end

  defp start_and_await_healthy(state) do
    case state.start.() do
      :ok ->
        case state.await_healthy.() do
          :healthy ->
            Logger.info("Vagus.Provisioner: first-boot provisioning complete — HA Core is up")

          :timeout ->
            Logger.warning(
              "Vagus.Provisioner: Core started but didn't report healthy in time — " <>
                "leaving steady-state health to the watchdog"
            )
        end

      {:error, reason} ->
        Logger.warning("Vagus.Provisioner: Core start failed (#{inspect(reason)}), not retrying")
    end
  end

  # --- default seams ---------------------------------------------------

  # bin/args are the hardcoded fwup/resize2fs invocations above, not request
  # input. Public (not private) so it can be unit-tested directly against a
  # nonexistent binary — same "@doc false, but def" precedent as
  # `Vagus.Addon.Manager.native_allowed?/1`.
  # sobelow_skip ["CI.System"]
  @doc false
  @spec default_cmd(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def default_cmd(bin, args) do
    System.cmd(bin, args, stderr_to_stdout: true)
  rescue
    # `System.cmd/3` doesn't return a nonzero-status tuple for a missing or
    # unusable binary — it raises `ErlangError` (`:enoent`, `:eacces`, ...).
    # Rescuing the shape (not enumerating reasons) and returning a fake
    # exit-127 ("command not found") tuple lets both call sites' existing
    # nonzero-status handling degrade this the same way it degrades a real
    # failed command (issue #45 — rpi3_64 ships no `resize2fs`). No logging
    # here — the reason is carried in the returned message, so each call
    # site's existing nonzero-status log stays the single logging point.
    exception in [ErlangError] ->
      reason = exception.original
      {"#{bin}: #{inspect(reason)}", 127}
  end

  defp default_ping, do: Vagus.Runtime.Docker.ping()

  defp default_installed, do: Vagus.Core.Versions.installed()

  defp default_update, do: Vagus.Core.Lifecycle.update()

  defp default_start, do: Vagus.Core.Lifecycle.start()

  defp default_await_healthy, do: Vagus.Core.Health.await_healthy()

  # `vintage_net` isn't compiled at all under MIX_TARGET=host, so a bare
  # `VintageNet.get/1` reference would break the host build — same split as
  # `Vagus.Engine.Manager`. The Provisioner is never enabled on :host (see
  # the module gate above), so this branch is dead in practice; tests always
  # inject `:connection` and never hit it.
  if Mix.target() == :host do
    defp default_connection, do: :disconnected
  else
    defp default_connection, do: VintageNet.get(["connection"])
  end
end
