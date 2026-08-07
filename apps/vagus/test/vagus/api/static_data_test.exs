defmodule Vagus.API.StaticDataTest do
  # async: false — these tests mutate the :vagus application env
  # (`:machine`) to prove the value is read at runtime rather than baked in
  # at compile time.
  use ExUnit.Case, async: false

  import Mox

  alias Vagus.API.StaticData
  alias Vagus.Core.HttpConfig

  defmodule FakeCore do
    @moduledoc false
    # Core's socket listener, for the `core_info/0 port + ssl` tests below.
    # Answers with whatever the test's Agent currently holds, so the same
    # listener serves the "Core moved to 80" response and then the
    # restore-to-defaults one.
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/api/core/http_config" do
      send_resp(conn, 200, Jason.encode!(Agent.get(Vagus.API.StaticDataTest.Script, & &1)))
    end
  end

  # `root_info/0` calls `Vagus.Backend.os().info()`, so this module needs a
  # live OS mock. It cannot rely on the ambient `stub_with/2` delegation
  # from test_helper.exs: Mox's global mode ties stub ownership to whichever
  # process last called `set_mox_global/1`, and
  # `Vagus.API.RouterBackendTest` re-claims it for itself (see its
  # moduledoc). Both modules are `async: false`, so they share the sync
  # phase and the ambient stubs are already dead if that module ran first —
  # which is exactly how this failed in CI (seed 661416) while passing
  # locally under a seed that ordered it the other way. Re-claiming
  # ownership and re-stubbing here makes the module order-independent.
  setup :set_mox_global

  setup do
    stub_with(Vagus.Backend.OSMock, Vagus.Backend.OS.HostStub)
    :ok
  end

  describe "machine (board identity)" do
    test "root_info/0 and core_info/0 report the CONFIGURED machine, not a literal" do
      configured = Application.get_env(:vagus, :machine)

      # Not a vacuous-pass guard — without it this test would still fail if
      # the key went missing (`StaticData.machine/0` raises now, and even
      # under the old defaulted read a nil `configured` could not match a
      # non-nil fallback). It exists purely to turn that into a one-line
      # "you forgot config/test.exs" instead of the ArgumentError
      # `fetch_env!/2` raises, or a confusing nil-vs-string diff.
      refute is_nil(configured),
             "config :vagus, :machine must be set (see config/test.exs)"

      assert StaticData.root_info()[:machine] == configured
      assert StaticData.core_info()[:machine] == configured
    end

    test "both endpoints follow a target that configures a different machine" do
      # "generic-aarch64" is what config/dragon_q6a.exs sets — a real HAOS
      # machine, and the reason this value stopped being a module attribute.
      original = Application.get_env(:vagus, :machine)
      Application.put_env(:vagus, :machine, "generic-aarch64")
      on_exit(fn -> Application.put_env(:vagus, :machine, original) end)

      assert StaticData.root_info()[:machine] == "generic-aarch64"
      assert StaticData.core_info()[:machine] == "generic-aarch64"
    end

    test "raises rather than reporting some other board when the key is missing" do
      original = Application.get_env(:vagus, :machine)
      Application.delete_env(:vagus, :machine)
      on_exit(fn -> Application.put_env(:vagus, :machine, original) end)

      # The point of the config indirection: a board that forgets to set
      # :machine must fail loudly, not quietly claim to be a Raspberry Pi.
      assert_raise ArgumentError, fn -> StaticData.root_info() end
      assert_raise ArgumentError, fn -> StaticData.core_info() end
    end

    test "arch stays fixed across boards — both targets are aarch64" do
      assert StaticData.root_info()[:arch] == "aarch64"
      assert StaticData.root_info()[:supported_arch] == ["aarch64"]
      assert StaticData.core_info()[:arch] == "aarch64"
    end
  end

  ## A4: `core_info/0`'s port/ssl are Core's own, cached by
  ## `Vagus.Core.HttpConfig` from `GET /api/core/http_config` over the
  ## Supervisor↔Core socket. Every test here points
  ## `:core_http_config_server` at a private cache instance rather than
  ## touching the shared, app-supervised one (the same seam the router's
  ## `:core_versions_server` uses).

  describe "core_info/0 port + ssl" do
    test "with no socket (host dev / this suite) they are HttpConfig's defaults" do
      use_http_config(start_http_config())

      assert StaticData.core_info()[:port] == 8123
      assert StaticData.core_info()[:ssl] == false
      assert HttpConfig.defaults() == %{port: 8123, ssl: false, server_host: nil}
    end

    test "a Core that reports port 80 + ssl is reported honestly" do
      cache = start_http_config()
      use_http_config(cache)

      path = fake_core_socket(%{"port" => 80, "ssl" => true, "server_host" => "0.0.0.0"})
      assert HttpConfig.refresh(server: cache, transport: {:socket, path}) == :ok

      assert StaticData.core_info()[:port] == 80
      assert StaticData.core_info()[:ssl] == true
    end

    test "a cache that is down reports the defaults rather than 500-ing the endpoint" do
      cache = start_http_config()
      use_http_config(cache)
      :ok = stop_supervised!(cache)

      assert StaticData.core_info()[:port] == 8123
    end
  end

  defp start_http_config do
    name = :"static_data_http_config_#{System.unique_integer([:positive])}"

    start_supervised!(%{id: name, start: {HttpConfig, :start_link, [[name: name]]}})

    name
  end

  defp use_http_config(name) do
    Application.put_env(:vagus, :core_http_config_server, name)
    on_exit(fn -> Application.delete_env(:vagus, :core_http_config_server) end)
  end

  defp fake_core_socket(response) do
    path =
      Path.join(System.tmp_dir!(), "vagus_static_data_#{System.unique_integer([:positive])}.sock")

    start_supervised!(%{
      id: __MODULE__.Script,
      start: {Agent, :start_link, [fn -> response end, [name: __MODULE__.Script]]}
    })

    start_supervised!(
      {Bandit,
       plug: FakeCore,
       port: 0,
       thousand_island_options: [num_acceptors: 1, transport_options: [ip: {:local, path}]]},
      id: :fake_core_socket
    )

    on_exit(fn -> File.rm(path) end)
    path
  end
end
