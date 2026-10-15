defmodule Vagus.Runtime.Podman.Cmd do
  @moduledoc """
  Runs one `podman` invocation from the calling process, under muontrap.

  muontrap, not a bare Port: closing a Port only closes its pipes, and a
  podman blocked on a lock never notices. On the deadline the port is
  closed and muontrap sends SIGTERM, so podman can release its locks, then
  SIGKILL 3 s later. The same kill runs if the caller dies, so a killed
  task never orphans a podman.

  Not `MuonTrap.cmd/3`: it acknowledges every chunk of output by writing to
  muontrap's stdin, and an ack racing muontrap's exit closes the port with
  `:epipe`, an exit signal that kills the caller (about 1 in 20 calls with
  64 running at once). Here muontrap's output window covers the whole cap,
  so nothing is ever written to it.

  The environment is the Host's (`Vagus.Runtime.Host.env/1`: the profile's
  Go limits and `CONTAINERS_CONF_OVERRIDE`) plus `:env`, which carries
  secret values so they never appear on the argv.
  """

  @global_args ["--log-level=error", "--transient-store"]
  @sigkill_delay_ms 3_000
  @default_cap 1_048_576
  # muontrap's window is a C int.
  @max_window 2_147_483_647

  @type result ::
          {:ok, binary()}
          | {:exit, pos_integer(), binary()}
          | {:error, :timeout | :unavailable | :output_too_large | :invalid_argument}

  @doc """
  Options: `:timeout_ms` (required), `:cap` (bytes, default 1 MiB),
  `:truncate` (past the cap keep the head instead of failing with
  `:output_too_large`), `:env` (`[{name, value}]`), `:podman_bin`, `:host`.
  """
  @spec run([String.t()], keyword()) :: result()
  def run(args, opts) do
    argv = @global_args ++ args

    cond do
      Enum.any?(argv, &String.contains?(&1, <<0>>)) -> {:error, :invalid_argument}
      path = System.find_executable(bin(opts)) -> spawn_podman(path, argv, opts)
      true -> {:error, :unavailable}
    end
  end

  # The binary comes from config or a test's opts, never from a request.
  # sobelow_skip ["CI.System"]
  defp spawn_podman(path, argv, opts) do
    cap = Keyword.get(opts, :cap, @default_cap)
    truncate? = Keyword.get(opts, :truncate, false)
    window = if truncate?, do: @max_window, else: min(cap + 1, @max_window)
    env = Vagus.Runtime.Host.env(opts[:host]) ++ Keyword.get(opts, :env, [])

    muontrap_args =
      ["--capture-output", "--capture-stderr", "--delay-to-sigkill", "#{@sigkill_delay_ms}"] ++
        ["--stdio-window", "#{window}", "--", path | argv]

    port =
      Port.open({:spawn_executable, Application.app_dir(:muontrap, ["priv", "muontrap"])}, [
        :use_stdio,
        :exit_status,
        :binary,
        :hide,
        args: muontrap_args,
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ])

    # The port still closes when its owner dies; unlinked, its own exit
    # never reaches a caller that traps exits.
    Process.unlink(port)

    # A deadline instant rather than a timer: no message of its own can be
    # left behind in the caller's mailbox.
    deadline = now_ms() + Keyword.fetch!(opts, :timeout_ms)

    try do
      collect(port, deadline, %{cap: cap, truncate?: truncate?, size: 0, acc: []})
    after
      flush(port)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
      {:EXIT, ^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  # The deadline is checked before every receive: `after` only fires on an
  # empty mailbox, so queued output would otherwise outrun it.
  defp collect(port, deadline, out) do
    case deadline - now_ms() do
      left when left <= 0 -> close(port, {:error, :timeout})
      left -> await(port, deadline, out, left)
    end
  end

  defp await(port, deadline, out, left) do
    receive do
      {^port, {:data, data}} ->
        case keep(out, data) do
          {:ok, out} -> collect(port, deadline, out)
          :overflow -> close(port, {:error, :output_too_large})
        end

      {^port, {:exit_status, 0}} ->
        {:ok, output(out)}

      {^port, {:exit_status, status}} ->
        {:exit, status, output(out)}
    after
      left -> close(port, {:error, :timeout})
    end
  end

  defp keep(%{size: size, cap: cap} = out, data) when size + byte_size(data) <= cap,
    do: {:ok, %{out | acc: [data | out.acc], size: size + byte_size(data)}}

  defp keep(%{truncate?: true, size: size, cap: cap} = out, data) when size < cap,
    do: {:ok, %{out | acc: [binary_part(data, 0, cap - size) | out.acc], size: cap}}

  defp keep(%{truncate?: true} = out, _data), do: {:ok, out}
  defp keep(_out, _data), do: :overflow

  defp output(%{acc: acc}), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # Closing muontrap's stdin is what makes it kill podman. muontrap exits
  # only once podman has, so waiting for it means the caller's permit never
  # outlives a podman, and a pull's spool is no longer being written.
  defp close(port, result) do
    muontrap = Port.info(port, :os_pid)
    Port.close(port)
    with {:os_pid, pid} <- muontrap, do: await_exit(pid, @sigkill_delay_ms + 2_000)
    result
  rescue
    ArgumentError -> result
  end

  defp await_exit(_pid, left) when left <= 0, do: :ok

  defp await_exit(pid, left) do
    if File.exists?("/proc/#{pid}") do
      Process.sleep(10)
      await_exit(pid, left - 10)
    end
  end

  defp bin(opts), do: opts[:podman_bin] || Application.get_env(:vagus, :podman_bin, "podman")

  @doc """
  Decodes `output` as JSON. A stray line before the document (a warning
  that slipped past `--log-level=error`) is skipped by retrying from the
  first line opening with `[` or `{`.
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, :bad_json}
  def decode(output) do
    case Jason.decode(output) do
      {:ok, term} ->
        {:ok, term}

      {:error, _} ->
        case Regex.run(~r/^[\[{].*/ms, output) do
          [json] when json != output -> decode(json)
          _ -> {:error, :bad_json}
        end
    end
  end
end
