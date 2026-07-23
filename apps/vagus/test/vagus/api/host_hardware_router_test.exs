defmodule Vagus.API.HostHardwareRouterTest do
  @moduledoc """
  Router tests for the survey-P1 trio: `/host/disks/default/usage`,
  `/hardware/info`, `/os/datadisk/list` (vagus-supervisor-api
  endpoint-survey.md). Shape-level assertions — the breakdown/enumeration
  logic itself is covered by the DiskBreakdown/Hardware unit tests.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Vagus.API.{Router, Token}

  @opts Router.init([])

  defp get_authed(path) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer " <> Token.get())
    |> Router.call(@opts)
  end

  defp json_data(conn) do
    body = Jason.decode!(conn.resp_body)
    assert body["result"] == "ok"
    body["data"]
  end

  test "GET /host/disks/default/usage returns the root breakdown node" do
    conn = get_authed("/host/disks/default/usage")

    assert conn.status == 200
    data = json_data(conn)
    assert data["id"] == "root"
    assert data["label"] == "Root"
    assert is_integer(data["total_bytes"])
    assert is_integer(data["used_bytes"])
    assert [%{"id" => "system"} | known] = data["children"]

    assert Enum.map(known, & &1["id"]) ==
             ~w(addons_data addons_config media share backup ssl homeassistant)
  end

  test "GET /host/disks/default/usage tolerates a garbage max_depth" do
    conn = get_authed("/host/disks/default/usage?max_depth=banana")
    assert conn.status == 200
    assert json_data(conn)["id"] == "root"
  end

  test "GET /hardware/info returns devices + empty drives" do
    conn = get_authed("/hardware/info")

    assert conn.status == 200
    data = json_data(conn)
    assert is_list(data["devices"])
    assert data["drives"] == []

    # The dev machine's real /sys guarantees at least one device; every
    # entry carries the full upstream device_struct key set.
    assert [device | _rest] = data["devices"]

    assert Map.keys(device) |> Enum.sort() ==
             ~w(attributes by_id children dev_path name subsystem sysfs)
  end

  test "GET /os/datadisk/list returns honestly empty lists" do
    conn = get_authed("/os/datadisk/list")

    assert conn.status == 200
    assert json_data(conn) == %{"devices" => [], "disks" => []}
  end

  test "all three routes require auth" do
    for path <- [
          "/host/disks/default/usage",
          "/hardware/info",
          "/os/datadisk/list"
        ] do
      conn = conn(:get, path) |> Router.call(@opts)
      assert conn.status == 401, "#{path} did not 401 without a token"
    end
  end
end
