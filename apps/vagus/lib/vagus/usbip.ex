defmodule Vagus.USBIP do
  @moduledoc """
  Lends a USB device plugged into the board to another machine over USB/IP,
  for the agent-dev-board flavor: an agent calls
  `:erpc.call(board, Vagus.USBIP, :share, ["usb:1-1.4"])`, then the laptop
  runs `usbip attach -r <board> -b 1-1.4`.

  The host half is the sysfs sequence `usbip bind`/`usbip unbind` perform
  (Linux `tools/usb/usbip/src/usbip_bind.c`, `usbip_unbind.c`, `utils.c`),
  done here because the userland is not in the firmware: Buildroot's package
  needs udev. `usbipd`, the TCP server on port 3240, runs in a privileged
  host-network container (`vagus-usbipd`) from the first share to the last.
  Its name has no `addon_` prefix, so nothing treats it as an app.

  A device that is unplugged is forgotten. The kernel keeps its port armed
  (see `forget/2`), so a device that later appears on usbip-host without
  being shared is handed back to its own driver. Devices already bound to
  usbip-host when this server starts (it crashed) are adopted, so they can
  still be unshared.
  """

  use GenServer
  require Logger

  alias Vagus.{Devices, Resubscribe}
  alias Vagus.Runtime.Podman.Cmd, as: PodmanCmd

  @container "vagus-usbipd"
  # The agent base image carries Debian's usbip userland; a pinned tag means
  # a share never pulls something nobody has run usbipd from.
  @default_image "ghcr.io/bbangert/vagus-agent-base:0.2.0"
  @driver "usbip-host"
  @cmd_timeout_ms 10_000
  @inspect_timeout_ms 10_000
  # The first `run` may pull the image.
  @run_timeout_ms 120_000
  @stop_timeout_ms 30_000
  # The longest call is a share that finds usbipd dead and then fails its
  # bind: modprobe, the liveness inspect, `podman run`, then the stop.
  @call_timeout_ms @cmd_timeout_ms + @inspect_timeout_ms + @run_timeout_ms +
                     @stop_timeout_ms + 3 * PodmanCmd.kill_budget_ms() + 5_000

  @type share :: %{id: String.t(), busid: String.t(), vid_pid: String.t() | nil}
  @type call_error :: :not_running | :timeout | {:exit, term()}
  @type error ::
          call_error()
          | :not_found
          | {:ambiguous, [String.t()]}
          | :already_shared
          | :not_shared
          | :bind_loop
          | :invalid_busid
          | :invalid_driver
          | {:sysfs, String.t(), File.posix()}
          | {:podman, term()}
          | {:cmd, String.t(), non_neg_integer(), String.t()}

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    if Keyword.get_lazy(opts, :enabled, &Vagus.Flavor.agent?/0) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @doc """
  Shares a device: its `id` (`"usb:1-1.4"`), its bare busid (`"1-1.4"`),
  or any key `Vagus.Devices.find/2` resolves. A failure leaves sysfs as it
  found it.
  """
  @spec share(term(), keyword()) :: :ok | {:error, error()}
  def share(key, opts \\ [])
  def share(key, opts) when is_binary(key), do: call(opts, {:share, key})
  def share(_key, _opts), do: {:error, :invalid_busid}

  @doc """
  Hands a shared device back to its own driver. Every step is attempted;
  the first failure is returned.
  """
  @spec unshare(term(), keyword()) :: :ok | {:error, error()}
  def unshare(key, opts \\ [])
  def unshare(key, opts) when is_binary(key), do: call(opts, {:unshare, key})
  def unshare(_key, _opts), do: {:error, :invalid_busid}

  @spec shared(keyword()) :: [share()] | {:error, call_error()}
  def shared(opts \\ []), do: call(opts, :shared)

  # A caller over dist gets a value, never an exit.
  defp call(opts, msg) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), msg, @call_timeout_ms)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {{:nodedown, _}, _} -> {:error, :not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl GenServer
  def init(opts) do
    state = %{
      sysfs: Keyword.get(opts, :sysfs_root, "/sys"),
      cmd: Keyword.get(opts, :cmd, &default_cmd/2),
      podman: Keyword.get(opts, :podman, []),
      image:
        Keyword.get_lazy(opts, :image, fn ->
          Application.get_env(:vagus, __MODULE__, [])[:image] || @default_image
        end),
      watcher: Keyword.get(opts, :watcher, Devices.Watcher),
      subscribe: Keyword.get(opts, :subscribe, &Devices.Watcher.subscribe/1),
      devices_opts:
        Keyword.get_lazy(opts, :devices_opts, fn -> Keyword.take(opts, [:sysfs_root]) end),
      trace: Keyword.get(opts, :trace),
      watcher_ref: nil,
      daemon: :down,
      shares: %{}
    }

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    state = adopt(state)
    # Not expected: the Watcher is :ignore wherever nerves_uevent is absent,
    # and there a missing Watcher is the idle case, not one to retry.
    {:noreply, subscribe(state, &Resubscribe.start(&1, &2, :resubscribe, false))}
  end

  @impl GenServer
  def handle_call(:shared, _from, state) do
    {:reply, state.shares |> Map.values() |> Enum.sort_by(& &1.busid), state}
  end

  def handle_call({:share, key}, _from, state) do
    case share_device(key, state) do
      {:ok, share, state} -> {:reply, :ok, put_in(state.shares[share.busid], share)}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unshare, key}, _from, state) do
    busid = busid(key)

    cond do
      not busid?(busid) -> {:reply, {:error, :invalid_busid}, state}
      Map.has_key?(state.shares, busid) -> unshare_busid(busid, state)
      driver(busid, state) == @driver -> unshare_busid(busid, state)
      true -> {:reply, {:error, :not_shared}, state}
    end
  end

  @impl GenServer
  def handle_info({:device, :removed, "usb:" <> busid}, %{shares: shares} = state)
      when is_map_key(shares, busid) do
    {:noreply, forget(busid, state)}
  end

  def handle_info({:device, :added, %{id: "usb:" <> busid}}, %{shares: shares} = state)
      when not is_map_key(shares, busid) do
    if busid?(busid) and driver(busid, state) == @driver, do: release_captured(busid, state)
    {:noreply, state}
  end

  def handle_info({:device, _event, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{watcher_ref: ref} = state) do
    {:noreply, %{state | watcher_ref: Resubscribe.down(state.watcher, :resubscribe)}}
  end

  def handle_info(:resubscribe, state) do
    {:noreply, subscribe(state, &Resubscribe.retry(&1, &2, :resubscribe))}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp share_device(key, state) do
    with :ok <- check_key(key),
         {:ok, device} <- resolve(key, state),
         busid = busid(device.id),
         :ok <- not_shared(busid, state),
         :ok <- not_imported(device),
         :ok <- modprobe(state),
         {:ok, state} <- ensure_daemon(state) do
      case bind(busid, state) do
        :ok -> {:ok, %{id: device.id, busid: busid, vid_pid: device.vid_pid}, state}
        {:error, reason} -> {:error, reason, stop_if_idle(state)}
      end
    else
      {:error, reason, state} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # A device under vhci_hcd is itself imported over USB/IP; exporting it
  # again sends its URBs back through usbip, a loop when the importer is the
  # machine it came from.
  defp not_imported(device) do
    if String.contains?(device.sysfs, "vhci_hcd"), do: {:error, :bind_loop}, else: :ok
  end

  defp subscribe(state, how) do
    case how.(state.watcher, state.subscribe) do
      nil -> state
      ref -> reconcile(%{state | watcher_ref: ref})
    end
  end

  # Plugs and unplugs that happened while unsubscribed were never heard.
  defp reconcile(state) do
    state =
      state.shares
      |> Map.keys()
      |> Enum.reject(&File.exists?(device_path(&1, state)))
      |> Enum.reduce(state, &forget/2)

    for busid <- bound(state),
        not Map.has_key?(state.shares, busid),
        do: release_captured(busid, state)

    state
  end

  # stub_dev.c stub_disconnect() turns the entry our bind left at
  # STUB_BUSID_ALLOC back into STUB_BUSID_ADDED, and stub_main.c
  # del_match_busid() leaves an ADDED entry as it is (it clears only OTHER
  # and marks the rest REMOV), so the port stays armed for the next device.
  # rebind_store() would disarm it, but its do_rebind() dereferences the
  # gone device's busid_priv->udev, as module unload's stub_device_rebind()
  # does; nothing disarms it safely. The `del` still matters when the
  # disconnect returned early and left ALLOC: that it turns into REMOV.
  defp forget(busid, state) do
    _ = write(match_busid(state), "del " <> busid, state)
    stop_if_idle(%{state | shares: Map.delete(state.shares, busid)})
  end

  # The armed entry of an unplugged share claimed a new device on its port;
  # now it has a live udev, so the unshare sequence disarms it.
  defp release_captured(busid, state) do
    Logger.warning("Vagus.USBIP: #{busid} was claimed by a stale match_busid entry; releasing")

    with {_, {:error, reason}} <- restore(busid, state),
         do: Logger.warning("Vagus.USBIP: releasing #{busid}: #{inspect(reason)}")
  end

  defp adopt(state) do
    bound = bound(state)

    if bound == [] do
      # Nothing is lent, so a usbipd container is an orphan of a crash.
      daemon_down(state)
    else
      Logger.info("Vagus.USBIP: adopted #{Enum.join(bound, ", ")}")
      state = %{state | shares: Map.new(bound, &{&1, adopted(&1, state)})}

      case daemon_up(state) do
        {:ok, state} ->
          state

        {:error, reason, state} ->
          Logger.warning("Vagus.USBIP: usbipd not started: #{inspect(reason)}")
          state
      end
    end
  end

  defp adopted(busid, state) do
    vid_pid =
      case Devices.find("usb:" <> busid, state.devices_opts) do
        {:ok, device} -> device.vid_pid
        {:error, _} -> nil
      end

    %{id: "usb:" <> busid, busid: busid, vid_pid: vid_pid}
  end

  defp bound(state) do
    case File.ls(driver_path(@driver, state)) do
      {:ok, entries} -> entries |> Enum.filter(&busid?/1) |> Enum.sort()
      {:error, _} -> []
    end
  end

  defp resolve(key, state) do
    key = if busid?(key), do: "usb:" <> key, else: key

    case Devices.find(key, state.devices_opts) do
      {:ok, %{kind: :usb} = device} -> {:ok, device}
      {:ok, _sys} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp busid(id), do: String.replace_prefix(id, "usb:", "")

  # Every sysfs path is built from a busid, so one is only ever the kernel's
  # port-path shape. A `/dev` node path is still a valid `Devices.find/2` key.
  defp busid?(busid), do: Devices.usb_id(busid) != nil

  defp check_key("usb:" <> busid), do: if(busid?(busid), do: :ok, else: {:error, :invalid_busid})

  defp check_key(key) do
    if String.contains?(key, "/") and not String.starts_with?(key, "/dev/"),
      do: {:error, :invalid_busid},
      else: :ok
  end

  defp not_shared(busid, state) do
    if Map.has_key?(state.shares, busid) or driver(busid, state) == @driver,
      do: {:error, :already_shared},
      else: :ok
  end

  # usbip_bind.c bind_device(): unbind_other() releases the device (not its
  # interfaces) from its driver, then `match_busid` "add", then `bind`; a
  # failed bind takes the match back out. Every value is written without a
  # newline: match_busid_store() keeps everything after "add " as the busid.
  defp bind(busid, state) do
    original = driver(busid, state)

    with :ok <- release(original, busid, state),
         :ok <-
           or_reprobe(write(match_busid(state), "add " <> busid, state), original, busid, state) do
      case write(attr(@driver, "bind", state), busid, state) do
        :ok ->
          :ok

        error ->
          _ = write(match_busid(state), "del " <> busid, state)
          or_reprobe(error, original, busid, state)
      end
    end
  end

  defp release(nil, _busid, _state), do: :ok
  defp release(:invalid, _busid, _state), do: {:error, :invalid_driver}
  defp release(driver, busid, state), do: write(attr(driver, "unbind", state), busid, state)

  # usbip_bind.c leaves a device it released driverless when the bind
  # fails; `drivers_probe` hands it back to whichever driver claims it.
  defp or_reprobe(:ok, _original, _busid, _state), do: :ok
  defp or_reprobe(error, nil, _busid, _state), do: error

  defp or_reprobe(error, _original, busid, state) do
    _ = write(drivers_probe(state), busid, state)
    error
  end

  # Past the unbind the device is no longer lent, so it is forgotten even if
  # a later step fails.
  defp unshare_busid(busid, state) do
    {unbind, result} = restore(busid, state)

    state =
      if unbind == :ok,
        do: stop_if_idle(%{state | shares: Map.delete(state.shares, busid)}),
        else: state

    {:reply, result, state}
  end

  # usbip_unbind.c unbind_device(): `unbind`, `match_busid` "del", then
  # `rebind`. The unbind leaves the entry STUB_BUSID_ADDED, which the "del"
  # does not clear (stub_main.c del_match_busid()); rebind_store() is what
  # disarms it: it sets STUB_BUSID_OTHER, re-attaches the device to its own
  # driver, then deletes the entry. A failed rebind leaves the device
  # driverless, so `drivers_probe` is tried. Each step runs whatever the
  # previous one returned; the first failure is the result.
  defp restore(busid, state) do
    unbind =
      if driver(busid, state) == @driver,
        do: write(attr(@driver, "unbind", state), busid, state),
        else: :ok

    del = write(match_busid(state), "del " <> busid, state)

    rebind =
      with {:error, _} = error <- write(attr(@driver, "rebind", state), busid, state) do
        _ = write(drivers_probe(state), busid, state)
        error
      end

    {unbind, Enum.find([unbind, del, rebind], :ok, &(&1 != :ok))}
  end

  defp driver(busid, state) do
    case File.read_link(Path.join(device_path(busid, state), "driver")) do
      {:ok, target} -> driver_name(Path.basename(target))
      {:error, _} -> nil
    end
  end

  # It names a directory under `drivers/`, so it must be one plain segment.
  defp driver_name(name) do
    if name not in ["", ".", ".."] and Regex.match?(~r/\A[\w.-]+\z/, name),
      do: name,
      else: :invalid
  end

  defp device_path(busid, state), do: Path.join([state.sysfs, "bus", "usb", "devices", busid])
  defp driver_path(driver, state), do: Path.join([state.sysfs, "bus", "usb", "drivers", driver])
  defp attr(driver, name, state), do: Path.join(driver_path(driver, state), name)
  defp match_busid(state), do: attr(@driver, "match_busid", state)
  defp drivers_probe(state), do: Path.join([state.sysfs, "bus", "usb", "drivers_probe"])

  # File.write would create a missing attribute (O_CREAT), which on sysfs
  # fails with a misleading EACCES and in a test tree silently succeeds.
  # Every segment is a checked busid or driver name under the configured root.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(path, value, state) do
    if state.trace,
      do: send(state.trace, {:sysfs_write, Path.relative_to(path, state.sysfs), value})

    result = if File.regular?(path), do: File.write(path, value), else: {:error, :enoent}

    case result do
      :ok -> :ok
      {:error, posix} -> {:error, {:sysfs, path, posix}}
    end
  end

  defp modprobe(state) do
    case state.cmd.("modprobe", [@driver]) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:cmd, "modprobe", status, String.trim(out)}}
    end
  end

  defp default_cmd(bin, args) do
    case Vagus.BoundedCall.run(fn -> Vagus.Host.Cmd.run(bin, args) end, @cmd_timeout_ms) do
      {out, status} when is_binary(out) -> {out, status}
      {:error, reason} -> {"#{bin}: #{inspect(reason)}", 1}
    end
  end

  defp stop_if_idle(%{shares: shares} = state) when shares == %{}, do: daemon_down(state)
  defp stop_if_idle(state), do: state

  # usbipd can die on its own (`--rm` then removes the container), so an
  # `:up` is checked before a share relies on it.
  defp ensure_daemon(%{daemon: :up} = state) do
    if daemon_running?(state) do
      {:ok, state}
    else
      Logger.warning("Vagus.USBIP: #{@container} is not running; starting it again")
      daemon_up(%{state | daemon: :down})
    end
  end

  defp ensure_daemon(state), do: daemon_up(state)

  defp daemon_running?(state) do
    args = ["container", "inspect", "-f", "{{.State.Running}}", @container]

    case PodmanCmd.run(args, podman_opts(@inspect_timeout_ms, state)) do
      {:ok, out} -> String.trim(out) == "true"
      _ -> false
    end
  end

  # Foreground `usbipd` (no -D), so the container lives exactly as long as
  # the daemon. `--replace` clears a container a crashed server left behind.
  # Privileged mounts /sys read-write, and root (the image ends `USER agent`)
  # may write it: usbipd hands each accepted socket to usbip-host through
  # `usbip_sockfd`.
  defp daemon_up(state) do
    args = [
      "run",
      "-d",
      "--rm",
      "--replace",
      "--name",
      @container,
      "--privileged",
      "--network=host",
      "--user",
      "root",
      "--entrypoint",
      "usbipd",
      state.image
    ]

    case PodmanCmd.run(args, podman_opts(@run_timeout_ms, state)) do
      {:ok, _} -> {:ok, %{state | daemon: :up}}
      {:exit, status, out} -> {:error, {:podman, {status, String.trim(out)}}, state}
      {:error, reason} -> {:error, {:podman, reason}, state}
    end
  end

  defp daemon_down(state) do
    args = ["stop", "-t", "5", "--ignore", @container]

    case PodmanCmd.run(args, podman_opts(@stop_timeout_ms, state)) do
      {:ok, _} -> :ok
      other -> Logger.warning("Vagus.USBIP: podman stop #{@container}: #{inspect(other)}")
    end

    # A failed stop is retried by the next share's `run --replace`.
    %{state | daemon: :down}
  end

  defp podman_opts(timeout_ms, state), do: Keyword.merge([timeout_ms: timeout_ms], state.podman)
end
