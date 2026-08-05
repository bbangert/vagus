defmodule Vagus.DiagnosticsTest do
  # RingLogger is a single process-wide backend/buffer; async: true would let
  # other tests' log lines land concurrently and pollute assertions.
  use ExUnit.Case, async: false

  require Logger

  alias Vagus.Diagnostics

  setup do
    {:ok, _} = Application.ensure_all_started(:ring_logger)
    Logger.add_backend(RingLogger)
    on_exit(fn -> Logger.remove_backend(RingLogger) end)
    :ok
  end

  # Unique per test run so assertions filter on our own lines rather than on
  # exact buffer counts/positions, which other concurrent activity could shift.
  setup do
    tag = System.unique_integer([:positive])

    %{
      provisioner_msg: "Vagus.Provisioner: engine ready (#{tag})",
      other_msg: "something else (#{tag})"
    }
  end

  test "matches a substring pattern against the message, not other lines", %{
    provisioner_msg: provisioner_msg,
    other_msg: other_msg
  } do
    Logger.info(provisioner_msg)
    Logger.info(other_msg)
    Process.sleep(150)

    assert [matched] = Diagnostics.ring_grep(provisioner_msg)
    assert matched =~ provisioner_msg
    refute matched =~ other_msg
  end

  test "matches a Regex pattern", %{provisioner_msg: provisioner_msg} do
    Logger.info(provisioner_msg)
    Process.sleep(150)

    assert [matched] = Diagnostics.ring_grep(~r/engine ready/)
    assert matched =~ provisioner_msg
  end

  test "a pattern matching nothing returns an empty list" do
    assert Diagnostics.ring_grep("no-such-pattern-anywhere-xyz") == []
  end

  # Regression pin for issue #2's root cause: the hand-rolled filter assumed
  # RingLogger.get/2 returned {level, {_, msg, _, _}} tuples. It returns maps.
  # If a future ring_logger bump changes this shape, this assertion fails
  # loudly here instead of silently reintroducing the phantom log-drop bug.
  test "RingLogger.get/2 entries are maps, not tuples" do
    Logger.info("shape pin")
    Process.sleep(150)

    entries = RingLogger.get(0, 0)
    assert entries != []
    assert Enum.all?(entries, &is_map/1)
  end
end
