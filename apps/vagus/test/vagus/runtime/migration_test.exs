defmodule Vagus.Runtime.MigrationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Runtime.Migration

  @core "ghcr.io/home-assistant/home-assistant:2026.7.3"
  @app "ghcr.io/home-assistant/aarch64-addon-mosquitto:6.5.0"
  @mib 1_048_576

  setup do
    root = Path.join(System.tmp_dir!(), "vagus-migration-#{System.unique_integer([:positive])}")
    legacy = Path.join(root, "root/balena-engine")
    File.mkdir_p!(Path.join(legacy, "volumes/vagus-core-config/_data/.storage"))
    File.write!(Path.join(legacy, "volumes/vagus-core-config/_data/configuration.yaml"), "x: 1")
    File.mkdir_p!(Path.join(legacy, "image/overlay2/layerdb/sha256"))
    on_exit(fn -> File.rm_rf(root) end)

    mountinfo = Path.join(root, "mountinfo")
    File.write!(mountinfo, "22 1 179:2 / / rw - ext4 /dev/root rw\n")

    opts = [
      legacy_root: legacy,
      marker: Path.join(root, "root/vagus/engine-migrated"),
      config_dir: Path.join(root, "root/vagus/core/config"),
      graphroot: Path.join(root, "root/containers/storage"),
      mountinfo: mountinfo,
      validated?: fn -> true end,
      wanted_images: fn -> {:ok, [@core, @app]} end,
      image_present?: fn _image -> true end,
      core_healthy?: fn -> true end,
      core_image: fn -> @core end
    ]

    %{root: root, legacy: legacy, opts: opts}
  end

  defp legacy_config(opts), do: Migration.legacy_config_dir(opts)
  defp new_config(opts), do: opts[:config_dir]

  # The state after a validated boot's preparation.
  defp renamed(opts) do
    assert Migration.prepare(opts) == :renamed
    opts
  end

  describe "detection" do
    test "pending while balena's root exists and the marker does not", %{opts: opts} do
      assert Migration.pending?(opts)
    end

    test "not once the marker exists", %{opts: opts} do
      File.mkdir_p!(Path.dirname(opts[:marker]))
      File.write!(opts[:marker], "")
      refute Migration.pending?(opts)
    end

    test "not on a board that never ran balena", %{opts: opts, legacy: legacy} do
      File.rm_rf!(legacy)
      refute Migration.pending?(opts)
    end
  end

  describe "the Core config resolver" do
    test "the legacy directory before the rename, the new one after", %{opts: opts} do
      assert Migration.core_config_path(opts) == legacy_config(opts)
      renamed(opts)
      assert Migration.core_config_path(opts) == new_config(opts)
      assert File.read!(Path.join(new_config(opts), "configuration.yaml")) == "x: 1"
    end

    test "the moved config wins over a volume balena made again after a rollback",
         %{opts: opts} do
      renamed(opts)
      File.mkdir_p!(legacy_config(opts))
      assert Migration.core_config_path(opts) == new_config(opts)
    end

    test "the new directory on a board without balena", %{opts: opts, legacy: legacy} do
      File.rm_rf!(legacy)
      assert Migration.core_config_path(opts) == new_config(opts)
    end
  end

  describe "prepare/1" do
    test "moves the config only once the slot is validated", %{opts: opts} do
      unvalidated = Keyword.put(opts, :validated?, fn -> false end)

      assert Migration.prepare(unvalidated) == :kept
      assert File.dir?(legacy_config(opts))
      refute File.exists?(new_config(opts))
      assert Migration.core_config_path(unvalidated) == legacy_config(opts)

      assert Migration.prepare(opts) == :renamed
      refute File.exists?(legacy_config(opts))
      assert File.dir?(Path.join(new_config(opts), ".storage"))
    end

    test "rename?: false keeps the config where Core already runs on it", %{opts: opts} do
      assert Migration.prepare(Keyword.put(opts, :rename?, false)) == :kept
      assert File.dir?(legacy_config(opts))
    end

    test "is a no-op once moved", %{opts: opts} do
      renamed(opts)
      assert Migration.prepare(opts) == :kept
      assert File.read!(Path.join(new_config(opts), "configuration.yaml")) == "x: 1"
    end

    test "gives a board with no legacy config an empty new one", %{opts: opts} do
      File.rm_rf!(legacy_config(opts))
      assert Migration.prepare(opts) == :created
      assert File.ls!(new_config(opts)) == []
    end
  end

  describe "cleanup/1" do
    test "deletes balena's root and writes the marker when every condition holds",
         %{opts: opts, legacy: legacy} do
      renamed(opts)
      assert Migration.cleanup(opts) == :done
      refute File.exists?(legacy)
      assert File.exists?(opts[:marker])
      refute Migration.pending?(opts)
      assert File.read!(Path.join(new_config(opts), "configuration.yaml")) == "x: 1"
    end

    for {condition, opt, value} <- [
          {:validated, :validated?, quote(do: fn -> false end)},
          {:images, :image_present?, quote(do: fn image -> image != @app end)},
          {:images, :wanted_images, quote(do: fn -> {:error, :versions_down} end)},
          {:core_healthy, :core_healthy?, quote(do: fn -> false end)}
        ] do
      test "waits on #{condition} when #{opt} says no", %{opts: opts, legacy: legacy} do
        renamed(opts)
        opts = Keyword.put(opts, unquote(opt), unquote(value))

        assert Migration.cleanup(opts) == {:waiting, unquote(condition)}
        assert File.dir?(legacy)
        refute File.exists?(opts[:marker])
      end
    end

    test "waits while any wanted image is missing, the last included", %{opts: opts} do
      renamed(opts)
      third = "ghcr.io/x/z:1"
      opts = Keyword.put(opts, :wanted_images, fn -> {:ok, [@core, @app, third]} end)

      for missing <- [@core, @app, third] do
        opts = Keyword.put(opts, :image_present?, &(&1 != missing))
        assert Migration.cleanup(opts) == {:waiting, :images}
      end
    end

    test "waits on the rename", %{opts: opts, legacy: legacy} do
      assert Migration.cleanup(opts) == {:waiting, :config_renamed}
      assert File.dir?(legacy_config(opts))
      assert File.dir?(legacy)
    end

    test "never follows a symlink out of the tree", %{opts: opts, root: root, legacy: legacy} do
      outside = Path.join(root, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "keep"), "k")
      File.ln_s!(outside, Path.join(legacy, "link-to-dir"))
      File.ln_s!(Path.join(outside, "keep"), Path.join(legacy, "link-to-file"))

      renamed(opts)
      assert Migration.cleanup(opts) == :done
      refute File.exists?(legacy)
      assert File.read!(Path.join(outside, "keep")) == "k"
    end

    test "refuses while anything is mounted inside the tree", %{opts: opts, legacy: legacy} do
      mount = Path.join(legacy, "overlay2/abc/merged")
      File.write!(opts[:mountinfo], "40 22 0:50 / #{mount} rw - overlay overlay rw\n")
      renamed(opts)

      capture_log(fn ->
        assert {:error, {:mounted, [^mount]}} = Migration.cleanup(opts)
      end)

      assert File.dir?(legacy)
      refute File.exists?(opts[:marker])
    end

    test "a mount point written with octal escapes is still found", %{opts: opts, legacy: legacy} do
      File.write!(opts[:mountinfo], "40 22 0:50 / #{legacy}/a\\040b rw - tmpfs t rw\n")
      renamed(opts)
      capture_log(fn -> assert {:error, {:mounted, _}} = Migration.cleanup(opts) end)
    end

    test "finishes after a reboot cut the deletion short", %{opts: opts, legacy: legacy} do
      renamed(opts)
      File.mkdir_p!(Path.join(legacy, "overlay2/l1/diff"))
      File.write!(Path.join(legacy, "overlay2/l1/diff/f"), "")
      # Part of the tree is gone, the marker never written.
      File.rm_rf!(Path.join(legacy, "volumes"))

      assert Migration.pending?(opts)
      assert Migration.prepare(opts) == :kept
      assert Migration.cleanup(opts) == :done
      refute File.exists?(legacy)
      assert Migration.cleanup(opts) == :done
    end

    test "a reboot between the rename and the deletion changes nothing", %{opts: opts} do
      renamed(opts)
      waiting = Keyword.put(opts, :core_healthy?, fn -> false end)
      assert Migration.cleanup(waiting) == {:waiting, :core_healthy}

      assert Migration.prepare(opts) == :kept
      assert Migration.core_config_path(opts) == new_config(opts)
      assert Migration.cleanup(opts) == :done
    end
  end

  # A balena image store: each image's layers as {diff_id, size}.
  defp store(legacy, images) do
    dir = Path.join(legacy, "image/overlay2")

    tags =
      for {ref, layers} <- images, into: %{} do
        config = Jason.encode!(%{"rootfs" => %{"diff_ids" => Enum.map(layers, &elem(&1, 0))}})
        id = Base.encode16(:crypto.hash(:sha256, config), case: :lower)
        File.mkdir_p!(Path.join(dir, "imagedb/content/sha256"))
        File.write!(Path.join([dir, "imagedb/content/sha256", id]), config)

        _last_chain =
          Enum.reduce(layers, nil, fn {diff_id, size}, parent ->
            chain =
              if parent,
                do:
                  "sha256:" <>
                    Base.encode16(:crypto.hash(:sha256, parent <> " " <> diff_id), case: :lower),
                else: diff_id

            "sha256:" <> hex = chain
            File.mkdir_p!(Path.join([dir, "layerdb/sha256", hex]))
            File.write!(Path.join([dir, "layerdb/sha256", hex, "size"]), "#{size}")
            chain
          end)

        {ref, "sha256:" <> id}
      end

    repos = Enum.group_by(tags, fn {ref, _} -> ref |> String.split(":") |> hd() end)

    File.write!(
      Path.join(dir, "repositories.json"),
      Jason.encode!(%{"Repositories" => Map.new(repos, fn {r, t} -> {r, Map.new(t)} end)})
    )
  end

  defp diff(n), do: "sha256:" <> String.duplicate(Integer.to_string(n), 64)

  defp df_free(bytes) do
    fn _path ->
      {"Filesystem 1K-blocks Used Available Use% Mounted on\n" <>
         "/dev/root 99999999 1 #{div(bytes, 1024)} 1% /root\n", 0}
    end
  end

  describe "space/1" do
    setup %{legacy: legacy} do
      # Core and the app share their base layer.
      store(legacy, [
        {@core, [{diff(1), 100 * @mib}, {diff(2), 900 * @mib}]},
        {@app, [{diff(1), 100 * @mib}, {diff(3), 50 * @mib}]}
      ])

      :ok
    end

    test "each shared layer once, plus half the largest image for the spool", %{opts: opts} do
      assert Migration.need_bytes([@core, @app], opts) == (1050 + 500) * @mib
    end

    test "an image balena does not hold counts as 1 GiB", %{opts: opts} do
      assert Migration.need_bytes(["ghcr.io/x/y:1"], opts) == 1024 * @mib + 512 * @mib
    end

    test "a Docker Hub short name is found under its full name", %{opts: opts, legacy: legacy} do
      store(legacy, [{"docker.io/library/alpine:3.20", [{diff(4), 8 * @mib}]}])
      assert Migration.need_bytes(["alpine:3.20"], opts) == 12 * @mib
    end

    test "fits: :ok", %{opts: opts} do
      opts = Keyword.merge(opts, image_present?: fn _ -> false end, df: df_free(2000 * @mib))
      assert Migration.space(opts) == :ok
    end

    test "does not fit: {:short, need, free}", %{opts: opts} do
      opts = Keyword.merge(opts, image_present?: fn _ -> false end, df: df_free(1000 * @mib))
      assert Migration.space(opts) == {:short, 1550 * @mib, 1000 * @mib}
    end

    test "images podman already holds need nothing, so a reboot mid-pull still fits",
         %{opts: opts} do
      opts =
        Keyword.merge(opts, image_present?: &(&1 == @core), df: df_free(300 * @mib))

      # Only the app: its two layers, plus half of itself.
      assert Migration.space(opts) == :ok
      assert Migration.need_bytes([@app], opts) == 225 * @mib
    end

    test "an unreadable df is unknown, not an empty disk", %{opts: opts} do
      opts = Keyword.merge(opts, image_present?: fn _ -> false end, df: fn _ -> {"", 1} end)
      assert Migration.space(opts) == {:error, :df_failed}
    end

    test "pull_space/2 keeps room for Core while Core's image is not back", %{opts: opts} do
      opts = Keyword.merge(opts, df: df_free(1100 * @mib), image_present?: fn _ -> false end)
      # The app with Core: every layer once (1050) plus half of Core (500).
      assert {:short, need, _} = Migration.pull_space(@app, opts)
      assert need == 1550 * @mib

      # Core back, or no Core installed: the app alone (225).
      assert Migration.pull_space(@app, Keyword.put(opts, :image_present?, &(&1 == @core))) == :ok
      assert Migration.pull_space(@app, Keyword.put(opts, :core_image, fn -> nil end)) == :ok
    end

    test "pull_space/2 asks room for that image alone", %{opts: opts} do
      opts = Keyword.put(opts, :df, df_free(1100 * @mib))
      # Core: its 1000 MiB plus half of itself; the app: 150 plus 75.
      assert {:short, need, _} = Migration.pull_space(@core, opts)
      assert need == 1500 * @mib
      assert Migration.pull_space(@app, opts) == :ok

      assert {:short, _, _} =
               Migration.space(Keyword.put(opts, :image_present?, fn _ -> false end))
    end

    test "pull_space/2 asks nothing once the migration is done", %{opts: opts} do
      File.mkdir_p!(Path.dirname(opts[:marker]))
      File.write!(opts[:marker], "")
      assert Migration.pull_space(@core, Keyword.put(opts, :df, df_free(1))) == :ok
    end
  end

  describe "balena metadata that is not what it should be" do
    setup %{legacy: legacy} do
      %{dir: Path.join(legacy, "image/overlay2")}
    end

    defp repositories(dir, id) do
      File.mkdir_p!(Path.join(dir, "imagedb/content/sha256"))

      File.write!(
        Path.join(dir, "repositories.json"),
        Jason.encode!(%{"Repositories" => %{"r" => %{@app => id}}})
      )
    end

    defp unknown, do: 1024 * @mib + 512 * @mib

    test "an image id naming a path out of the store is unknown, and nothing is read",
         %{opts: opts, dir: dir, root: root, legacy: legacy} do
      # A readable config out there, with a layer the store does hold: were
      # the id followed, the size would come out known.
      store(legacy, [{"ghcr.io/x/other:1", [{diff(6), 10 * @mib}]}])

      File.write!(
        Path.join(root, "secret"),
        Jason.encode!(%{"rootfs" => %{"diff_ids" => [diff(6)]}})
      )

      repositories(dir, "sha256:" <> String.duplicate("../", 7) <> "secret")

      assert File.exists?(
               Path.join([dir, "imagedb/content/sha256", String.duplicate("../", 7) <> "secret"])
             )

      assert Migration.need_bytes([@app], opts) == unknown()
    end

    test "a diff id that is no digest is unknown", %{opts: opts, dir: dir} do
      for diff_ids <- [
            [42],
            ["sha256:../../x"],
            ["md5:abc"],
            "sha256:" <> String.duplicate("a", 64)
          ] do
        config = Jason.encode!(%{"rootfs" => %{"diff_ids" => diff_ids}})
        id = Base.encode16(:crypto.hash(:sha256, config), case: :lower)
        repositories(dir, "sha256:" <> id)
        File.write!(Path.join([dir, "imagedb/content/sha256", id]), config)
        assert Migration.need_bytes([@app], opts) == unknown()
      end
    end

    test "a size that is no number is unknown", %{opts: opts, legacy: legacy} do
      store(legacy, [{@app, [{diff(5), 10 * @mib}]}])

      File.write!(
        Path.join([legacy, "image/overlay2/layerdb/sha256", String.duplicate("5", 64), "size"]),
        "12abc"
      )

      assert Migration.need_bytes([@app], opts) == unknown()
    end

    test "repositories of the wrong shape are unknown", %{opts: opts, dir: dir} do
      File.mkdir_p!(dir)

      for json <- [
            ~s([]),
            ~s({"Repositories": []}),
            ~s({"Repositories": {"r": {"#{@app}": 7}}}),
            "{"
          ] do
        File.write!(Path.join(dir, "repositories.json"), json)
        assert Migration.need_bytes([@app], opts) == unknown()
      end
    end
  end

  describe "check/2 and the notification" do
    defp notifier do
      test = self()

      fn event ->
        send(test, {:notify, event})
        :ok
      end
    end

    setup %{opts: opts} do
      %{opts: Keyword.merge(opts, notify: notifier(), image_present?: fn _ -> false end)}
    end

    test "raises one with what is needed while the images do not fit", %{opts: opts} do
      opts = Keyword.merge(opts, validated?: fn -> false end, df: df_free(10 * @mib))
      assert %{cleanup: {:waiting, :validated}, notice: notice} = Migration.check(opts)
      assert_received {:notify, {:raise, need, free}}
      assert notice == %{need: need, free: free}
      assert free == 10 * @mib

      assert %{notice: ^notice} = Migration.check(opts, notice: notice)
      refute_received {:notify, _}
    end

    test "dismisses it once they fit", %{opts: opts} do
      opts = Keyword.merge(opts, validated?: fn -> false end, df: df_free(100_000 * @mib))
      assert %{notice: nil} = Migration.check(opts, notice: %{need: 1, free: 0})
      assert_received {:notify, :dismiss}
    end

    test "keeps it while space is unknown", %{opts: opts} do
      opts = Keyword.merge(opts, validated?: fn -> false end, df: fn _ -> {"", 1} end)
      assert %{notice: %{need: 1}} = Migration.check(opts, notice: %{need: 1, free: 0})
      refute_received {:notify, _}
    end

    test "says how much is needed and what the deletion gives up" do
      %{"message" => message} = Migration.notification(1500 * @mib, 10 * @mib)
      assert message =~ "1500 MiB"
      assert message =~ "10 MiB"
      assert message =~ "roll back"
    end
  end

  describe "making room once validated" do
    setup %{opts: opts} do
      short =
        Keyword.merge(opts,
          df: df_free(1 * @mib),
          image_present?: fn _ -> false end,
          core_healthy?: fn -> false end,
          notify: fn _ -> :ok end
        )

      %{short: short}
    end

    test "deletes the store before the images are back, keeping Core's config",
         %{short: opts, legacy: legacy} do
      renamed(opts)

      capture_log(fn ->
        assert %{cleanup: :done, notice: nil} = Migration.check(opts, notice: %{need: 1, free: 0})
      end)

      refute File.exists?(legacy)
      assert File.exists?(opts[:marker])
      assert File.read!(Path.join(new_config(opts), "configuration.yaml")) == "x: 1"
    end

    test "never before the slot is validated", %{short: opts, legacy: legacy} do
      renamed(opts)
      opts = Keyword.put(opts, :validated?, fn -> false end)
      assert %{cleanup: {:waiting, :validated}} = Migration.check(opts)
      assert File.dir?(legacy)
    end

    test "never before Core's config is out of the tree", %{short: opts, legacy: legacy} do
      # Validated, but the move is still to come at the next preparation.
      capture_log(fn -> Migration.check(opts) end)
      assert File.read!(Path.join(legacy_config(opts), "configuration.yaml")) == "x: 1"
      refute File.exists?(opts[:marker])
    end
  end

  describe "the deletion" do
    setup %{opts: opts} do
      renamed(opts)
      :ok
    end

    test "does not follow a directory swapped for a symlink before its listing",
         %{opts: opts, root: root, legacy: legacy} do
      outside = Path.join(root, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "keep"), "k")
      victim = Path.join(legacy, "overlay2")
      File.mkdir_p!(victim)

      swap = fn
        ^victim ->
          File.rm_rf!(victim)
          File.ln_s!(outside, victim)

        _other ->
          :ok
      end

      capture_log(fn ->
        assert {:error, {:changed, ^victim}} =
                 Migration.cleanup(Keyword.put(opts, :walk_hook, swap))
      end)

      assert File.read!(Path.join(outside, "keep")) == "k"
      refute File.exists?(opts[:marker])
    end

    test "leaves an entry on another filesystem alone", %{opts: opts, legacy: legacy} do
      mounted = Path.join(legacy, "mnt")
      File.mkdir_p!(mounted)
      File.write!(Path.join(mounted, "keep"), "k")

      lstat = fn path ->
        with {:ok, stat} <- File.lstat(path) do
          if path == mounted,
            do: {:ok, %{stat | major_device: stat.major_device + 1}},
            else: {:ok, stat}
        end
      end

      capture_log(fn ->
        assert {:error, {:other_filesystem, ^mounted}} =
                 Migration.cleanup(Keyword.put(opts, :lstat, lstat))
      end)

      assert File.read!(Path.join(mounted, "keep")) == "k"
      refute File.exists?(opts[:marker])
    end

    test "counts what another walk removed meanwhile as done, and logs no failure",
         %{opts: opts, legacy: legacy} do
      gone = Path.join(legacy, "overlay2/l1")
      File.mkdir_p!(Path.join(gone, "diff"))
      File.write!(Path.join(gone, "diff/f"), "")

      race = fn
        ^gone -> File.rm_rf!(gone)
        _other -> :ok
      end

      log =
        capture_log(fn ->
          assert Migration.cleanup(Keyword.put(opts, :walk_hook, race)) == :done
        end)

      refute log =~ "[error]"
      refute File.exists?(legacy)
    end
  end
end
