defmodule Vagus.AppFixtures do
  @moduledoc """
  Seeds and cleans up installed apps for tests.

  Tests must not know where app facts live: they install, register and
  inspect apps only through this module, so when the store behind
  `Vagus.App` changes, only this file changes with it.
  """

  import ExUnit.Assertions, only: [assert_receive: 2]
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Vagus.Addon.Config
  alias Vagus.App.File, as: AppFile
  alias Vagus.App.{Instances, Policy}

  @settings [:watchdog, :boot, :ingress_panel, :protected, :auto_update, :ports, :ingress_port]

  @spec app_config(String.t(), map()) :: Config.t()
  def app_config(slug, overrides \\ %{}) do
    {:ok, config} =
      %{
        "name" => "Test App",
        "version" => "1",
        "slug" => slug,
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y"
      }
      |> Map.merge(overrides)
      |> Config.parse()

    config
  end

  @doc """
  Writes the app's file and (re)starts its process, which reads it.
  Installing a slug again keeps its ingress token, user options and settings,
  as a reinstall over a live app does. `state: :started` is the engine
  reporting the app's container started, as the process would hear it;
  `process: false` leaves the app with no process behind it, as after a
  process start that failed.
  """
  @spec install_app(Config.t(), keyword()) :: Config.t()
  def install_app(%Config{slug: slug} = config, opts \\ []) do
    {state, opts} = Keyword.pop(opts, :state, :stopped)
    {process?, changes} = Keyword.pop(opts, :process, true)
    check_keys!(changes)

    saved =
      case AppFile.read(slug) do
        {:ok, saved} -> saved
        _absent_or_unreadable -> nil
      end

    data = Policy.init_data(slug, saved)
    token = data.ingress_token || Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    data =
      Enum.reduce(changes, %{data | config: config, wanted: state, ingress_token: token}, &put/2)

    :ok = Instances.stop(slug)
    :ok = AppFile.write(data)
    if process?, do: start_process(slug, state)

    on_exit(fn -> forget_app(slug) end)
    config
  end

  defp put({:options, options}, data), do: %{data | user_options: options}
  defp put({key, value}, data), do: Map.put(data, key, value)

  defp start_process(slug, state) do
    {:ok, pid} = Instances.ensure(slug)

    if state == :started do
      send(
        pid,
        {:docker_event, %{action: "start", id: "fixture-" <> slug, name: "addon_" <> slug}}
      )

      _ = :sys.get_state(pid)
    end

    pid
  end

  @doc """
  Changes an installed app's options and settings mid-test, taking the same
  keys as `install_app/2` bar `:state`. `:ingress_port` is not a setting
  `Vagus.App` exposes, so it is written to the app's file and the process
  restarted to read it.
  """
  @spec set_app(String.t(), keyword()) :: :ok
  def set_app(slug, changes) do
    check_keys!(changes)
    {ingress_port, changes} = Keyword.split(changes, [:ingress_port])
    if changes != [], do: :ok = Vagus.App.set(slug, changes)

    if ingress_port != [] do
      {:ok, saved} = AppFile.read(slug)
      {:ok, %{state: state}} = Vagus.App.info(slug)
      data = Enum.reduce(ingress_port, Policy.init_data(slug, saved), &put/2)
      :ok = Instances.stop(slug)
      :ok = AppFile.write(data)
      start_process(slug, if(state in [:startup, :started], do: :started, else: :stopped))
    end

    :ok
  end

  defp check_keys!(changes) do
    Enum.each(changes, fn {key, _value} ->
      unless key == :options or key in @settings,
        do: raise(ArgumentError, "unknown app fixture option #{inspect(key)}")
    end)
  end

  @doc """
  A token is only ever issued to an installed app, and is held by its
  process, so an app not yet installed is installed here and forgotten again
  at exit. What a token grants comes from the app's config, so `identity:`
  grants are written into the config. `installed: false` returns a token no
  app holds, as for one that outlived its app.
  """
  @spec register_app_token(Config.t(), keyword()) :: String.t()
  def register_app_token(%Config{slug: slug} = config, opts \\ []) do
    token = Keyword.get_lazy(opts, :token, fn -> random_token() end)

    if Keyword.get(opts, :installed, true) do
      grants = Keyword.get(opts, :identity, %{})

      case Vagus.App.info(slug) do
        {:ok, entry} when grants != %{} ->
          state = if entry.state in [:startup, :started], do: :started, else: :stopped
          install_app(grant(entry.config, grants), state: state)

        {:ok, _entry} ->
          :ok

        :error ->
          install_app(grant(config, grants))
      end

      [{pid, _slug}] = Registry.lookup(Vagus.App.Directory, {:slug, slug})
      :ok = :gen_statem.call(pid, {:test_token, token})
    end

    token
  end

  defp grant(config, grants) do
    Enum.reduce(grants, config, fn
      {:slug, _slug}, config ->
        config

      {:services_role, roles}, config ->
        %{config | services: for({service, role} <- roles, do: "#{service}:#{role}")}

      {key, value}, config ->
        Map.replace!(config, key, value)
    end)
  end

  @spec app_info(String.t()) :: {:ok, map()} | :error
  def app_info(slug), do: Vagus.App.info(slug)

  @spec app_list() :: [map()]
  def app_list, do: Vagus.App.list()

  @doc """
  For tests that install through a route, so no fixture call exists to hang
  cleanup on, and for simulating a concurrent uninstall mid-test. The file
  goes first, so nothing that heals a missing process brings this one back,
  and again after the stop, since an operation the process was finishing may
  have written it since.
  """
  @spec forget_app(String.t()) :: :ok
  def forget_app(slug) do
    :ok = AppFile.delete(slug)
    :ok = Instances.stop(slug)
    :ok = AppFile.delete(slug)
  end

  @doc "Hands every app step to the calling test through `Vagus.App.StepsStub`."
  @spec stub_app_steps() :: :ok
  def stub_app_steps do
    put_env_for_test(:app_steps, Vagus.App.StepsStub)
    put_env_for_test(:app_steps_test_pid, self())
  end

  @doc "Hands every URL probe to the calling test through `Vagus.App.ProbeStub`."
  @spec stub_app_probe() :: :ok
  def stub_app_probe do
    put_env_for_test(:app_probe, Vagus.App.ProbeStub)
    put_env_for_test(:app_steps_test_pid, self())
  end

  @doc """
  Sets step deadlines and the process's timers (`:retry`, `:settled`,
  `:probe`, `:probe_deadline`, `:new`) for this test, by name, in ms or as a
  function of the default.
  """
  @spec app_deadlines(map()) :: :ok
  def app_deadlines(deadlines), do: put_env_for_test(:app_deadlines, deadlines)

  defp put_env_for_test(key, value) do
    prev = Application.fetch_env(:vagus, key)
    Application.put_env(:vagus, key, value)

    on_exit(fn ->
      case prev do
        {:ok, value} -> Application.put_env(:vagus, key, value)
        :error -> Application.delete_env(:vagus, key)
      end
    end)
  end

  @doc "Sends `{tag, method, message}` to the test for each discovery push, in delivery order."
  @spec capture_discovery_pushes(atom()) :: :ok
  def capture_discovery_pushes(tag \\ :discovery_push) do
    test_pid = self()
    prev = Application.get_env(:vagus, :discovery_push)

    Application.put_env(:vagus, :discovery_push, fn method, message ->
      send(test_pid, {tag, method, message})
      :ok
    end)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:vagus, :discovery_push),
        else: Application.put_env(:vagus, :discovery_push, prev)
    end)
  end

  @doc """
  Returns once every push queued before it is delivered, so a `refute_received`
  after it is not racing the queue.
  """
  @spec drain_discovery_pushes(atom()) :: :ok
  def drain_discovery_pushes(tag \\ :discovery_push) do
    uuid = "drain-#{System.unique_integer([:positive])}"
    Vagus.Discovery.Push.notify(:delete, %{uuid: uuid, addon: "", service: ""})
    assert_receive {^tag, :delete, %{uuid: ^uuid}}, 5_000
    :ok
  end

  @doc """
  Stalls the push queue behind one held push and returns its pusher; send it
  `:release` to let the queue go. Every other push is sent to the test as
  `{tag, method, message}`.
  """
  @spec hold_discovery_queue(atom()) :: pid()
  def hold_discovery_queue(tag) do
    test_pid = self()
    hold = "hold-#{System.unique_integer([:positive])}"
    prev = Application.get_env(:vagus, :discovery_push)

    Application.put_env(:vagus, :discovery_push, fn
      _method, %{uuid: ^hold} ->
        send(test_pid, {:discovery_queue_held, self()})

        receive do
          :release -> :ok
        after
          5_000 -> exit(:queue_never_released)
        end

      method, message ->
        send(test_pid, {tag, method, message})
        :ok
    end)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:vagus, :discovery_push),
        else: Application.put_env(:vagus, :discovery_push, prev)
    end)

    :ok = Vagus.Discovery.Push.notify(:delete, %{uuid: hold, addon: "", service: ""})
    assert_receive {:discovery_queue_held, pusher}, 5_000
    pusher
  end

  @doc "Releases a `hold_discovery_queue/1` and returns every push after it as `{method, uuid}`, in delivery order."
  @spec release_discovery_queue(pid(), atom()) :: [{:post | :delete, String.t()}]
  def release_discovery_queue(pusher, tag) do
    send(pusher, :release)
    drain = "drain-#{System.unique_integer([:positive])}"
    :ok = Vagus.Discovery.Push.notify(:delete, %{uuid: drain, addon: "", service: ""})
    collect_pushes(tag, drain, [])
  end

  defp collect_pushes(tag, drain, acc) do
    receive do
      {^tag, :delete, %{uuid: ^drain}} -> Enum.reverse(acc)
      {^tag, method, %{uuid: uuid}} -> collect_pushes(tag, drain, [{method, uuid} | acc])
    after
      5_000 ->
        raise "discovery queue never drained; delivered so far: #{inspect(Enum.reverse(acc))}"
    end
  end

  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  @doc "Points `:api_port` at a socket of ours: the test env runs no API listener."
  @spec listening_api_port() :: :gen_tcp.socket()
  def listening_api_port do
    previous = Application.fetch_env(:vagus, :api_port)
    {:ok, socket} = :gen_tcp.listen(0, active: false)
    {:ok, port} = :inet.port(socket)
    Application.put_env(:vagus, :api_port, port)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:vagus, :api_port, value)
        :error -> Application.delete_env(:vagus, :api_port)
      end
    end)

    socket
  end
end
