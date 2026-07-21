defmodule Vagus.Addon.ProbeURLTest do
  @moduledoc """
  `docs/contract-2026.7-m4b-ingress-watchdog.md` §B7.2 grammar/rendering —
  pure, no process, fully hermetic.
  """

  use ExUnit.Case, async: true

  alias Vagus.Addon.ProbeURL

  defp cfg(overrides \\ %{}) do
    Map.merge(%{host_network: false, ports: %{}}, overrides)
  end

  describe "watchdog_spec/4" do
    test "tcp://[HOST]:8080 -> tcp, port substituted, host substituted" do
      assert {:ok, %{proto: "tcp", host: "1.2.3.4", port: 8080, suffix: ""}} =
               ProbeURL.watchdog_spec("tcp://[HOST]:8080", cfg(), %{}, "1.2.3.4")
    end

    test "http://[HOST]:[PORT:80]/health -> port 80 + suffix /health" do
      assert {:ok, %{proto: "http", host: "1.2.3.4", port: 80, suffix: "/health"}} =
               ProbeURL.watchdog_spec("http://[HOST]:[PORT:80]/health", cfg(), %{}, "1.2.3.4")
    end

    test "[PROTO:ssl]://[HOST]:[PORT:8443]/x -> https when options[ssl] is truthy" do
      assert {:ok, %{proto: "https", port: 8443, suffix: "/x"}} =
               ProbeURL.watchdog_spec(
                 "[PROTO:ssl]://[HOST]:[PORT:8443]/x",
                 cfg(),
                 %{"ssl" => true},
                 "1.2.3.4"
               )
    end

    test "[PROTO:ssl]://[HOST]:[PORT:8443]/x -> http when options[ssl] is falsy" do
      assert {:ok, %{proto: "http", port: 8443}} =
               ProbeURL.watchdog_spec(
                 "[PROTO:ssl]://[HOST]:[PORT:8443]/x",
                 cfg(),
                 %{"ssl" => false},
                 "1.2.3.4"
               )

      assert {:ok, %{proto: "http"}} =
               ProbeURL.watchdog_spec(
                 "[PROTO:ssl]://[HOST]:[PORT:8443]/x",
                 cfg(),
                 %{},
                 "1.2.3.4"
               )
    end

    test "host_network + ports mapping -> host-mapped port" do
      config = cfg(%{host_network: true, ports: %{"80/tcp" => 8080}})

      assert {:ok, %{port: 8080}} =
               ProbeURL.watchdog_spec("http://[HOST]:[PORT:80]/", config, %{}, "1.2.3.4")
    end

    test "host_network but port not in ports map -> literal port" do
      config = cfg(%{host_network: true, ports: %{"81/tcp" => 8081}})

      assert {:ok, %{port: 80}} =
               ProbeURL.watchdog_spec("http://[HOST]:[PORT:80]/", config, %{}, "1.2.3.4")
    end

    test "bridge network (host_network: false) ignores the ports map entirely" do
      config = cfg(%{host_network: false, ports: %{"80/tcp" => 8080}})

      assert {:ok, %{port: 80}} =
               ProbeURL.watchdog_spec("http://[HOST]:[PORT:80]/", config, %{}, "1.2.3.4")
    end

    test "garbage template -> :error" do
      assert :error = ProbeURL.watchdog_spec("not a url at all", cfg(), %{}, "1.2.3.4")
    end
  end

  describe "webui_url/3" do
    test "port mapping is unconditional (no host_network branch) + [HOST] stays literal" do
      config = cfg(%{ports: %{"8099/tcp" => 31_337}})

      assert ProbeURL.webui_url("http://[HOST]:[PORT:8099]/dash", config, %{}) ==
               "http://[HOST]:31337/dash"
    end

    test "unconditional mapping applies even without host_network: true" do
      config = cfg(%{host_network: false, ports: %{"8099/tcp" => 31_337}})

      assert ProbeURL.webui_url("http://[HOST]:[PORT:8099]/dash", config, %{}) ==
               "http://[HOST]:31337/dash"
    end

    test "[PROTO:ssl] variant" do
      config = cfg(%{ports: %{"443/tcp" => 8443}})

      assert ProbeURL.webui_url("[PROTO:ssl]://[HOST]:[PORT:443]/", config, %{"ssl" => true}) ==
               "https://[HOST]:8443/"

      assert ProbeURL.webui_url("[PROTO:ssl]://[HOST]:[PORT:443]/", config, %{"ssl" => false}) ==
               "http://[HOST]:8443/"
    end

    test "port not in the ports map falls back to the literal port" do
      config = cfg(%{ports: %{}})

      assert ProbeURL.webui_url("http://[HOST]:[PORT:8099]/dash", config, %{}) ==
               "http://[HOST]:8099/dash"
    end

    test "bare-literal-port template (invalid for webui grammar) -> nil" do
      assert ProbeURL.webui_url("http://[HOST]:8080/dash", cfg(), %{}) == nil
    end

    test "tcp:// is invalid for webui grammar -> nil" do
      assert ProbeURL.webui_url("tcp://[HOST]:[PORT:8080]/", cfg(), %{}) == nil
    end

    test "nil template -> nil" do
      assert ProbeURL.webui_url(nil, cfg(), %{}) == nil
    end
  end
end
