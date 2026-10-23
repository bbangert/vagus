defmodule Vagus.API.HardwareDevicesRouterTest do
  # Points `Vagus.Devices` at a fixture tree through application env.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  import Vagus.AppFixtures
  import Vagus.DevicesFixtures

  alias Vagus.API.{Router, Token}

  @opts Router.init([])

  setup do
    ctx = "devices_route" |> tmp_root() |> bench()
    Application.put_env(:vagus, Vagus.Devices, opts(ctx))

    on_exit(fn ->
      Application.delete_env(:vagus, Vagus.Devices)
      File.rm_rf(ctx.root)
    end)

    ctx
  end

  defp get_with(header, token) do
    conn(:get, "/hardware/devices")
    |> put_req_header(header, token)
    |> Router.call(@opts)
  end

  test "Core reads the inventory as JSON", ctx do
    conn = get_with("authorization", "Bearer " <> Token.get())

    assert conn.status == 200
    assert %{"result" => "ok", "data" => %{"devices" => devices}} = Jason.decode!(conn.resp_body)
    assert Enum.map(devices, & &1["id"]) == ["usb:1-1.2", "usb:1-1.3", "usb:2-1", "sys:i2c-1"]

    [ftdi | _rest] = devices

    assert %{
             "kind" => "usb",
             "vid" => "0403",
             "pid" => "6001",
             "serial" => "A10K1234",
             "ifaces" => [],
             "hci" => []
           } = ftdi

    assert %{"path" => tty, "major" => 188, "minor" => 0, "class" => "tty"} =
             List.last(ftdi["nodes"])

    assert tty == Path.join(ctx.dev_root, "ttyUSB0")
  end

  test "an app, even an admin one, is refused" do
    token =
      register_app_token(app_config("hardware_devices_test_app"),
        identity: %{hassio_api: true, hassio_role: "admin"}
      )

    assert get_with("x-supervisor-token", token).status == 403
  end

  test "no token is a 401" do
    assert Router.call(conn(:get, "/hardware/devices"), @opts).status == 401
  end
end
