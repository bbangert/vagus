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

  With `:stderr_apart`, stdout goes to a file instead (podman's own
  `--out`, which replaces Go's `os.Stdout` before the verb runs) and only
  stderr comes through muontrap, whose one output stream cannot tell the two
  apart. A warning podman prints then never lands inside the JSON a caller
  parses, and podman's error text still reaches `Runtime.Podman.Error`. The
  file lives on the Host's own small tmpfs (`Vagus.Runtime.Host.out_dir/1`).
  While the Host has none the call is merged as any other, its pipe bounding
  podman where a file on the shared /run would not; with no Host it is
  `:unavailable`. The Host removes a holder's file should the holder die
  mid-call.

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
          | {:error,
             :timeout
             | :unavailable
             | :output_too_large
             | :invalid_argument
             | {:out_file, File.posix()}}

  # How often a split call with nothing arriving on stderr rechecks its
  # stdout file against the cap.
  @out_poll_ms 100
  # Every page size Linux uses is a multiple of this.
  @page_bytes 4096

  @spec default_cap() :: pos_integer()
  def default_cap, do: @default_cap

  @doc "How long a podman can outlive the port it was started from."
  @spec kill_budget_ms() :: pos_integer()
  def kill_budget_ms, do: @sigkill_delay_ms + 2_000

  @doc """
  Options: `:timeout_ms` (required), `:cap` (bytes, default 1 MiB),
  `:truncate` (past the cap keep the head instead of failing with
  `:output_too_large`), `:discard_stdout` (stdout never leaves muontrap;
  only stderr is returned), `:stderr_apart` (stdout alone on success,
  stderr alone on failure; raises with `:discard_stdout` or `:truncate`),
  `:out_dir` (where its stdout file goes instead of the Host's; tests),
  `:env` (`[{name, value}]`), `:podman_bin`, `:host`.
  """
  @spec run([String.t()], keyword()) :: result()
  def run(args, opts) do
    apart? = Keyword.get(opts, :stderr_apart, false)

    if apart? and (opts[:discard_stdout] || opts[:truncate]),
      do: raise(ArgumentError, ":stderr_apart takes neither :discard_stdout nor :truncate")

    cond do
      Enum.any?(args, &String.contains?(&1, <<0>>)) -> {:error, :invalid_argument}
      path = System.find_executable(bin(opts)) -> start(path, args, apart?, opts)
      true -> {:error, :unavailable}
    end
  end

  defp start(path, args, true, opts), do: run_apart(path, args, opts)
  defp start(path, args, false, opts), do: spawn_podman(path, @global_args ++ args, opts)

  # The name is unique, so the Host's cleanup after a dead caller can only
  # ever remove that caller's file. The Host learns it before the file
  # exists: a caller killed in between leaves nothing to remove. The file is
  # made here, so a successful podman whose file is gone had it removed
  # under it (a Host restarting mid-call sweeps the dir), not an empty
  # answer. The path is the Host's dir and a name made here, never input.
  # sobelow_skip ["Traversal.FileModule"]
  defp run_apart(path, args, opts) do
    dir = if d = opts[:out_dir], do: {:ok, d}, else: Vagus.Runtime.Host.out_dir(opts[:host])

    case dir do
      :unavailable ->
        {:error, :unavailable}

      :unbounded ->
        spawn_podman(path, @global_args ++ args, opts)

      {:ok, dir} ->
        name = "podman-#{System.pid()}-#{System.unique_integer([:positive])}.out"
        out = Path.join(dir, name)
        Vagus.Runtime.Host.track_out(opts[:host], out)

        try do
          case File.write(out, "", [:exclusive]) do
            :ok ->
              argv = @global_args ++ ["--out=" <> out] ++ args
              spawn_podman(path, argv, Keyword.put(opts, :out, out))

            {:error, :enospc} ->
              {:error, :output_too_large}

            {:error, reason} ->
              {:error, {:out_file, reason}}
          end
        after
          File.rm(out)
        end
    end
  end

  defp spawn_podman(path, argv, opts) do
    cap = Keyword.get(opts, :cap, @default_cap)
    truncate? = Keyword.get(opts, :truncate, false)
    window = if truncate?, do: @max_window, else: min(cap + 1, @max_window)
    env = Vagus.Runtime.Host.env(opts[:host]) ++ Keyword.get(opts, :env, [])

    # A split call's podman writes stdout to its `--out` file, not fd 1.
    # Discarded stdout goes to /dev/null inside muontrap (muontrap.c, the
    # `capture_stderr_only` branch of the child's setup), so none of it ever
    # reaches the BEAM; stderr, where podman reports its own failures, is
    # still read.
    capture =
      if Keyword.get(opts, :discard_stdout, false) or opts[:out] != nil,
        do: ["--capture-stderr-only"],
        else: ["--capture-output", "--capture-stderr"]

    muontrap_args =
      capture ++
        ["--delay-to-sigkill", "#{@sigkill_delay_ms}", "--stdio-window", "#{window}"] ++
        ["--", path | argv]

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
      collect(port, deadline, %{cap: cap, truncate?: truncate?, size: 0, acc: [], out: opts[:out]})
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
  # empty mailbox, so queued output would otherwise outrun it. A split
  # call's stdout file is checked there too: no pipe blocks a podman writing
  # past the cap into it.
  defp collect(port, deadline, out) do
    case deadline - now_ms() do
      left when left <= 0 ->
        close(port, {:error, :timeout})

      left ->
        if over_cap?(out),
          do: close(port, {:error, :output_too_large}),
          else: await(port, deadline, out, left)
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
        if out.out, do: read_out(out), else: {:ok, output(out)}

      {^port, {:exit_status, status}} ->
        {:exit, status, output(out)}
    after
      wait(out, left) ->
        if out.out, do: collect(port, deadline, out), else: close(port, {:error, :timeout})
    end
  end

  defp wait(%{out: nil}, left), do: left
  defp wait(_out, left), do: min(left, @out_poll_ms)

  defp over_cap?(%{out: nil}), do: false

  defp over_cap?(%{out: path, cap: cap}) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size > cap
      {:error, _} -> false
    end
  end

  # The path is one run_apart/3 made, never input.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_out(%{out: path, cap: cap}) do
    with {:ok, %{size: size}} <- File.stat(path),
         true <- size <= cap || {:error, :too_large},
         {:ok, result} <- File.open(path, [:read, :append, :binary, :raw], &read_whole(&1, size)) do
      result
    else
      {:error, :too_large} -> {:error, :output_too_large}
      {:error, :enoent} -> {:error, :unavailable}
      {:error, reason} -> {:error, {:out_file, reason}}
    end
  end

  # podman exits 0 when its stdout hits a full filesystem, leaving the
  # output cut short at a page boundary, as nothing else ends it. Such a
  # file is probed with one more byte: ENOSPC means the cut was the tmpfs
  # filling, not the end of podman's answer.
  defp read_whole(fd, size) do
    with {:ok, data} <- read_bytes(fd, size),
         :ok <- if(rem(byte_size(data), @page_bytes) == 0, do: :file.write(fd, <<0>>), else: :ok) do
      {:ok, data}
    else
      {:error, :enospc} -> {:error, :output_too_large}
      {:error, reason} -> {:error, {:out_file, reason}}
    end
  end

  defp read_bytes(fd, size) do
    case :file.read(fd, size) do
      {:ok, data} -> {:ok, data}
      :eof -> {:ok, ""}
      {:error, _} = error -> error
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
    with {:os_pid, pid} <- muontrap, do: await_exit(pid, kill_budget_ms())
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
