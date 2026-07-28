defmodule Vagus.VersionTest do
  @moduledoc """
  P2-A P2: the one comparator behind `update_available`, shared by HA Core
  and add-ons.
  """
  use ExUnit.Case, async: true

  alias Vagus.Version

  describe "update_available?/2" do
    test "differing versions mean an update is available" do
      assert Version.update_available?("7.1.0", "7.2.0")
    end

    test "equal versions do not" do
      refute Version.update_available?("7.1.0", "7.1.0")
    end

    test "an unknown latest is not an update" do
      # A detached add-on (installed, no longer in its repository) and a
      # failed version fetch land here. Reporting `true` would render an
      # update button with nothing behind it.
      refute Version.update_available?("7.1.0", nil)
    end

    test "an unknown installed version is not an update" do
      refute Version.update_available?(nil, "7.2.0")
    end

    test "both unknown is not an update" do
      refute Version.update_available?(nil, nil)
    end

    test "non-binary inputs are refused rather than compared" do
      refute Version.update_available?(7, 8)
      refute Version.update_available?(:a, :b)
      refute Version.update_available?(%{}, "1.0")
    end

    test "comparison is exact, not semantic" do
      # Add-on versions are opaque publisher-chosen tags — semver, dates,
      # build ids. "differs" is the only question answerable without knowing
      # the publisher's scheme.
      assert Version.update_available?("1.0", "1.0.0")
      assert Version.update_available?("2025.1.0", "2025.2.0")
      assert Version.update_available?(" 1.0", "1.0")
    end

    test "a store downgrade also reads as an update" do
      # A repository yanking a bad release and re-advertising the previous
      # tag: the store's current version is what should be running, so
      # offering the change is correct (and is upstream's behaviour).
      assert Version.update_available?("7.2.0", "7.1.0")
    end
  end
end
