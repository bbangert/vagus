defmodule Vagus.ProbeParity.VolatileAllowlistTest do
  @moduledoc """
  Runs the committed volatile allowlist against the committed HAOS fingerprint,
  the pairing nothing else exercises: `CanonTest` measures the rules on
  synthetic captures and `mix vagus.probe.diff` runs on no fixture in CI.

  An entry that masks nothing is the failure mode worth catching. Every entry
  narrows what parity measures, so one that stopped matching — a renamed field,
  a `*` too broad to be the pattern the author meant — has quietly bought
  nothing, and is treated the way `list_unused_filters: true` treats a stale
  dialyzer filter.
  """

  use ExUnit.Case, async: true

  alias Vagus.ProbeParity.Canon

  @fixture_path Path.join([
                  __DIR__,
                  "..",
                  "..",
                  "fixtures",
                  "haos-2026.07.5-container-fingerprint.json"
                ])
  @allowlist_path Path.join([
                    __DIR__,
                    "..",
                    "..",
                    "fixtures",
                    "haos-container-fingerprint.volatile.json"
                  ])
  @external_resource @fixture_path
  @external_resource @allowlist_path

  @fixture @fixture_path |> File.read!() |> Jason.decode!()

  # The engine's own /dev/shm and the Supervisor's tmpfs stacked over it: same
  # target, different noexec. The only duplicated sort key in the capture.
  @shm Enum.filter(@fixture["fingerprint"]["mounts"], &(&1["target"] == "/dev/shm"))

  # Entries that legitimately match nothing in the HAOS capture — a field only a
  # Vagus capture carries, say. Exempting by name keeps the rest of the check
  # sharp; deleting the entry or loosening the assertion would not.
  @matches_nothing []

  test "every allowlist entry masks at least one leaf of the committed fixture" do
    unmasked = Canon.canonicalize(@fixture, [])

    dead =
      @allowlist_path
      |> Canon.load_allowlist!()
      |> Enum.reject(&(&1.path in @matches_nothing))
      |> Enum.filter(&(Canon.diff(unmasked, Canon.canonicalize(@fixture, [&1])) == []))
      |> Enum.map(& &1.path)

    assert dead == [], """
    These volatile-allowlist entries mask nothing in
    #{Path.basename(@fixture_path)}:

    #{inspect(dead)}

    Either the field they name moved, or they are obsolete. Remove them, or
    record them in @matches_nothing with the reason a Vagus capture still needs
    them.
    """
  end

  # The converse of the check above, for the one field where a too-broad entry
  # is a security hole rather than a lost measurement: masking mounts/*/options
  # wholesale once suppressed these too, so a capture with an suid-enabled or
  # executable mount compared equal to a locked-down one.
  test "the allowlist leaves the mount security flags comparable" do
    allowlist = Canon.load_allowlist!(@allowlist_path)
    canonical = Canon.canonicalize(@fixture, allowlist)

    for flag <- ~w(nodev noexec nosuid sync dirsync nosymfollow),
        index <- 0..(length(@fixture["fingerprint"]["mounts"]) - 1) do
      path = ["fingerprint", "mounts", Access.at(index), "flags", flag]
      flipped = update_in(@fixture, path, &(not &1))

      assert Canon.diff(canonical, Canon.canonicalize(flipped, allowlist)) != [],
             "flipping #{flag} on mount #{index} is invisible through the allowlist"
    end
  end

  test "the duplicated /dev/shm target compares equal however a capture ordered it" do
    [engine, supervisor] = @shm

    # Sources differ as well as order. Ordering the pair by anything the
    # allowlist masks — source, options — would put them back in step here and
    # out of step between two machines, which is the failure this pins.
    assert diff(
             with_shm([source(engine, "tmpfs"), source(supervisor, "tmpfs")]),
             with_shm([source(supervisor, "shm"), source(engine, "/run/shm")])
           ) == []
  end

  test "a duplicated target still diverges when one of the pair really differs" do
    [engine, supervisor] = @shm
    relaxed = put_in(supervisor, ["flags", "noexec"], false)

    assert diff(with_shm([engine, supervisor]), with_shm([relaxed, engine])) != []
  end

  test "masking is what makes the fixture compare equal to a differently-sited copy" do
    allowlist = Canon.load_allowlist!(@allowlist_path)
    elsewhere = put_in(@fixture, ["versions", "machine"], "rpi3-64")

    assert Canon.diff(Canon.canonicalize(@fixture, []), Canon.canonicalize(elsewhere, [])) != []

    assert Canon.diff(
             Canon.canonicalize(@fixture, allowlist),
             Canon.canonicalize(elsewhere, allowlist)
           ) == []
  end

  defp diff(left, right) do
    allowlist = Canon.load_allowlist!(@allowlist_path)

    Canon.diff(Canon.canonicalize(left, allowlist), Canon.canonicalize(right, allowlist))
  end

  defp with_shm(mounts) do
    others = Enum.reject(@fixture["fingerprint"]["mounts"], &(&1["target"] == "/dev/shm"))

    put_in(@fixture, ["fingerprint", "mounts"], others ++ mounts)
  end

  defp source(mount, source), do: %{mount | "source" => source}
end
