defmodule Vagus.ProbeParity.CanonTest do
  @moduledoc """
  Exercises the canonicaliser on synthetic captures, deliberately: a test built
  on the committed HAOS fingerprint would measure what that bench happened to
  report, where these measure the rules. The one thing checked against the real
  artifact is that the committed volatile allowlist loads and every entry
  carries a reason; whether those entries still mask anything, and how the rules
  behave on the real capture, is `Vagus.ProbeParity.VolatileAllowlistTest`.
  """

  use ExUnit.Case, async: true

  alias Vagus.ProbeParity.Canon

  @allowlist_path Path.join([
                    __DIR__,
                    "..",
                    "..",
                    "fixtures",
                    "haos-container-fingerprint.volatile.json"
                  ])
  @external_resource @allowlist_path

  describe "load_allowlist!/1" do
    @describetag :tmp_dir

    test "reads path/reason pairs", %{tmp_dir: tmp_dir} do
      file =
        write_json(tmp_dir, [
          %{"path" => "fingerprint/hostname", "reason" => "slug-derived"},
          %{"path" => "fingerprint/mounts/*/source", "reason" => "host layout"}
        ])

      assert Canon.load_allowlist!(file) == [
               %{path: "fingerprint/hostname", reason: "slug-derived"},
               %{path: "fingerprint/mounts/*/source", reason: "host layout"}
             ]
    end

    test "rejects a blank reason, naming the offending path", %{tmp_dir: tmp_dir} do
      file =
        write_json(tmp_dir, [
          %{"path" => "fingerprint/hostname", "reason" => "slug-derived"},
          %{"path" => "fingerprint/ids/uid", "reason" => "   "}
        ])

      assert_raise ArgumentError, ~r|fingerprint/ids/uid has a blank reason|, fn ->
        Canon.load_allowlist!(file)
      end
    end

    test "rejects a missing reason", %{tmp_dir: tmp_dir} do
      file = write_json(tmp_dir, [%{"path" => "fingerprint/ids/uid"}])

      assert_raise ArgumentError, ~r/needs a path and a reason/, fn ->
        Canon.load_allowlist!(file)
      end
    end

    test "rejects a pattern whose literal segment would be a slash-bearing key", %{
      tmp_dir: tmp_dir
    } do
      file =
        write_json(tmp_dir, [
          %{"path" => "fingerprint/well_known//data/mode", "reason" => "per-machine"}
        ])

      assert_raise ArgumentError, ~r/reachable only through \*/, fn ->
        Canon.load_allowlist!(file)
      end
    end

    test "names the file when the JSON is malformed", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "broken.json")
      File.write!(file, "[{\"path\": ")

      assert_raise ArgumentError, ~r/#{Regex.escape(file)}: invalid JSON/, fn ->
        Canon.load_allowlist!(file)
      end
    end

    test "names the file when it cannot be read", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "absent.json")

      assert_raise ArgumentError, ~r/#{Regex.escape(file)}: cannot read/, fn ->
        Canon.load_allowlist!(file)
      end
    end

    test "the committed allowlist loads" do
      entries = Canon.load_allowlist!(@allowlist_path)

      assert entries != []
      assert Enum.all?(entries, &(String.trim(&1.reason) != ""))
    end
  end

  describe "canonicalize/2" do
    test "masks a leaf and leaves its siblings alone" do
      capture = %{"fingerprint" => %{"env" => %{"TZ" => "Europe/Berlin", "LANG" => "C.UTF-8"}}}

      assert canon(capture, ["fingerprint/env/TZ"]) == %{
               "fingerprint" => %{
                 "env" => %{"TZ" => Canon.sentinel(), "LANG" => "C.UTF-8"}
               }
             }
    end

    test "* matches any map key" do
      capture = %{"well_known" => %{"/data" => %{"uid" => 0}, "/ssl" => %{"uid" => 1}}}

      assert canon(capture, ["well_known/*/uid"]) == %{
               "well_known" => %{
                 "/data" => %{"uid" => Canon.sentinel()},
                 "/ssl" => %{"uid" => Canon.sentinel()}
               }
             }
    end

    test "a slash-bearing key is a single path segment, reachable only through *" do
      capture = %{"well_known" => %{"/data" => %{"mode" => "0755"}}}

      assert canon(capture, ["well_known/*/mode"]) == %{
               "well_known" => %{"/data" => %{"mode" => Canon.sentinel()}}
             }

      assert_raise ArgumentError, ~r/reachable only through \*/, fn ->
        canon(capture, ["well_known//data/mode"])
      end
    end

    test "* matches any list index" do
      capture = %{
        "fingerprint" => %{
          "mounts" => [
            %{"target" => "/data", "source" => "/mnt/data/addons/a", "ro" => false},
            %{"target" => "/ssl", "source" => "/mnt/data/ssl", "ro" => true}
          ]
        }
      }

      assert canon(capture, ["fingerprint/mounts/*/source"]) == %{
               "fingerprint" => %{
                 "mounts" => [
                   %{"target" => "/data", "source" => Canon.sentinel(), "ro" => false},
                   %{"target" => "/ssl", "source" => Canon.sentinel(), "ro" => true}
                 ]
               }
             }
    end

    test "a pattern naming a subtree masks the whole subtree" do
      capture = %{
        "fingerprint" => %{"cgroup" => %{"self" => ["0::/docker/abc"], "cpu_max" => "max"}}
      }

      assert canon(capture, ["fingerprint/cgroup/self"]) == %{
               "fingerprint" => %{"cgroup" => %{"self" => Canon.sentinel(), "cpu_max" => "max"}}
             }
    end

    test "masking substitutes rather than drops, so a vanished field still diffs" do
      allowlist = ["fingerprint/interfaces/*/hwaddr"]

      present =
        canon(
          %{
            "fingerprint" => %{
              "interfaces" => [%{"name" => "eth0", "hwaddr" => "02:42:ac:1e:20:05"}]
            }
          },
          allowlist
        )

      absent = canon(%{"fingerprint" => %{"interfaces" => [%{"name" => "eth0"}]}}, allowlist)

      assert Canon.diff(present, absent) == [
               %{
                 path: ["fingerprint", "interfaces", "0", "hwaddr"],
                 left: Canon.sentinel(),
                 right: :absent
               }
             ]
    end

    test "re-sorts mounts by target and interfaces by name" do
      capture = %{
        "fingerprint" => %{
          "mounts" => [%{"target" => "/ssl"}, %{"target" => "/config"}, %{"target" => "/data"}],
          "interfaces" => [%{"name" => "lo"}, %{"name" => "eth0"}]
        }
      }

      canonical = canon(capture, [])

      assert canonical["fingerprint"]["mounts"] == [
               %{"target" => "/config"},
               %{"target" => "/data"},
               %{"target" => "/ssl"}
             ]

      assert canonical["fingerprint"]["interfaces"] == [%{"name" => "eth0"}, %{"name" => "lo"}]
    end

    test "entries sharing a sort key order by canonical content, not by a masked one" do
      allowlist = ["fingerprint/mounts/*/source"]

      shm = fn source, noexec ->
        %{"target" => "/dev/shm", "source" => source, "flags" => %{"noexec" => noexec}}
      end

      left = %{"fingerprint" => %{"mounts" => [shm.("tmpfs", true), shm.("shm", false)]}}
      right = %{"fingerprint" => %{"mounts" => [shm.("/run/shm", false), shm.("none", true)]}}

      assert Canon.diff(canon(left, allowlist), canon(right, allowlist)) == []
    end

    test "entries missing the sort key keep file order, after the sorted ones" do
      capture = %{
        "fingerprint" => %{
          "mounts" => [%{"fstype" => "proc"}, %{"target" => "/ssl"}, %{"fstype" => "sysfs"}]
        }
      }

      assert canon(capture, [])["fingerprint"]["mounts"] == [
               %{"target" => "/ssl"},
               %{"fstype" => "proc"},
               %{"fstype" => "sysfs"}
             ]
    end

    test "leaves other lists in file order" do
      capture = %{"fingerprint" => %{"resolv_conf" => %{"search" => ["local.hass.io", "lan"]}}}

      assert canon(capture, [])["fingerprint"]["resolv_conf"]["search"] == [
               "local.hass.io",
               "lan"
             ]
    end
  end

  describe "diff/2" do
    test "is empty for equal captures" do
      capture = %{"a" => %{"b" => [1, 2], "c" => nil}}

      assert Canon.diff(capture, capture) == []
    end

    test "two different volatile values compare equal once masked" do
      allowlist = ["fingerprint/interfaces/*/addrs/*/addr"]

      haos = capture_with_addr("172.30.32.4")
      vagus = capture_with_addr("172.30.32.9")

      refute haos == vagus
      assert Canon.diff(canon(haos, allowlist), canon(vagus, allowlist)) == []
    end

    test "a key missing on either side diffs against :absent" do
      left = %{"versions" => %{"supervisor" => "2026.07.5", "channel" => "stable"}}
      right = %{"versions" => %{"supervisor" => "2026.07.5", "machine" => "green"}}

      assert Canon.diff(left, right) == [
               %{path: ["versions", "channel"], left: "stable", right: :absent},
               %{path: ["versions", "machine"], left: :absent, right: "green"}
             ]
    end

    test "an empty collection is a leaf, so it diffs against a populated one" do
      assert Canon.diff(%{"mounts" => []}, %{"mounts" => [%{"target" => "/data"}]}) == [
               %{path: ["mounts"], left: [], right: :absent},
               %{path: ["mounts", "0", "target"], left: :absent, right: "/data"}
             ]
    end

    test "is ordered by path" do
      left = %{"b" => 1, "a" => %{"z" => 1, "y" => 1}}
      right = %{"b" => 2, "a" => %{"z" => 2, "y" => 2}}

      assert Enum.map(Canon.diff(left, right), & &1.path) == [["a", "y"], ["a", "z"], ["b"]]
    end

    @tag :tmp_dir
    test "canonicalize then diff reports only the real divergence", %{tmp_dir: tmp_dir} do
      allowlist =
        Canon.load_allowlist!(
          write_json(tmp_dir, [
            %{"path" => "fingerprint/mounts/*/source", "reason" => "host layout"},
            %{"path" => "fingerprint/interfaces/*/hwaddr", "reason" => "engine-assigned"}
          ])
        )

      haos = fingerprint("/mnt/data/supervisor/addons/data/probe", "02:42:ac:1e:20:05", "0755")
      vagus = fingerprint("/root/vagus/addons/data/probe", "02:42:ac:1e:20:63", "0700")

      divergence = %{path: ["fingerprint", "well_known", "/data", "mode"]}

      assert Canon.diff(canon(haos, allowlist), canon(vagus, allowlist)) == [
               Map.merge(divergence, %{left: "0755", right: "0700"})
             ]

      # The slash-bearing key survives the round trip only in the segment list;
      # rendered, it is the ambiguous "fingerprint/well_known//data/mode".
      assert Canon.path_to_string(divergence.path) == "fingerprint/well_known//data/mode"
    end
  end

  defp canon(capture, allowlist), do: Canon.canonicalize(capture, allowlist)

  defp capture_with_addr(addr) do
    %{
      "fingerprint" => %{
        "interfaces" => [
          %{
            "name" => "eth0",
            "addrs" => [
              %{"family" => "inet", "addr" => addr, "prefix_or_mask" => "255.255.254.0"}
            ]
          }
        ]
      }
    }
  end

  defp fingerprint(source, hwaddr, mode) do
    %{
      "fingerprint" => %{
        "mounts" => [
          %{"target" => "/data", "source" => source, "fstype" => "ext4", "ro" => false}
        ],
        "interfaces" => [%{"name" => "eth0", "hwaddr" => hwaddr}],
        "well_known" => %{"/data" => %{"exists" => true, "mode" => mode}}
      }
    }
  end

  defp write_json(tmp_dir, term) do
    file = Path.join(tmp_dir, "allowlist-#{System.unique_integer([:positive])}.json")
    File.write!(file, Jason.encode!(term))

    file
  end
end
