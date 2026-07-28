defmodule Vagus.Addon.Store.AssetModeTest do
  @moduledoc "P2-A P0: boot-time resolution of the store's asset retention mode."
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Addon.Store.AssetMode
  alias Vagus.Platform.Memory

  @gib 1024 * 1024 * 1024

  defp with_total(bytes_or_error), do: [total_bytes: fn -> bytes_or_error end]

  defp resolve(configured, opts), do: capture_log(fn -> AssetMode.resolve(configured, opts) end)

  describe ":auto threshold" do
    test "exactly 1 GiB stays in memory" do
      assert :memory = AssetMode.resolve(:auto, with_total({:ok, @gib}))
    end

    test "one byte under 1 GiB goes to disk" do
      assert :disk = AssetMode.resolve(:auto, with_total({:ok, @gib - 1}))
    end

    test "a real rpi3 MemTotal (~0.93 GiB) goes to disk" do
      assert :disk = AssetMode.resolve(:auto, with_total({:ok, 970_644 * 1024}))
    end

    test "a Q6A-class board (8 GiB) stays in memory" do
      assert :memory = AssetMode.resolve(:auto, with_total({:ok, 8 * @gib}))
    end

    test "threshold_bytes/0 is the documented 1 GiB" do
      assert AssetMode.threshold_bytes() == @gib
    end
  end

  describe ":auto with no usable MemTotal" do
    test "fails open to memory rather than switching a device to disk writes" do
      assert :memory = AssetMode.resolve(:auto, with_total(:error))
    end

    test "an unreadable /proc/meminfo path reaches the same fail-open path" do
      missing = Path.join(System.tmp_dir!(), "vagus_asset_mode_no_meminfo")
      refute File.exists?(missing)

      assert :memory =
               AssetMode.resolve(:auto, total_bytes: fn -> Memory.total_bytes(missing) end)
    end
  end

  describe "explicit configuration" do
    test ":memory wins over detection that would say disk" do
      assert :memory = AssetMode.resolve(:memory, with_total({:ok, 1}))
    end

    test ":disk wins over detection that would say memory" do
      assert :disk = AssetMode.resolve(:disk, with_total({:ok, 64 * @gib}))
    end

    test "an invalid value warns and falls back to detection" do
      log = resolve("disk", with_total({:ok, @gib - 1}))

      assert log =~ ~s(ignoring invalid :store_asset_mode "disk")
      assert :disk = AssetMode.resolve("disk", with_total({:ok, @gib - 1}))
    end
  end

  describe "config default" do
    test "nil reads config :vagus, :store_asset_mode (:memory under config/test.exs)" do
      assert Application.get_env(:vagus, :store_asset_mode) == :memory
      assert :memory = AssetMode.resolve(nil, with_total({:ok, 1}))
    end
  end

  describe "the boot log line" do
    test "names the mode and the MemTotal that drove it" do
      log = resolve(:auto, with_total({:ok, 970_644 * 1024}))

      assert log =~ "store asset mode :disk"
      assert log =~ "MemTotal #{970_644 * 1024} bytes"
    end

    test "says so when MemTotal was unavailable" do
      log = resolve(:auto, with_total(:error))

      assert log =~ "store asset mode :memory"
      assert log =~ "MemTotal unavailable"
    end

    test "distinguishes an explicit setting from a detected one" do
      assert resolve(:disk, []) =~ "store asset mode :disk (configured explicitly)"
    end
  end
end
