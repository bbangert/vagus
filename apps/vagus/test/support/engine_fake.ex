defmodule Vagus.Runtime.Engine.Fake do
  @moduledoc """
  In-memory `Vagus.Runtime.Engine`, one instance per test: pass
  `engine: Vagus.Runtime.Engine.Fake, fake: pid` in a call's opts. Code that
  takes no per-call opts (the router) reaches it through
  `config :vagus, engine: Fake, engine_fake: pid` instead, which is global:
  only `async: false` tests may use it.

  Creating from an image the fake does not hold, or onto a bridge never
  `ensure_network`ed, is `{:failed, :create, :image_not_found |
  :network_not_found}`, as `Engine.Docker` reports them.
  `calls/1` logs each callback as `{verb, args}`; `call_opts/1` logs the same
  calls as `{verb, opts}`, without the dispatch keys.
  `fail_next(fake, :stop, e)` also fails the next stop inside `stop_all/3`.
  `delay_next(fake, verb, ms)` makes the next call of `verb` take `ms`: one
  given a smaller `timeout_ms` is `:timeout` and changes nothing; no call
  actually sleeps.

  `put_container/3` makes a running container from any `Container` field
  (`state:` overrides) plus `:logs` (text, or a list of chunks a follow
  delivers verbatim, as an engine that already stamped and split them),
  `:follow_open` (a follow stays open after the last chunk, until its owner
  exits), `:stats` (the computed map) and `:exec` (`{code, output}` or a
  function of the argv returning one).
  """

  @behaviour Vagus.Runtime.Engine

  use Agent

  import Kernel, except: [inspect: 2]

  alias Vagus.Runtime.Engine.{Container, ContainerSpec, NetworkSpec}
  alias Vagus.Runtime.Stats

  def start(opts \\ []) do
    {:ok, pid} = start_link(opts)
    pid
  end

  def start_link(_opts \\ []) do
    Agent.start_link(fn ->
      %{
        images: MapSet.new(),
        containers: %{},
        networks: MapSet.new(),
        fail: %{},
        blocks: %{},
        calls: []
      }
    end)
  end

  @doc "A fake that callers without per-call opts reach through app env; restored on exit."
  def start_global do
    fake = start()
    keys = [:engine, :engine_fake]
    previous = for key <- keys, do: {key, Application.fetch_env(:vagus, key)}
    Application.put_env(:vagus, :engine, __MODULE__)
    Application.put_env(:vagus, :engine_fake, fake)

    ExUnit.Callbacks.on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:vagus, key, value)
          :error -> Application.delete_env(:vagus, key)
        end
      end
    end)

    fake
  end

  def put_image(fake, ref), do: Agent.update(fake, &%{&1 | images: MapSet.put(&1.images, ref)})

  def put_container(fake, name, attrs \\ []) do
    attrs = Map.new(attrs)
    {extras, fields} = Map.split(attrs, [:logs, :stats, :exec, :follow_open])

    container =
      struct!(
        %Container{id: new_id(), name: name, state: :running, labels: %{}, env: %{}, ips: %{}},
        Map.delete(fields, :name)
      )

    entry = Map.merge(%{container: container, spec: nil, logs: "", stats: nil, exec: nil}, extras)
    Agent.update(fake, &put_in(&1, [:containers, name], entry))
  end

  def set_state(fake, name, state) do
    Agent.update(fake, &put_in(&1, [:containers, name, :container, Access.key!(:state)], state))
  end

  # stop_all has no error return; fail its inner stops with `:stop`.
  def fail_next(_fake, :stop_all, _error), do: raise(ArgumentError, "fail_next(:stop) instead")

  def fail_next(fake, verb, error) do
    Agent.update(fake, fn s -> update_in(s, [:fail, Access.key(verb, [])], &(&1 ++ [error])) end)
  end

  def delay_next(fake, verb, ms), do: fail_next(fake, verb, {:delay, ms})

  @doc """
  Holds the next call of `verb` in its caller until `release/1`: the caller
  sends `{:fake_blocked, verb, pid}` to the process that called this.
  """
  def block_next(fake, verb) do
    notify = self()

    Agent.update(fake, fn s ->
      update_in(s, [:blocks, Access.key(verb, [])], &(&1 ++ [notify]))
    end)
  end

  def release(blocked_pid), do: send(blocked_pid, :fake_release)

  def calls(fake),
    do:
      Agent.get(
        fake,
        &(&1.calls |> Enum.reverse() |> Enum.map(fn {verb, args, _opts} -> {verb, args} end))
      )

  def call_opts(fake),
    do:
      Agent.get(
        fake,
        &(&1.calls |> Enum.reverse() |> Enum.map(fn {verb, _args, opts} -> {verb, opts} end))
      )

  def spec(fake, name), do: Agent.get(fake, &get_in(&1, [:containers, name, :spec]))

  @impl true
  def ready(opts), do: call(opts, :ready, [], &{:ok, &1})

  @impl true
  def pull(image, opts) do
    call(opts, :pull, [image], &{:ok, %{&1 | images: MapSet.put(&1.images, image)}})
  end

  @impl true
  def image_present?(image, opts) do
    call(opts, :image_present?, [image], &{MapSet.member?(&1.images, image), &1})
  end

  @impl true
  def remove_image(image, opts) do
    call(opts, :remove_image, [image], fn s ->
      if Enum.any?(s.containers, fn {_name, e} -> e.container.image == image end),
        do: {{:error, :in_use}, s},
        else: {:ok, %{s | images: MapSet.delete(s.images, image)}}
    end)
  end

  @impl true
  def create(%ContainerSpec{name: name, image: image} = spec, opts) do
    call(opts, :create, [spec], fn s ->
      cond do
        Map.has_key?(s.containers, name) ->
          {{:error, :conflict}, s}

        not MapSet.member?(s.images, image) ->
          {{:error, {:failed, :create, :image_not_found}}, s}

        match?({:bridge, _}, spec.network) and
            not MapSet.member?(s.networks, elem(spec.network, 1)) ->
          {{:error, {:failed, :create, :network_not_found}}, s}

        true ->
          container = %Container{
            id: new_id(),
            name: name,
            image: image,
            state: :created,
            labels: spec.labels || %{},
            env: Map.new(spec.env || []),
            ips: %{}
          }

          entry = %{container: container, spec: spec, logs: "", stats: nil, exec: nil}
          {{:ok, container.id}, put_in(s, [:containers, name], entry)}
      end
    end)
  end

  @impl true
  def start(name, opts) do
    call(
      opts,
      :start,
      [name],
      &update_container(&1, name, fn
        %Container{state: :running} = c -> c
        c -> run(c)
      end)
    )
  end

  @impl true
  def stop(name, opts), do: call(opts, :stop, [name], &do_stop(&1, name))

  @impl true
  def restart(name, opts) do
    call(opts, :restart, [name], &update_container(&1, name, fn c -> run(c) end))
  end

  @impl true
  def stop_all(names, timeout_s, opts) do
    # Delays add up, as sequential stops share one budget of every grace.
    floor = length(names) * grace_ms(timeout_s)

    call(opts, :stop_all, [names, timeout_s], fn s ->
      {s, stopped, failed, _elapsed} =
        Enum.reduce(names, {s, [], [], 0}, fn name, {s, stopped, failed, elapsed} ->
          {failure, s} = pop_failure(s, :stop)
          elapsed = elapsed + delay_ms(failure)

          {s, stopped, failed} =
            stop_step(s, name, stopped, failed, failure, timed_out?(opts, elapsed, floor))

          {s, stopped, failed, elapsed}
        end)

      {{:ok, Enum.reverse(stopped), Enum.reverse(failed)}, s}
    end)
  end

  @impl true
  def remove(name, opts) do
    force = Keyword.get(opts, :force, true)

    call(opts, :remove, [name], fn s ->
      case s.containers[key(s, name)] do
        nil ->
          {:ok, s}

        %{container: %{state: state}}
        when not force and state in [:running, :paused, :restarting] ->
          {{:error, {:failed, :remove, state}}, s}

        _entry ->
          {:ok, %{s | containers: Map.delete(s.containers, key(s, name))}}
      end
    end)
  end

  @impl true
  def inspect(name, opts),
    do: call(opts, :inspect, [name], &read(&1, name, fn e -> {:ok, e.container} end))

  @impl true
  def list(opts) do
    all = Keyword.get(opts, :all, false)
    prefix = opts[:name_prefix] || ""

    call(opts, :list, [], fn s ->
      containers =
        for {name, %{container: c}} <- Enum.sort(s.containers),
            all or c.state in [:running, :paused, :restarting],
            String.starts_with?(name, prefix),
            do: summary(c)

      {{:ok, containers}, s}
    end)
  end

  @impl true
  def logs(name, opts) do
    call(
      opts,
      :logs,
      [name],
      &read(&1, name, fn e -> {:ok, e.logs |> lines(opts) |> Enum.join()} end)
    )
  end

  @impl true
  def follow_logs(name, owner, opts) do
    case call(
           opts,
           :follow_logs,
           [name, owner],
           &{follow_plan(&1.containers[key(&1, name)], opts), &1}
         ) do
      {:error, error} ->
        {:error, error}

      {chunks, open?} ->
        {:ok, spawn_link(fn -> stream(owner, Process.monitor(owner), chunks, open?) end)}
    end
  end

  @impl true
  def stats(name, opts) do
    call(opts, :stats, [name], &read(&1, name, fn e -> {:ok, e.stats || Stats.zero()} end))
  end

  @impl true
  def exec(name, argv, opts) do
    capture = Keyword.get(opts, :capture, true)

    call(opts, :exec, [name, argv], &read(&1, name, fn e -> run_exec(e, argv, capture) end))
  end

  @impl true
  def healthcheck(name, opts) do
    call(opts, :healthcheck, [name], fn s ->
      read(s, name, fn
        %{container: %{healthcheck: nil}} -> {:error, :no_healthcheck}
        %{container: %{health: nil}} -> {:error, :no_healthcheck}
        %{container: %{health: health}} -> {:ok, health}
      end)
    end)
  end

  @impl true
  def ensure_network(%NetworkSpec{name: net} = spec, opts) do
    call(opts, :ensure_network, [spec], &{:ok, %{&1 | networks: MapSet.put(&1.networks, net)}})
  end

  # A container answers to its name or its id, as with Docker.
  defp key(s, ref) do
    if Map.has_key?(s.containers, ref),
      do: ref,
      else: Enum.find_value(s.containers, fn {name, e} -> e.container.id == ref && name end)
  end

  defp call(opts, verb, args, fun) do
    fake = instance(opts)

    case Agent.get_and_update(fake, &pop_block(&1, verb)) do
      nil ->
        :ok

      notify ->
        send(notify, {:fake_blocked, verb, self()})

        receive do
          :fake_release -> :ok
        after
          10_000 ->
            raise "Engine.Fake: #{verb} blocked by block_next/2 was never released (call release/1)"
        end
    end

    Agent.get_and_update(fake, fn s ->
      entry = {verb, args, Keyword.drop(opts, [:engine, :fake])}

      case pop_failure(%{s | calls: [entry | s.calls]}, verb) do
        {nil, s} ->
          fun.(s)

        {{:delay, ms}, s} ->
          if timed_out?(opts, ms, grace_floor(verb, opts)),
            do: {{:error, :timeout}, s},
            else: fun.(s)

        {error, s} ->
          {{:error, error}, s}
      end
    end)
  end

  defp instance(opts) do
    case {opts[:fake], Application.fetch_env(:vagus, :engine_fake)} do
      {nil, {:ok, fake}} ->
        fake

      {nil, :error} ->
        raise ArgumentError,
              "no Engine.Fake instance: pass fake: pid, or call start_global/0 in an async: false test"

      {fake, _global} ->
        fake
    end
  end

  defp timed_out?(opts, ms, floor),
    do: is_integer(opts[:timeout_ms]) and ms > max(opts[:timeout_ms], floor)

  # The same floor Engine.Docker gives a stop: timeout_ms never cuts a grace short.
  defp grace_floor(verb, opts) when verb in [:stop, :restart] do
    if seconds = opts[:timeout_s], do: grace_ms(seconds), else: 0
  end

  defp grace_floor(_verb, _opts), do: 0

  defp grace_ms(seconds), do: seconds * 1000 + 10_000

  defp delay_ms({:delay, ms}), do: ms
  defp delay_ms(_failure), do: 0

  defp pop_block(s, verb) do
    case s.blocks do
      %{^verb => [notify | rest]} -> {notify, put_in(s, [:blocks, verb], rest)}
      _none -> {nil, s}
    end
  end

  defp pop_failure(s, verb) do
    case s.fail do
      %{^verb => [error | rest]} -> {error, put_in(s, [:fail, verb], rest)}
      _none -> {nil, s}
    end
  end

  defp read(s, name, fun) do
    case s.containers[key(s, name)] do
      nil -> {{:error, :not_found}, s}
      entry -> {fun.(entry), s}
    end
  end

  defp update_container(s, name, fun) do
    case key(s, name) do
      nil -> {{:error, :not_found}, s}
      key -> {:ok, update_in(s, [:containers, key, :container], fun)}
    end
  end

  defp do_stop(s, name), do: update_container(s, name, &halt/1)

  defp stop_step(s, name, stopped, failed, _failure, true = _timed_out),
    do: {s, stopped, [{name, :timeout} | failed]}

  defp stop_step(s, name, stopped, failed, nil, false), do: stop_one(s, name, stopped, failed)

  defp stop_step(s, name, stopped, failed, {:delay, _ms}, false),
    do: stop_one(s, name, stopped, failed)

  defp stop_step(s, name, stopped, failed, error, false),
    do: {s, stopped, [{name, error} | failed]}

  defp stop_one(s, name, stopped, failed) do
    case do_stop(s, name) do
      {:ok, s} -> {s, [name | stopped], failed}
      {{:error, :not_found}, s} -> {s, [name | stopped], failed}
    end
  end

  defp run(%Container{} = c) do
    health = if c.healthcheck, do: :starting
    %{c | state: :running, exit_code: nil, health: health, started_at: DateTime.utc_now()}
  end

  defp halt(%Container{state: state} = c) when state in [:running, :paused, :restarting],
    do: %{c | state: :exited, exit_code: 0, finished_at: DateTime.utc_now()}

  defp halt(c), do: c

  defp summary(c) do
    %Container{
      id: c.id,
      name: c.name,
      image: c.image,
      state: c.state,
      labels: c.labels,
      exit_code: c.exit_code
    }
  end

  defp run_exec(%{container: %{state: state}}, _argv, _capture) when state != :running,
    do: {:error, {:failed, :exec, :not_running}}

  defp run_exec(entry, argv, capture) do
    {code, output} =
      case entry.exec do
        nil -> {0, ""}
        fun when is_function(fun, 1) -> fun.(argv)
        result -> result
      end

    {:ok, %{exit_code: code, output: if(capture, do: output, else: "")}}
  end

  # Line N is stamped N ns past a fixed instant, in Docker's RFC3339Nano form,
  # so a stamp is deterministic and survives `:tail`.
  defp follow_plan(nil, _opts), do: {[], false}

  defp follow_plan(entry, opts),
    do: {lines(entry.logs, opts), Map.get(entry, :follow_open, false)}

  defp lines(chunks, _opts) when is_list(chunks), do: chunks

  defp lines(text, opts) do
    tail = Keyword.get(opts, :tail, 100)

    lines =
      text
      |> String.split(~r/(?<=\n)/, trim: true)
      |> Enum.with_index(1)
      |> Enum.map(fn {line, n} -> stamp(line, n, Keyword.get(opts, :timestamps, false)) end)

    if is_integer(tail), do: Enum.take(lines, -tail), else: lines
  end

  defp stamp(line, _n, false), do: line

  defp stamp(line, n, true),
    do: "2026-10-14T21:00:00.#{String.pad_leading(Integer.to_string(n), 9, "0")}Z " <> line

  defp stream(_owner, ref, [], true) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end

  defp stream(owner, ref, [], false) do
    send(owner, :log_eof)
    Process.demonitor(ref, [:flush])
  end

  defp stream(owner, ref, [chunk | rest], open?) do
    send(owner, {:log_chunk, chunk})

    receive do
      :log_ack -> stream(owner, ref, rest, open?)
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end

  defp new_id, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
end
