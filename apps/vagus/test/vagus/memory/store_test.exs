defmodule Vagus.Memory.StoreTest do
  use ExUnit.Case, async: true

  alias Vagus.Memory

  @big String.duplicate("a", 65_537)
  @long_name String.duplicate("é", 257)

  # The caps are checked before the store is asked anything, so no store
  # needs to run.
  @opts [store: __MODULE__.Absent]

  test "texts over 64 KiB and names over 256 characters are too large" do
    assert Memory.remember("fact", nil, @big, @opts) == {:error, :too_large}
    assert Memory.remember(@long_name, nil, "x", @opts) == {:error, :too_large}
    assert Memory.remember("fact", @long_name, "x", @opts) == {:error, :too_large}
    assert Memory.recall(@big, @opts) == {:error, :too_large}
    assert Memory.journal("t", @big, @opts) == {:error, :too_large}
    assert Memory.device_note("d", @big, @opts) == {:error, :too_large}
    assert Memory.forget(1, @big, @opts) == {:error, :too_large}

    refs = Enum.to_list(1..65)
    assert Memory.remember("fact", nil, "x", [refs: refs] ++ @opts) == {:error, :too_large}
  end

  test "a 256-character name is within the cap" do
    name = String.duplicate("é", 256)
    assert Memory.remember(name, nil, "x", @opts) == {:error, :unavailable}
  end

  test "tombstone is a reserved kind" do
    assert Memory.remember("tombstone", nil, "x", @opts) == {:error, :reserved_kind}
  end

  test "text Postgres cannot hold, and malformed arguments, are invalid" do
    assert Memory.remember("fact", nil, "a\0b", @opts) == {:error, :invalid}
    assert Memory.remember("fact", nil, <<0xFF>>, @opts) == {:error, :invalid}
    assert Memory.remember("", nil, "x", @opts) == {:error, :invalid}
    assert Memory.recall("  ", @opts) == {:error, :invalid}
    assert Memory.recall("x", [k: 0] ++ @opts) == {:error, :invalid}
    assert Memory.recall("x", [k: 101] ++ @opts) == {:error, :invalid}
    assert Memory.forget(0, "x", @opts) == {:error, :invalid}
    assert Memory.forget(1, "x", [replaced_by: 1] ++ @opts) == {:error, :invalid}
    assert Memory.capture_register("/p", :meta, @opts) == {:error, :invalid}

    assert Memory.remember("fact", nil, "x", [refs: [{:a, :tuple}]] ++ @opts) ==
             {:error, :invalid}
  end

  test "with no store running, an operation is unavailable" do
    assert Memory.recall("kettle", @opts) == {:error, :unavailable}
    assert Memory.status(@opts) == {:error, :unavailable}
  end
end
