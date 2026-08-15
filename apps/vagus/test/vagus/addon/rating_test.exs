defmodule Vagus.Addon.RatingTest do
  use ExUnit.Case, async: true

  alias Vagus.Addon.{Config, Rating}

  defp config(raw) do
    {:ok, c} =
      Config.parse(
        Map.merge(
          %{
            "name" => "Rated",
            "version" => "1.0.0",
            "slug" => "rated",
            "description" => "rating fixture",
            "arch" => ["amd64"],
            "image" => "example/{arch}-addon-rated"
          },
          raw
        )
      )

    c
  end

  defp score(raw), do: Rating.score(config(raw))

  test "a plain add-on scores the baseline 5" do
    assert score(%{}) == 5
  end

  describe "the upstream ladder, term by term" do
    test "apparmor disabled costs a point" do
      assert score(%{"apparmor" => false}) == 4
    end

    test "ingress is worth +2 and outranks auth_api rather than stacking" do
      assert score(%{"ingress" => true}) == 7
      assert score(%{"auth_api" => true}) == 6
      assert score(%{"ingress" => true, "auth_api" => true}) == 7
    end

    test "a dangerous capability costs a point; a harmless one does not" do
      assert score(%{"privileged" => ["SYS_ADMIN"]}) == 4
      assert score(%{"privileged" => ["NET_RAW"]}) == 4
      # Not in upstream's tuple — the check is a named set, not "any capability".
      assert score(%{"privileged" => ["CHOWN"]}) == 5
    end

    test "supervisor role derates by seniority" do
      assert score(%{"hassio_role" => "manager"}) == 4
      assert score(%{"hassio_role" => "admin"}) == 3
      assert score(%{"hassio_role" => "default"}) == 5
    end

    test "host namespaces: network -1, pid -2" do
      assert score(%{"host_network" => true}) == 4
      assert score(%{"host_pid" => true}) == 3
    end

    test "host_uts only costs a point when SYS_ADMIN makes it usable" do
      assert score(%{"host_uts" => true}) == 5
      # -1 uts and -1 for the dangerous cap
      assert score(%{"host_uts" => true, "privileged" => ["SYS_ADMIN"]}) == 3
    end
  end

  describe "the not-secure override" do
    test "full_access or docker_api pins the score at 1" do
      assert score(%{"full_access" => true}) == 1
      assert score(%{"docker_api" => true}) == 1
    end

    test "the override cannot be earned back by an otherwise-safe config" do
      # Upstream assigns rather than subtracts, so +2 ingress does not offset.
      assert score(%{"full_access" => true, "ingress" => true, "auth_api" => true}) == 1
    end
  end

  describe "clamping" do
    test "the floor is 1, not a negative number" do
      worst =
        score(%{
          "apparmor" => false,
          "host_network" => true,
          "host_pid" => true,
          "host_uts" => true,
          "hassio_role" => "admin",
          "privileged" => ["SYS_ADMIN"]
        })

      assert worst == 1
    end

    test "the ceiling is 8" do
      # Nothing Vagus can express reaches 8 (signed and apparmor: profile are
      # both unreachable), so the best real config is 7 — asserted so the
      # unreachable-terms note in the moduledoc stays honest.
      assert score(%{"ingress" => true}) == 7
    end
  end

  test "devices: does not move the rating — parity with upstream" do
    # Deliberate: upstream's ladder has no devices term, even though a device
    # grant can mean raw disk access. Info's `devices` field is what reports
    # it. If this ever changes, it is a divergence and needs a ledger entry.
    assert score(%{"devices" => ["/dev/mmcblk0", "/dev/mem"]}) == 5
  end
end
