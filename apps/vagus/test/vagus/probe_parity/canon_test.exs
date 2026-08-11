defmodule Vagus.ProbeParity.CanonTest do
  @moduledoc """
  Exercises the canonicaliser on synthetic captures, deliberately: no real
  fingerprint fixture exists yet, and once one does, a test built on it would
  measure the capture rather than the rules. The one thing checked against the
  real artifact is that the committed volatile allowlist loads and every entry
  carries a reason.
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
    test "reads path/reason pairs" do
      file =
        write_json([
          %{"path" => "fingerprint/hostname", "reason" => "slug-derived"},
          %{"path" => "fingerprint/mounts/*/source", "reason" => "host layout"}
        ])

      assert Canon.load_allowlist!(file) == [
               %{path: "fingerprint/hostname", reason: "slug-derived"},
               %{path: "fingerprint/mounts/*/source", reason: "host layout"}
             ]
    end

    test "rejects a blank reason, naming the offending path" do
      file =
        write_json([
          %{"path" => "fingerprint/hostname", "reason" => "slug-derived"},
          %{"path" => "fingerprint/ids/uid", "reason" => "   "}
        ])

      assert_raise ArgumentError, ~r|fingerprint/ids/uid has a blank reason|, fn ->
        Canon.load_allowlist!(file)
      end
    end

    test "rejects a missing reason" do
      file = write_json([%{"path" => "fingerprint/ids/uid"}])

      assert_raise ArgumentError, ~r/needs a path and a reason/, fn ->
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
               %{path: "fingerprint/interfaces/0/hwaddr", left: Canon.sentinel(), right: :absent}
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
               %{path: "versions/channel", left: "stable", right: :absent},
               %{path: "versions/machine", left: :absent, right: "green"}
             ]
    end

    test "an empty collection is a leaf, so it diffs against a populated one" do
      assert Canon.diff(%{"mounts" => []}, %{"mounts" => [%{"target" => "/data"}]}) == [
               %{path: "mounts", left: [], right: :absent},
               %{path: "mounts/0/target", left: :absent, right: "/data"}
             ]
    end

    test "is ordered by path" do
      left = %{"b" => 1, "a" => %{"z" => 1, "y" => 1}}
      right = %{"b" => 2, "a" => %{"z" => 2, "y" => 2}}

      assert Enum.map(Canon.diff(left, right), & &1.path) == ["a/y", "a/z", "b"]
    end

    test "canonicalize then diff reports only the real divergence" do
      allowlist =
        Canon.load_allowlist!(
          write_json([
            %{"path" => "fingerprint/mounts/*/source", "reason" => "host layout"},
            %{"path" => "fingerprint/interfaces/*/hwaddr", "reason" => "engine-assigned"}
          ])
        )

      haos = fingerprint("/mnt/data/supervisor/addons/data/probe", "02:42:ac:1e:20:05", "0755")
      vagus = fingerprint("/root/vagus/addons/data/probe", "02:42:ac:1e:20:63", "0700")

      assert Canon.diff(canon(haos, allowlist), canon(vagus, allowlist)) == [
               %{path: "fingerprint/well_known//data/mode", left: "0755", right: "0700"}
             ]
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

  defp write_json(term) do
    file =
      Path.join(
        System.tmp_dir!(),
        "canon-allowlist-#{System.unique_integer([:positive])}.json"
      )

    File.write!(file, Jason.encode!(term))
    on_exit(fn -> File.rm(file) end)

    file
  end
end
