defmodule Vagus.Core.SupportedTest do
  # async: false — the enforce tests flip process-global app env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.Core.Supported
  alias Vagus.Test.ContractFixture

  @ceiling Supported.version()

  defp unenforced(_context) do
    Application.put_env(:vagus, Supported, enforce: false)
    on_exit(fn -> Application.delete_env(:vagus, Supported) end)
  end

  # A fixture bump that forgets the ceiling (or the reverse) fails here.
  test "the ceiling is the Core release the hassio-views fixture was dumped from" do
    assert Supported.version() == ContractFixture.core_views_tag()
  end

  describe "newer?/1" do
    test "orders HA's YYYY.M.P numerically, not as strings" do
      assert Supported.newer?("2026.12.0")
      assert Supported.newer?("2026.11.1")
      assert Supported.newer?("2027.1.0")
      refute Supported.newer?(@ceiling)
      refute Supported.newer?("2026.10.3")
      refute Supported.newer?("2026.9.0")
      refute Supported.newer?("2025.12.5")
    end

    test "betas, release candidates and dev builds sort below their release" do
      refute Supported.newer?("2026.11.0b3")
      refute Supported.newer?("2026.11.0rc1")
      refute Supported.newer?("2026.11.0.dev20261101")
      assert Supported.newer?("2026.12.0b0")
      assert Supported.newer?("2026.12.0.dev20261105")
    end

    test "a zero-padded month still parses" do
      refute Supported.newer?("2026.07.3")
      assert Supported.newer?("2026.012.0")
    end

    test "anything unparsable counts as newer, so it is refused" do
      for junk <- ["latest", "stable", "", "2026.11", "2026.11.0-foo", "v2026.11.0", nil, 2026] do
        assert Supported.newer?(junk), "expected #{inspect(junk)} to count as newer"
      end
    end
  end

  describe "latest/2" do
    test "installed below the ceiling: the lesser of feed and ceiling" do
      assert Supported.latest("2026.10.0", "2026.12.1") == @ceiling
      assert Supported.latest("2026.10.0", "2026.10.2") == "2026.10.2"
      assert Supported.latest(nil, "2026.12.1") == @ceiling
    end

    test "installed at or above the ceiling: the installed version" do
      assert Supported.latest(@ceiling, "2026.12.1") == @ceiling
      assert Supported.latest("2026.12.0", "2026.12.1") == "2026.12.0"
    end

    test "an unknown feed stays unknown" do
      assert Supported.latest("2026.10.0", nil) == nil
      assert Supported.latest(@ceiling, nil) == nil
    end
  end

  describe "held?/2" do
    test "needs a feed above the ceiling and above the installed version" do
      assert Supported.held?("2026.10.0", "2026.12.1")
      assert Supported.held?(@ceiling, "2026.12.1")
      assert Supported.held?(nil, "2026.12.1")
    end

    test "an upstream rollback below the ceiling is not held" do
      refute Supported.held?(@ceiling, "2026.10.2")
      refute Supported.held?("2026.12.0", "2026.10.2")
      refute Supported.held?("2026.10.0", "2026.10.2")
    end

    test "a feed at or below the installed version is not held" do
      refute Supported.held?("2026.12.1", "2026.12.1")
      refute Supported.held?("2027.1.0", "2026.12.1")
    end
  end

  describe "permit/2" do
    test "refuses a target above the ceiling" do
      assert Supported.permit("2026.12.0", "2026.10.0") ==
               {:error, {:unsupported_core, "2026.12.0", @ceiling}}

      assert {:error, _} = Supported.permit("junk", "2026.10.0")
    end

    test "allows the ceiling, a downgrade, and the installed version" do
      assert Supported.permit(@ceiling, "2026.10.0") == :ok
      assert Supported.permit("2026.9.0", "2026.10.0") == :ok
      assert Supported.permit("2026.12.0", "2026.12.0") == :ok
    end
  end

  describe "enforce: false" do
    setup :unenforced

    test "clamps and refuses nothing" do
      assert Supported.latest("2026.10.0", "2026.12.1") == "2026.12.1"
      assert Supported.permit("2026.12.0", "2026.10.0") == :ok
      refute Supported.held?("2026.10.0", "2026.12.1")
    end

    test "warns" do
      assert capture_log(fn -> Supported.warn_if_unenforced() end) =~ "enforce is off"
    end
  end

  test "enforced, it does not warn" do
    assert capture_log(fn -> Supported.warn_if_unenforced() end) == ""
  end
end
