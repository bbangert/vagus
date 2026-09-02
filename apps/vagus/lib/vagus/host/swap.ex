defmodule Vagus.Host.Swap do
  @moduledoc """
  Configures swap once at boot, picking the backing store from the root
  medium: compressed RAM (zram) on SD/eMMC boards, a `/data` swapfile fronted
  by zswap on UFS/NVMe/USB boards.

  Until now no Vagus board had swap at all — a board that ran out of RAM
  OOM-killed HA Core instead of paging. The kernel gained SWAP/zram/zswap
  (both with LZ4), PSI and MGLRU on every target; this is the runtime half
  that decides what to do with them, because the right answer differs per
  board and only the running system knows which board it is.

  ## Why the backing store follows the root medium

  On SD/eMMC, a disk-backed swapfile would write the flash to death — those
  cards have no wear levelling worth the name and are the boot medium as
  well. zram costs RAM to save RAM (the kernel's zram docs say to expect
  about 2:1) but touches no flash. UFS and NVMe survive the writes and are
  big enough to hand out gigabytes, which buys far more headroom than
  compressing the same RAM in place.

  ## Compression belongs to whoever created the device

  zswap is a compressed cache in front of a *disk-backed* swap device, so it
  is written `Y` only on the swapfile path — and there it is a precondition
  rather than a finishing touch: without it the swapfile is plain
  uncompressed disk swap, which is not the trade this module exists to make.
  So `configure_swapfile/3` enables zswap first, before it measures or
  creates anything, and a kernel that offers no zswap parameters skips the
  path with nothing written.

  Leaving zswap on in front of zram would instead compress every page twice,
  spending CPU to make pages bigger. The zram path therefore writes `N`
  explicitly rather than assuming the kernel's default (`ZSWAP_DEFAULT_ON`
  is off today, but that is a build option, not a guarantee).

  ## Swappiness

  `vm.swappiness` is 150 on zram boards: the kernel documents the 0-200
  range with values above 100 reserved for swap that is as fast as the page
  cache, which in-memory swap is. On swapfile boards it is 10 — paging a
  BEAM heap out to real storage is slow enough that we would rather reclaim
  page cache first, and the swapfile exists as a spike absorber, not as
  routine capacity. `vm.page-cluster` goes to 0 on zram only, since swap
  readahead has nothing to amortise when the "device" is RAM.

  These writes are the only place swappiness is set — the system's
  `/etc/sysctl.conf` line was removed. nerves_runtime applies that file
  before `:vagus` starts, so anything written here lands last and wins.

  ## mkswap can only ever see two paths

  The `.87` near-miss (a `mkfs` that nearly ran against a mounted `/data`)
  is why `mkswap/2` is a two-clause function matching literally `/dev/zram0`
  or the configured swapfile, and why the run refuses a `swapfile_path`
  not named `swapfile`. Any other argument is a `FunctionClauseError` — a
  loud crash beats a quiet reformat. The swapfile path is additionally
  required to be a regular file or absent; a directory, symlink or device
  node there means we touch nothing at all. That `lstat` leaves a window
  before the write, but only root-owned processes write directly under
  `/data` — add-on mounts map subdirectories of it, never the data root
  itself — so nothing hostile is in a position to race it. The accepted
  residual is the swapfile itself: a snapshot of RAM persisting on the
  unencrypted `/data` across reboots, the same trade HAOS makes.

  ## Lifecycle

  Gated by `config :vagus, :host_swap` read at `start_link/1` time (`:ignore`
  otherwise), like `Vagus.Provisioner`. `init/1` returns immediately with
  `{:continue, :run}` so nothing blocks the supervisor. The whole run is
  wrapped in a rescue/catch: a bug here must never crash-loop a
  `:permanent` child and take `:vagus` down over a memory optimisation.

  One run configures swap for the boot and the process then idles — an
  already-active `/proc/swaps` short-circuits the whole flow, so a restart
  is a no-op. The one exception is the free-space skip: `Vagus.Provisioner`
  grows `/data` with `resize2fs` from a sibling child started at the same
  time, so on the boot after `fwup expand-data` this module can measure the
  filesystem before it has grown. That skip alone schedules a single retry
  five minutes out; every other outcome is terminal.

  Each path is gated on the kernel actually providing its compressor: no
  `zram0` in sysfs skips the zram path, no zswap parameters skips the
  swapfile path. Until the system release that builds both reaches a board,
  every board therefore skips — enabling the config switch ahead of that
  release changes nothing.
  """

  use GenServer

  require Logger

  @zram_dev "/dev/zram0"
  @rootdisk "/dev/rootdisk0"
  @sysfs_root "/sys"
  @procsys_root "/proc/sys"
  @mounts_path "/proc/mounts"
  @swaps_path "/proc/swaps"
  @meminfo_path "/proc/meminfo"
  @swapfile_path "/data/swapfile"
  @zswap_param_dir "/sys/module/zswap/parameters"

  @swapfile_fraction 33
  @swapfile_min 1_073_741_824
  @swapfile_max 4_294_967_296
  # An existing swapfile within this much of the target size is kept as-is:
  # the target moves with `MemTotal`, which can shift slightly across kernel
  # versions, and rewriting gigabytes to chase a few MiB is pure flash wear.
  @swapfile_slack 33_554_432
  # Space `dd` must leave behind: a `/data` filled to the last byte breaks
  # Core's recorder and the add-on store — worse than having no swap at all.
  @swapfile_headroom 536_870_912
  @block_size 4096

  # The only skip worth a second look, matched as a prefix so no other skip
  # reason can trigger the retry. Five minutes is longer than a `resize2fs`
  # of a multi-GiB `/data` and still inside the boot it belongs to.
  @no_space "not enough free space on"
  @retry_after 300_000

  @type result ::
          :already_active
          | {:zram, non_neg_integer()}
          | {:swapfile, non_neg_integer()}
          | {:skipped, String.t()}
          | {:failed, String.t()}
          | {:error, :crashed}

  @doc """
  Starts the boot-time swap configurator — `:ignore` (no process) unless
  `config :vagus, :host_swap` is truthy.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    if Application.get_env(:vagus, :host_swap, false) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @impl GenServer
  def init(opts) do
    cmd = Keyword.get(opts, :cmd, &Vagus.Host.Cmd.run/2)
    swapfile_path = Keyword.get(opts, :swapfile_path, @swapfile_path)

    state = %{
      cmd: cmd,
      df: Keyword.get(opts, :df, &default_df(&1, cmd)),
      rootdisk: Keyword.get(opts, :rootdisk, @rootdisk),
      sysfs_root: Keyword.get(opts, :sysfs_root, @sysfs_root),
      procsys_root: Keyword.get(opts, :procsys_root, @procsys_root),
      mounts_path: Keyword.get(opts, :mounts_path, @mounts_path),
      swaps_path: Keyword.get(opts, :swaps_path, @swaps_path),
      meminfo_path: Keyword.get(opts, :meminfo_path, @meminfo_path),
      swapfile_path: swapfile_path,
      zswap_param_dir: Keyword.get(opts, :zswap_param_dir, @zswap_param_dir),
      retry_after: Keyword.get(opts, :retry_after, @retry_after),
      retries_left: 1,
      result: nil
    }

    {:ok, state, {:continue, :run}}
  end

  @impl GenServer
  def handle_continue(:run, state), do: {:noreply, store(state, safe_run(state))}

  # `retries_left` is spent on arrival rather than on scheduling, so a stray
  # `:retry` cannot buy an extra run. Re-running is safe at any time: the
  # flow re-reads `/proc/swaps` first and stops there once swap is on.
  @impl GenServer
  def handle_info(:retry, %{retries_left: 0} = state), do: {:noreply, state}

  def handle_info(:retry, state) do
    {:noreply, store(%{state | retries_left: state.retries_left - 1}, safe_run(state))}
  end

  def handle_info(message, state) do
    Logger.debug("Vagus.Host.Swap: ignoring unexpected message #{inspect(message)}")
    {:noreply, state}
  end

  defp store(state, result), do: maybe_retry(%{state | result: result})

  # `/data` may still be growing under us on the boot after `fwup
  # expand-data` (see the moduledoc's Lifecycle).
  defp maybe_retry(%{result: {:skipped, @no_space <> _reason}, retries_left: left} = state)
       when left > 0 do
    Logger.info(
      "Vagus.Host.Swap: retrying in #{div(state.retry_after, 1000)} s — " <>
        "/data may still be expanding"
    )

    Process.send_after(self(), :retry, state.retry_after)
    state
  end

  defp maybe_retry(state), do: state

  # A raise anywhere below becomes one logged line and an idle process. The
  # alternative — letting it crash — is a `:permanent` child restarting into
  # the same raise, burning `Vagus.Supervisor`'s shared restart budget and
  # taking HA Core down with it (issue #45's lesson, applied up front).
  defp safe_run(state) do
    run(state)
  rescue
    exception ->
      Logger.error(
        "Vagus.Host.Swap: crashed (" <>
          Exception.format(:error, exception, __STACKTRACE__) <>
          ") — leaving swap unconfigured for this boot"
      )

      {:error, :crashed}
  catch
    kind, reason ->
      Logger.error(
        "Vagus.Host.Swap: crashed (caught #{kind}: #{inspect(reason)}) — " <>
          "leaving swap unconfigured for this boot"
      )

      {:error, :crashed}
  end

  defp run(state) do
    case validate_swapfile_path(state.swapfile_path) do
      :ok -> run_unless_active(state)
      {:error, reason} -> fail(reason)
    end
  end

  defp run_unless_active(state) do
    case active_swaps(state) do
      {:ok, []} ->
        configure(state)

      {:ok, names} ->
        Logger.info("Vagus.Host.Swap: swap already active (#{Enum.join(names, ", ")})")
        :already_active

      {:skip, reason} ->
        skip(reason)
    end
  end

  defp configure(state) do
    with {:ok, mem_total} <- mem_total(state),
         {:ok, disk} <- root_disk(state),
         {:ok, backing} <- classify(disk) do
      case backing do
        :zram -> configure_zram(state, mem_total)
        :swapfile -> configure_swapfile(state, mem_total, disk)
      end
    else
      {:skip, reason} -> skip(reason)
    end
  end

  defp skip(reason) do
    Logger.info("Vagus.Host.Swap: skipping (#{reason})")
    {:skipped, reason}
  end

  defp fail(reason) do
    Logger.warning("Vagus.Host.Swap: #{reason}")
    {:failed, reason}
  end

  # `/proc/swaps` opens with a `Filename Type Size Used Priority` header;
  # every real entry is an absolute path. Any entry at all means someone
  # (a previous run of this module, most likely) already configured swap.
  # A procfs read failure is not a state worth acting on: guessing "no swap"
  # is guessing toward `mkswap`, against a file the kernel may be paging to.
  defp active_swaps(state) do
    case read_file(state.swaps_path) do
      {:ok, contents} ->
        {:ok,
         contents
         |> String.split("\n", trim: true)
         |> Enum.filter(&String.starts_with?(&1, "/"))
         |> Enum.map(&(&1 |> String.split() |> hd()))}

      {:error, reason} ->
        {:skip, "can't read #{state.swaps_path}: #{inspect(reason)}"}
    end
  end

  defp mem_total(state) do
    case Vagus.Platform.Memory.total_bytes(state.meminfo_path) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:skip, "can't read MemTotal from #{state.meminfo_path}"}
    end
  end

  defp root_disk(state) do
    case File.read_link(state.rootdisk) do
      {:ok, target} -> {:ok, Path.basename(target)}
      {:error, reason} -> {:skip, "can't resolve #{state.rootdisk}: #{inspect(reason)}"}
    end
  end

  defp classify("mmcblk" <> _), do: {:ok, :zram}
  defp classify("sd" <> _), do: {:ok, :swapfile}
  defp classify("nvme" <> _), do: {:ok, :swapfile}
  defp classify("vd" <> _), do: {:ok, :swapfile}
  defp classify(name), do: {:skip, "unrecognised root disk #{name}"}

  # --- zram ---------------------------------------------------------------

  defp configure_zram(state, mem_total) do
    zram_dir = Path.join([state.sysfs_root, "block", "zram0"])

    if dir?(zram_dir) do
      set_comp_algorithm(zram_dir)
      init_zram(state, zram_dir, div(mem_total, 2))
    else
      skip("no zram0 at #{zram_dir} — kernel without CONFIG_ZRAM?")
    end
  end

  # Half of RAM is the device's *uncompressed* capacity, not an allocation:
  # RAM is consumed only as pages are swapped in, at their compressed size,
  # so a full 50 % device costs about 25 % of RAM at the 2:1 the kernel docs
  # expect. 50 % is the appliance consensus (Armbian, zram-generator).
  defp init_zram(state, zram_dir, disksize) do
    case write_file(Path.join(zram_dir, "disksize"), to_string(disksize)) do
      :ok ->
        swapon_zram(state, disksize)

      {:error, reason} ->
        # `disksize` is write-once per device init — there is no way back to
        # a clean zram0 short of a reboot, so a half-configured device is
        # left alone rather than retried.
        fail("can't set zram disksize (#{inspect(reason)}) — leaving zram0 alone until reboot")
    end
  end

  # `comp_algorithm` reads as the available compressors with the current one
  # bracketed (`lzo lzo-rle [lz4] zstd`) and is writable only *before*
  # `disksize` initialises the device. LZ4 is the point of the exercise on
  # these boards — it decompresses fast enough that swapping in stays cheap
  # — but a kernel that doesn't offer it is not a reason to abort.
  defp set_comp_algorithm(zram_dir) do
    path = Path.join(zram_dir, "comp_algorithm")

    case read_file(path) do
      {:ok, contents} ->
        select_lz4(path, contents)

      {:error, reason} ->
        Logger.warning("Vagus.Host.Swap: can't read #{path}: #{inspect(reason)}")
    end
  end

  defp select_lz4(path, contents) do
    if "lz4" in algorithms(contents) do
      case write_file(path, "lz4") do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Vagus.Host.Swap: can't select lz4 (#{inspect(reason)})")
      end
    else
      Logger.warning(
        "Vagus.Host.Swap: zram offers no lz4 (#{String.trim(contents)}) — keeping the default"
      )
    end
  end

  defp algorithms(contents) do
    contents
    |> String.split()
    |> Enum.map(&(&1 |> String.trim_leading("[") |> String.trim_trailing("]")))
  end

  defp swapon_zram(state, disksize) do
    case mkswap(state, @zram_dev) do
      {_output, 0} -> zram_swapon(state, disksize)
      {output, status} -> fail("mkswap exited #{status}: #{inspect(output)}")
    end
  end

  # Priority 100 so zram always outranks any disk-backed swap the kernel
  # picked up on its own.
  defp zram_swapon(state, disksize) do
    case state.cmd.("swapon", ["-p", "100", @zram_dev]) do
      {_output, 0} -> finish_zram(state, disksize)
      {output, status} -> fail("swapon exited #{status}: #{inspect(output)}")
    end
  end

  defp finish_zram(state, disksize) do
    write_zswap(state, "N")
    write_sysctl(state, "swappiness", "150")
    write_sysctl(state, "page-cluster", "0")

    mib = mib(disksize)
    Logger.info("Vagus.Host.Swap: zram #{mib} MiB active, swappiness 150")
    {:zram, mib}
  end

  # --- swapfile -----------------------------------------------------------

  defp configure_swapfile(state, mem_total, disk) do
    with :ok <- enable_zswap(state),
         {:ok, mountpoint} <- data_mountpoint(state, disk),
         size = swapfile_size(mem_total),
         :ok <- ensure_swapfile(state, mountpoint, size) do
      swapon_swapfile(state, size)
    else
      {:skip, reason} -> skip(reason)
      {:error, reason} -> fail(reason)
    end
  end

  # Enabling zswap is what makes writing gigabytes of swap to flash
  # defensible (see the moduledoc), so it happens before anything is
  # measured or created and a kernel without it gets no swapfile at all —
  # not a 1-4 GiB uncompressed one nobody asked for.
  defp enable_zswap(state) do
    path = Path.join(state.zswap_param_dir, "enabled")

    if exists?(path) do
      case write_file(path, "Y") do
        :ok -> :ok
        {:error, reason} -> {:error, "can't enable zswap at #{path}: #{inspect(reason)}"}
      end
    else
      {:skip,
       "kernel has no zswap (#{path} missing) — waiting for the memory-tuning system release"}
    end
  end

  # The swapfile must live on the root disk. Swapping onto removable or
  # network-backed storage takes the board down the moment the medium
  # blinks, and `/data` is not guaranteed to be where we assume it is.
  defp data_mountpoint(state, disk) do
    with {:ok, contents} <- read_mounts(state),
         {:ok, mountpoint, device} <- find_data_mount(contents) do
      actual = parent_disk(resolve_device(device))

      if actual == disk do
        {:ok, mountpoint}
      else
        {:skip, "#{mountpoint} is on #{actual}, not on the root disk #{disk}"}
      end
    end
  end

  defp read_mounts(state) do
    case read_file(state.mounts_path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:skip, "can't read #{state.mounts_path}: #{inspect(reason)}"}
    end
  end

  # Nerves mounts the application partition at `/root` with `/data` as a
  # symlink to it on some boards and mounts `/data` itself on others. `/data`
  # is where the swapfile goes, so its own entry wins whenever it has one and
  # `/root` only covers the symlink case. Lines are fstab(5) columns.
  defp find_data_mount(contents) do
    lines = String.split(contents, "\n", trim: true)

    Enum.find_value(
      ["/data", "/root"],
      {:skip, "found neither /data nor /root in the mount table"},
      fn mountpoint ->
        Enum.find_value(lines, fn line ->
          case String.split(line) do
            [device, ^mountpoint | _rest] -> {:ok, mountpoint, device}
            _other -> nil
          end
        end)
      end
    )
  end

  # `/dev/rootdisk0*` names are udev aliases for the real device — resolve
  # one symlink hop so an alias mount and a real-device mount of the same
  # partition compare equal. Non-absolute device fields (`overlay`, `none`)
  # are used as-is: `File.read_link/1` would resolve them against the BEAM's
  # CWD and could produce a coincidental match.
  defp resolve_device("/" <> _ = path) do
    case File.read_link(path) do
      {:ok, target} -> Path.basename(target)
      {:error, _reason} -> Path.basename(path)
    end
  end

  defp resolve_device(path), do: path

  # mmc/nvme partitions are `<disk>p<n>`, sd/vd partitions `<disk><n>`.
  defp parent_disk("mmcblk" <> _ = name), do: String.replace(name, ~r/p\d+$/, "")
  defp parent_disk("nvme" <> _ = name), do: String.replace(name, ~r/p\d+$/, "")
  defp parent_disk("sd" <> _ = name), do: String.replace(name, ~r/\d+$/, "")
  defp parent_disk("vd" <> _ = name), do: String.replace(name, ~r/\d+$/, "")
  defp parent_disk(name), do: name

  # HAOS's haos-swapfile formula verbatim: a third of RAM clamped to 1-4 GiB
  # (below 1 GiB there is too little to absorb a spike; above 4 GiB the file
  # is disk and time spent zeroing it for headroom nothing here uses), then
  # rounded down to whole 4 KiB blocks so `dd`'s count is exact.
  defp swapfile_size(mem_total) do
    mem_total
    |> Kernel.*(@swapfile_fraction)
    |> div(100)
    |> min(@swapfile_max)
    |> max(@swapfile_min)
    |> div(@block_size)
    |> Kernel.*(@block_size)
  end

  # `File.lstat/1` rather than `stat` on purpose: a symlink at the swapfile
  # path must be refused, not followed to whatever it points at.
  defp ensure_swapfile(state, mountpoint, size) do
    case lstat(state.swapfile_path) do
      {:ok, %File.Stat{type: :regular, size: existing}} ->
        reuse_or_recreate(state, mountpoint, size, existing)

      {:ok, %File.Stat{type: type}} ->
        {:skip,
         "#{state.swapfile_path} exists and is not a regular file (#{type}) — " <>
           "refusing to touch it"}

      {:error, :enoent} ->
        create_swapfile(state, mountpoint, size)

      {:error, reason} ->
        {:skip, "can't stat #{state.swapfile_path}: #{inspect(reason)}"}
    end
  end

  defp reuse_or_recreate(state, mountpoint, size, existing) do
    if abs(existing - size) <= @swapfile_slack do
      reuse(state, existing)
    else
      case rm_file(state.swapfile_path) do
        :ok ->
          create_swapfile(state, mountpoint, size)

        {:error, reason} ->
          {:error, "can't remove stale swapfile #{state.swapfile_path}: #{inspect(reason)}"}
      end
    end
  end

  # A file this module did not create — an older firmware's, a restored
  # image's — must never be swapon'd while others can read it: it is about
  # to hold RAM contents.
  defp reuse(state, existing) do
    case chmod_swapfile(state) do
      :ok ->
        Logger.info(
          "Vagus.Host.Swap: reusing existing swapfile #{state.swapfile_path} (#{mib(existing)} MiB)"
        )

        :ok

      {:error, reason} ->
        {:error, "can't chmod #{state.swapfile_path}: #{inspect(reason)}"}
    end
  end

  # Checking free space first because `dd` filling `/data` to the last byte
  # would break HA Core (and the add-on store) far worse than having no swap.
  defp create_swapfile(state, mountpoint, size) do
    case state.df.(mountpoint) do
      {:ok, free} when free >= size + @swapfile_headroom ->
        dd_swapfile(state, size)

      {:ok, free} ->
        Logger.error(
          "Vagus.Host.Swap: not enough free space on #{mountpoint}: " <>
            "need #{mib(size)} MiB + #{mib(@swapfile_headroom)} MiB headroom, " <>
            "have #{mib(free)} MiB"
        )

        {:skip, "#{@no_space} #{mountpoint}"}

      :error ->
        {:skip, "can't measure free space on #{mountpoint}"}
    end
  end

  # `dd` writes to `<path>.tmp` and only a complete file is renamed into
  # place: a partial one left at the real path can fall within the reuse
  # slack and be swapon'd at the wrong size a boot later. An untrappable
  # `:kill` mid-`dd` orphans the port's `dd` — the BEAM does not reap it —
  # but the orphan writes to the tmp file, which the next run clears.
  defp dd_swapfile(state, size) do
    tmp = state.swapfile_path <> ".tmp"

    with :ok <- clear_tmp(tmp),
         :ok <- touch_file(tmp),
         :ok <- run_dd(state, tmp, div(size, @block_size)) do
      rename_tmp(state, tmp)
    end
  end

  defp clear_tmp(tmp) do
    case lstat(tmp) do
      {:ok, %File.Stat{type: :regular}} ->
        Logger.info("Vagus.Host.Swap: removing leftover #{tmp}")
        remove_tmp(tmp)

      {:ok, %File.Stat{type: type}} ->
        {:skip, "#{tmp} exists and is not a regular file (#{type}) — refusing to touch it"}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:skip, "can't stat #{tmp}: #{inspect(reason)}"}
    end
  end

  defp remove_tmp(tmp) do
    case rm_file(tmp) do
      :ok -> :ok
      {:error, reason} -> {:error, "can't remove #{tmp}: #{inspect(reason)}"}
    end
  end

  defp run_dd(state, tmp, blocks) do
    args = ["if=/dev/zero", "of=#{tmp}", "bs=4k", "count=#{blocks}"]

    case state.cmd.("dd", args) do
      {_output, 0} -> :ok
      {output, status} -> {:error, dd_failed(tmp, output, status)}
    end
  end

  # A leftover the cleanup could not remove is named in the error rather than
  # dropped: the next run refuses to start over on a tmp file it can't clear,
  # and that would otherwise read as an unexplained skip a boot later.
  defp dd_failed(tmp, output, status) do
    message = "dd exited #{status}: #{inspect(output)}"

    case rm_file(tmp) do
      :ok -> message
      {:error, reason} -> message <> "; could not remove #{tmp}: #{inspect(reason)}"
    end
  end

  defp rename_tmp(state, tmp) do
    case rename(tmp, state.swapfile_path) do
      :ok ->
        :ok

      {:error, reason} ->
        rm_file(tmp)
        {:error, "can't rename #{tmp} to #{state.swapfile_path}: #{inspect(reason)}"}
    end
  end

  # A freshly `dd`'d file carries no swap signature, so the first `swapon`
  # failing is the ordinary first-boot path rather than an error — hence
  # `mkswap` on demand instead of unconditionally (which would wipe the
  # signature of a perfectly good existing swapfile). Exactly one retry: a
  # second failure is a real one.
  defp swapon_swapfile(state, size) do
    case swapon(state) do
      {_output, 0} -> finish_swapfile(state, size)
      {_output, _status} -> mkswap_then_swapon(state, size)
    end
  end

  defp mkswap_then_swapon(state, size) do
    case mkswap(state, state.swapfile_path) do
      {_output, 0} -> retry_swapon(state, size)
      {output, status} -> fail("mkswap exited #{status}: #{inspect(output)}")
    end
  end

  defp retry_swapon(state, size) do
    case swapon(state) do
      {_output, 0} -> finish_swapfile(state, size)
      {output, status} -> fail("swapon exited #{status}: #{inspect(output)}")
    end
  end

  defp swapon(state), do: state.cmd.("swapon", [state.swapfile_path])

  defp finish_swapfile(state, size) do
    write_sysctl(state, "swappiness", "10")

    mib = mib(size)
    Logger.info("Vagus.Host.Swap: swapfile #{mib} MiB active, swappiness 10")
    {:swapfile, mib}
  end

  # --- guarded destructive op ----------------------------------------------

  # The entire allowlist of things this module may format. Anything else is
  # a `FunctionClauseError` by design: a mkfs-family command that can be
  # aimed at an arbitrary path is one config typo away from eating a mounted
  # filesystem.
  defp mkswap(%{cmd: cmd}, @zram_dev), do: cmd.("mkswap", [@zram_dev])
  defp mkswap(%{cmd: cmd, swapfile_path: path}, path), do: cmd.("mkswap", [path])

  defp validate_swapfile_path(path) do
    if Path.basename(path) == "swapfile" do
      :ok
    else
      {:error, "refusing swapfile_path #{inspect(path)} — must be named swapfile"}
    end
  end

  # --- knobs ---------------------------------------------------------------

  # Non-fatal on failure: swap itself is already working by the time these
  # run, and a board with the wrong swappiness beats a board with none.
  defp write_zswap(state, value) do
    path = Path.join(state.zswap_param_dir, "enabled")

    if exists?(path) do
      warn_on_error(write_file(path, value), "can't set zswap enabled=#{value}")
    else
      Logger.info(
        "Vagus.Host.Swap: zswap parameters absent at #{state.zswap_param_dir} — " <>
          "kernel without CONFIG_ZSWAP?"
      )
    end
  end

  defp write_sysctl(state, name, value) do
    path = Path.join([state.procsys_root, "vm", name])
    warn_on_error(write_file(path, value), "can't set vm.#{name}=#{value}")
  end

  defp warn_on_error(:ok, _what), do: :ok

  defp warn_on_error({:error, reason}, what),
    do: Logger.warning("Vagus.Host.Swap: #{what} (#{inspect(reason)})")

  defp mib(bytes), do: div(bytes, 1024 * 1024)

  # --- default seams --------------------------------------------------------

  # POSIX `df -Pk`: a header line, then one line per filesystem whose 4th
  # column is available 1K blocks. `-P` is what keeps that row on a single
  # line when the device name is long.
  defp default_df(mountpoint, cmd) do
    case cmd.("df", ["-Pk", mountpoint]) do
      {output, 0} -> parse_df(output)
      {_output, _status} -> :error
    end
  end

  defp parse_df(output) do
    with [_header, row | _rest] <- String.split(output, "\n", trim: true),
         [_fs, _size, _used, avail | _rest] <- String.split(row),
         {blocks, ""} <- Integer.parse(avail) do
      {:ok, blocks * 1024}
    else
      _unparsable -> :error
    end
  end

  # --- file access ----------------------------------------------------------

  # Every path reaching these helpers is built from a module attribute or an
  # injected test seam — sysfs/procfs nodes, the mount table, the configured
  # swapfile. None of it is request input, which is all Sobelow's traversal
  # check is looking for.

  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(path), do: File.read(path)

  # sobelow_skip ["Traversal.FileModule"]
  defp write_file(path, contents), do: File.write(path, contents)

  # sobelow_skip ["Traversal.FileModule"]
  defp exists?(path), do: File.exists?(path)

  # sobelow_skip ["Traversal.FileModule"]
  defp dir?(path), do: File.dir?(path)

  # sobelow_skip ["Traversal.FileModule"]
  defp lstat(path), do: File.lstat(path)

  # sobelow_skip ["Traversal.FileModule"]
  defp rm_file(path), do: File.rm(path)

  # sobelow_skip ["Traversal.FileModule"]
  defp rename(source, target), do: File.rename(source, target)

  # sobelow_skip ["Traversal.FileModule"]
  defp chmod_swapfile(state), do: File.chmod(state.swapfile_path, 0o600)

  # Mode before content: the file will hold RAM contents, so there must be
  # no window in which it is world-readable.
  # sobelow_skip ["Traversal.FileModule"]
  defp touch_file(path) do
    with :ok <- File.write(path, ""),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} -> {:error, "can't create #{path}: #{inspect(reason)}"}
    end
  end
end
