defmodule Vagus.TargzTest do
  @moduledoc "Bounded gunzip + tar extract (decompression-bomb guard)."
  use ExUnit.Case, async: true

  alias Vagus.Targz

  # Build a .tar.gz in memory with one member.
  defp targz(name, content) do
    path =
      Path.join(System.tmp_dir!(), "vagus-targz-#{System.unique_integer([:positive])}.tar.gz")

    {:ok, t} = :erl_tar.open(String.to_charlist(path), [:write, :compressed])
    :ok = :erl_tar.add(t, content, String.to_charlist(name), [])
    :ok = :erl_tar.close(t)
    bin = File.read!(path)
    File.rm(path)
    bin
  end

  test "extracts a normal archive under the cap" do
    gz = targz("hello.txt", "hi there")
    assert {:ok, entries} = Targz.extract_capped(gz, 1_000_000)
    assert {"hello.txt", "hi there"} in entries
  end

  test "rejects a decompression bomb before it fully inflates" do
    # 8 MiB of zeros compresses tiny but blows the 64 KiB cap.
    gz = targz("bomb", :binary.copy(<<0>>, 8_000_000))
    assert {:error, :too_large} = Targz.extract_capped(gz, 65_536)
  end

  test "gunzip_capped enforces the cap directly" do
    gz = :zlib.gzip(:binary.copy(<<0>>, 1_000_000))
    assert {:error, :too_large} = Targz.gunzip_capped(gz, 1000)
    assert {:ok, out} = Targz.gunzip_capped(gz, 2_000_000)
    assert byte_size(out) == 1_000_000
  end
end
