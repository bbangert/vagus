defmodule Vagus.Discovery.PushTest do
  @moduledoc """
  `Vagus.Discovery.Push` — the shared fire-and-forget Core discovery push (M5).
  `deliver/3` (the body of one queued push) is driven directly
  with an injected `request_fun` so every outcome branch — success, the expected
  `:no_refresh_token` no-op, a plain error, an exception, and an exit — is
  covered without a live `Vagus.Core.Client`.

  Each test gets a UNIQUE `uuid` (setup) and scopes its log assertions to it:
  `capture_log/1` captures logs process-wide, so under `async: true` a shared
  string would match a concurrent test's output — the uuid keeps every assertion
  specific to this test's own push.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Discovery.Push

  setup do
    uuid = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    %{msg: %{uuid: uuid, addon: "core_mqtt", service: "mqtt"}}
  end

  describe "deliver/3" do
    test "posts the uuid path + JSON body and returns :ok on success", %{msg: msg} do
      parent = self()

      req = fn method, path, opts ->
        send(parent, {:req, method, path, opts})
        {:ok, %{status: 200}}
      end

      log = capture_log(fn -> assert :ok = Push.deliver(:post, msg, req) end)

      assert_received {:req, :post, path, opts}
      assert path == "/api/hassio_push/discovery/#{msg.uuid}"
      assert {"content-type", "application/json"} in opts[:headers]

      assert %{"addon" => "core_mqtt", "service" => "mqtt", "uuid" => msg.uuid} ==
               Jason.decode!(opts[:body])

      refute log =~ "#{msg.uuid} failed"
      refute log =~ "#{msg.uuid} crashed"
    end

    test ":no_refresh_token is a debug no-op, not a warning (Core simply isn't up yet)", %{
      msg: msg
    } do
      req = fn _m, _p, _o -> {:error, :no_refresh_token} end

      dbg = capture_log([level: :debug], fn -> assert :ok = Push.deliver(:delete, msg, req) end)
      assert dbg =~ "not pushed — Core not connected"
      # This push must not have produced any warning of its own.
      refute dbg =~ "#{msg.uuid} failed"
      refute dbg =~ "#{msg.uuid} crashed"
      refute dbg =~ "#{msg.uuid} exited"
    end

    test "a plain error tuple logs a warning with the reason", %{msg: msg} do
      req = fn _m, _p, _o -> {:error, :nxdomain} end

      log = capture_log(fn -> assert :ok = Push.deliver(:post, msg, req) end)
      assert log =~ "push for #{msg.uuid} failed"
      assert log =~ "nxdomain"
    end

    test "a raising request_fun is rescued + logged, never propagated", %{msg: msg} do
      req = fn _m, _p, _o -> raise "boom" end

      log = capture_log(fn -> assert :ok = Push.deliver(:post, msg, req) end)
      assert log =~ "push for #{msg.uuid} crashed"
      assert log =~ "boom"
    end

    test "an exiting request_fun (e.g. call to an unstarted client) is caught + logged", %{
      msg: msg
    } do
      req = fn _m, _p, _o -> exit(:noproc) end

      log = capture_log(fn -> assert :ok = Push.deliver(:delete, msg, req) end)
      assert log =~ "push for #{msg.uuid} exited"
      assert log =~ "noproc"
    end
  end
end

defmodule Vagus.Discovery.PushQueueTest do
  # async: false — the queue is the application's and the seam is global.
  use ExUnit.Case, async: false

  import Vagus.AppFixtures

  alias Vagus.Discovery.Push

  defp message(n), do: %{uuid: "queue-#{n}", addon: "a", service: "s", config: %{"pw" => "x"}}

  test "a crashing push neither blocks the next nor reorders the rest" do
    test_pid = self()
    prev = Application.get_env(:vagus, :discovery_push)

    Application.put_env(:vagus, :discovery_push, fn
      _method, %{uuid: "queue-2"} -> raise "boom"
      method, message -> send(test_pid, {:pushed, method, message})
    end)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:vagus, :discovery_push),
        else: Application.put_env(:vagus, :discovery_push, prev)
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      for n <- 1..4, do: Push.notify(:post, message(n))
      assert_receive {:pushed, :post, %{uuid: "queue-1"}}, 1_000
      assert_receive {:pushed, :post, %{uuid: "queue-3"}}, 1_000
      assert_receive {:pushed, :post, %{uuid: "queue-4"}}, 1_000
    end)
  end

  test "the config, which can hold a password, is never queued" do
    capture_discovery_pushes(:pushed)
    Push.notify(:post, message(5))

    assert_receive {:pushed, :post, pushed}, 1_000
    assert pushed == %{uuid: "queue-5", addon: "a", service: "s"}
  end
end
