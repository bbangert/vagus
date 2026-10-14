defmodule Vagus.Runtime.Engine.Fake do
  @moduledoc """
  In-memory `Vagus.Runtime.Engine`, one instance per test: pass
  `engine: Vagus.Runtime.Engine.Fake, fake: pid` in a call's opts.

  Creating from an image the fake does not hold, or onto a bridge never
  `ensure_network`ed, is `{:failed, :create, :image_not_found |
  :network_not_found}`, as `Engine.Docker` reports them.
  `calls/1` logs each callback as `{verb, args}` without its opts.
  `fail_next(fake, :stop, e)` also fails the next stop inside `stop_all/3`.
  `delay_next(fake, verb, ms)` makes the next call of `verb` take `ms`: one
  given a smaller `timeout_ms` is `:timeout` and changes nothing; no call
  actually sleeps.

  `put_container/3` makes a running container from any `Container` field
  (`state:` overrides) plus `:logs` (text),
  `:stats` (the computed map) and `:exec` (`{code, output}` or a function of
  the argv returning one).
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
      %{images: MapSet.new(), containers: %{}, networks: MapSet.new(), fail: %{}, calls: []}
    end)
  end

  def put_image(fake, ref), do: Agent.update(fake, &%{&1 | images: MapSet.put(&1.images, ref)})

  def put_container(fake, name, attrs \\ []) do
    attrs = Map.new(attrs)
    {extras, fields} = Map.split(attrs, [:logs, :stats, :exec])

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

  def calls(fake), do: Agent.get(fake, &Enum.reverse(&1.calls))

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
      case s.containers[name] do
        nil ->
          {:ok, s}

        %{container: %{state: :running}} when not force ->
          {{:error, {:failed, :remove, :running}}, s}

        _entry ->
          {:ok, %{s | containers: Map.delete(s.containers, name)}}
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
            all or c.state == :running,
            String.starts_with?(name, prefix),
            do: summary(c)

      {{:ok, containers}, s}
    end)
  end

  @impl true
  def logs(name, opts) do
    tail = Keyword.get(opts, :tail, 100)

    call(
      opts,
      :logs,
      [name],
      &read(&1, name, fn e -> {:ok, e.logs |> lines(tail) |> Enum.join()} end)
    )
  end

  @impl true
  def follow_logs(name, owner, opts) do
    tail = Keyword.get(opts, :tail, 100)

    case call(
           opts,
           :follow_logs,
           [name, owner],
           &{(&1.containers[name] && lines(&1.containers[name].logs, tail)) || [], &1}
         ) do
      {:error, error} -> {:error, error}
      chunks -> {:ok, spawn_link(fn -> stream(owner, Process.monitor(owner), chunks) end)}
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

  defp call(opts, verb, args, fun) do
    fake = Keyword.fetch!(opts, :fake)

    Agent.get_and_update(fake, fn s ->
      case pop_failure(%{s | calls: [{verb, args} | s.calls]}, verb) do
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

  defp pop_failure(s, verb) do
    case s.fail do
      %{^verb => [error | rest]} -> {error, put_in(s, [:fail, verb], rest)}
      _none -> {nil, s}
    end
  end

  defp read(s, name, fun) do
    case s.containers[name] do
      nil -> {{:error, :not_found}, s}
      entry -> {fun.(entry), s}
    end
  end

  defp update_container(s, name, fun) do
    case s.containers[name] do
      nil -> {{:error, :not_found}, s}
      entry -> {:ok, put_in(s, [:containers, name, :container], fun.(entry.container))}
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

  defp halt(%Container{state: :running} = c),
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

  defp lines(text, tail) do
    lines = String.split(text, ~r/(?<=\n)/, trim: true)
    if is_integer(tail), do: Enum.take(lines, -tail), else: lines
  end

  defp stream(owner, ref, []) do
    send(owner, :log_eof)
    Process.demonitor(ref, [:flush])
  end

  defp stream(owner, ref, [chunk | rest]) do
    send(owner, {:log_chunk, chunk})

    receive do
      :log_ack -> stream(owner, ref, rest)
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end

  defp new_id, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
end
