defmodule Vagus.Test.FakePodman do
  @moduledoc """
  A scripted `podman` executable in a per-test temp dir, aimed at with
  `podman_bin: fake.bin`.

  Rules match the argv after podman's global flags, joined by spaces, as a
  shell glob (`"container inspect *"`); the first matching rule answers.
  Each rule holds responses used in order, the last one repeating:
  `{exit_status, output}`, or `{exit_status, output, delay_ms: n}`. An
  output of `:killed` makes the fake SIGKILL itself. `info` answers 0
  unless a rule says otherwise; anything unscripted exits 125.

  Every invocation is logged: `calls/1` returns each argv (globals
  included) and `envs/1` the matching `NAME=value` lines of the env it
  ran with, for names given in `:log_env`.
  """

  defstruct [:dir, :bin]

  def start(rules, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "fake-podman-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    bin = Path.join(dir, "podman")

    rules = rules ++ [{"info*", [{0, "6.1.4\n"}]}]
    cases = rules |> Enum.with_index() |> Enum.map_join("\n", &rule_case(&1, dir))
    log_env = Enum.map_join(Keyword.get(opts, :log_env, []), " ", &"\"#{&1}=${#{&1}-}\"")

    File.write!(bin, """
    #!/bin/sh
    dir=#{dir}
    printf '%s\\037' "$@" >> "$dir/calls"
    printf '\\n' >> "$dir/calls"
    for kv in #{log_env}; do printf '%s\\037' "$kv" >> "$dir/envs"; done
    printf '\\n' >> "$dir/envs"
    while :; do
      case "$1" in
        --log-level=*|--transient-store) shift ;;
        *) break ;;
      esac
    done
    answer() {
      n=$(cat "$dir/r$1.n" 2>/dev/null || echo 0)
      n=$((n + 1))
      [ "$n" -gt "$2" ] && n=$2
      echo "$n" > "$dir/r$1.n"
      [ -f "$dir/r$1.$n.delay" ] && sleep "$(cat "$dir/r$1.$n.delay")"
      [ -f "$dir/r$1.$n.kill" ] && kill -9 $$
      cat "$dir/r$1.$n.out"
      exit "$(cat "$dir/r$1.$n.code")"
    }
    case "$*" in
    #{cases}
      *) echo "Error: fake podman: unscripted: $*" >&2; exit 125 ;;
    esac
    """)

    File.chmod!(bin, 0o755)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    %__MODULE__{dir: dir, bin: bin}
  end

  defp rule_case({{glob, responses}, i}, dir) do
    responses
    |> Enum.with_index(1)
    |> Enum.each(fn {response, n} -> write_response(dir, i, n, response) end)

    "  #{sh_glob(glob)}) answer #{i} #{length(responses)} ;;"
  end

  # Literal pieces single-quoted, so spaces and `$` match as themselves.
  defp sh_glob(glob), do: glob |> String.split("*") |> Enum.map_join("*", &"'#{&1}'")

  defp write_response(dir, i, n, {code, output}),
    do: write_response(dir, i, n, {code, output, []})

  defp write_response(dir, i, n, {code, output, opts}) do
    base = Path.join(dir, "r#{i}.#{n}")
    File.write!(base <> ".code", to_string(code))
    if output == :killed, do: File.write!(base <> ".kill", "")
    File.write!(base <> ".out", if(output == :killed, do: "", else: output))
    if ms = opts[:delay_ms], do: File.write!(base <> ".delay", to_string(ms / 1000))
  end

  def calls(%__MODULE__{dir: dir}), do: read_log(dir, "calls")
  def envs(%__MODULE__{dir: dir}), do: read_log(dir, "envs")

  defp read_log(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, log} ->
        log |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, "\x1f", trim: true))

      {:error, :enoent} ->
        []
    end
  end

  @doc "The calls without podman's global flags."
  def verbs(fake), do: Enum.map(calls(fake), &Enum.drop(&1, 2))

  @doc """
  A `Vagus.Runtime.Host` under the test's supervisor, preparing in a temp
  dir with `bin` as podman; returns its name once its probe has answered,
  and flunks if it never does. `root:` names the temp dir (its
  `storage/tmp` is the spool), `await: false` skips the wait, and any other
  option goes to the Host.
  """
  def start_host(bin, opts \\ []) do
    {root, opts} =
      Keyword.pop_lazy(opts, :root, fn ->
        Path.join(System.tmp_dir!(), "podman-host-#{System.unique_integer([:positive])}")
      end)

    {await?, opts} = Keyword.pop(opts, :await, true)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)
    name = :"podman_host_#{System.unique_integer([:positive])}"

    host_opts =
      Keyword.merge(
        [
          name: name,
          podman_bin: bin,
          graphroot: Path.join(root, "storage"),
          run_dir: Path.join(root, "run"),
          meminfo: Path.join(root, "no-meminfo"),
          profile_override: Path.join(root, "no-override"),
          socket_dir: Path.join(root, "supervisor"),
          resolv_conf: Path.join(root, "resolv.conf"),
          log_dir: Path.join(root, "logs"),
          mountinfo: empty_mountinfo(root),
          name_servers: fn -> [] end,
          run: fn _bin, _args -> {"", 0} end,
          shutting_down?: fn -> false end,
          prep_retry_ms: 60_000
        ],
        opts
      )

    ExUnit.Callbacks.start_supervised!({Vagus.Runtime.Host, host_opts})
    if await?, do: await_answer(name)
    name
  end

  defp empty_mountinfo(root) do
    File.mkdir_p!(root)
    path = Path.join(root, "mountinfo")
    File.write!(path, "")
    path
  end

  # The probe has answered, either way; a failing one is some tests' point.
  defp await_answer(name) do
    Enum.find_value(1..1_000, fn _ ->
      case Vagus.Runtime.Host.ready(name) do
        {:error, :preparing} -> Process.sleep(10) && nil
        answered -> answered
      end
    end) || ExUnit.Assertions.flunk("Host #{name} still preparing after 10 s")
  end
end
