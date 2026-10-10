defmodule Vagus.BackupMemoryTest do
  # Sync, so no async test's binaries land in the node-wide sample.
  use ExUnit.Case, async: false

  alias Vagus.Backup

  @file_bytes 1_048_576
  @files 32
  # The tree is 32 MiB, incompressible; holding it, or the inner tar, would
  # go far past this.
  @ceiling 16 * @file_bytes

  setup do
    root = Path.join(System.tmp_dir!(), "vagus-bkmem-#{System.unique_integer([:positive])}")
    data = Path.join(root, "data")
    File.mkdir_p!(data)

    for i <- 1..@files,
        do: File.write!(Path.join(data, "f#{i}"), :crypto.strong_rand_bytes(@file_bytes))

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, addon: %{slug: "x", version: "1", data_dir: data, system: %{"name" => "X"}}}
  end

  test "an app's snapshot peaks at a few files of binary memory, not its tree", ctx do
    inner = Path.join(ctx.root, "x.tar.gz")
    assert peak_binary(fn -> Backup.write_addon_tar(ctx.addon, inner) end) < @ceiling
  end

  test "the outer tar copies a staged inner tar without loading it", ctx do
    inner = Path.join(ctx.root, "x.tar.gz")
    :ok = Backup.write_addon_tar(ctx.addon, inner)
    assert File.stat!(inner).size > @files * @file_bytes

    spec = %{
      slug: "m",
      name: "n",
      supervisor_version: "2026.07.3",
      addons: [%{slug: "x", inner: inner}]
    }

    to = Path.join(ctx.root, "outer.tar")
    assert peak_binary(fn -> {:ok, ^to} = Backup.create(spec, to: to) end) < @ceiling
  end

  # Node-wide, sampled throughout `fun`, since the bytes may sit in erl_tar's
  # file process rather than the caller's.
  defp peak_binary(fun) do
    :erlang.garbage_collect()
    base = :erlang.memory(:binary)
    sampler = Task.async(fn -> sample(base) end)

    try do
      fun.()
    after
      send(sampler.pid, :stop)
    end

    Task.await(sampler) - base
  end

  defp sample(peak) do
    receive do
      :stop -> peak
    after
      1 -> sample(max(peak, :erlang.memory(:binary)))
    end
  end
end
