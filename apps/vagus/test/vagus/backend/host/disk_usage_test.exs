defmodule Vagus.Backend.Host.DiskUsageTest do
  use ExUnit.Case, async: true

  alias Vagus.Backend.Host.DiskUsage

  # A captured, realistic `df -k` two-line output fixture (filesystem name
  # deliberately long, like an overlay/tmpfs mount, to exercise the
  # whitespace-column split rather than a fixed-width parse).
  @df_output """
  Filesystem     1K-blocks     Used Available Use% Mounted on
  /dev/mmcblk0p4  33554432 23068672  10485760  69% /data
  """

  describe "parse/1" do
    test "converts KB columns to GB floats as {free, total, used}" do
      assert DiskUsage.parse(@df_output) == {10.0, 32.0, 22.0}
    end

    test "falls back to {0.0, 0.0, 0.0} on unparseable output" do
      assert DiskUsage.parse("not df output at all\n") == {0.0, 0.0, 0.0}
    end

    test "falls back to {0.0, 0.0, 0.0} on empty output" do
      assert DiskUsage.parse("") == {0.0, 0.0, 0.0}
    end
  end

  describe "usage_gb/1" do
    test "returns floats for a real, existing path (the test working directory)" do
      {free, total, used} = DiskUsage.usage_gb(".")

      assert is_float(free)
      assert is_float(total)
      assert is_float(used)
      assert total >= 0.0
    end

    test "falls back to {0.0, 0.0, 0.0} for a path df can't stat" do
      assert DiskUsage.usage_gb("/definitely/not/a/real/path/xyz") == {0.0, 0.0, 0.0}
    end
  end
end
