defmodule Vagus.Addon.Store.AssetsTest do
  @moduledoc """
  P2-A P1: retention of store assets (icon/logo/changelog/documentation).

  The property worth protecting is that `:memory` and `:disk` are
  observationally identical through `get/3` — the mode is a retention
  decision, not a behaviour switch — so the shared cases run against both.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Addon.Store.Assets

  # 1x1 PNG header. Real bytes rather than "png", so a test that
  # accidentally round-trips through a text path fails loudly.
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>

  # `:icon`/`:logo` content must start with the PNG signature (P2-A P4); a
  # marker appended after it keeps distinct-content tests distinguishable
  # without failing that check.
  defp png(marker), do: @png <> marker

  # Assets are addressed by `{repo_slug, addon_slug}`, never by store slug.
  @mosquitto {"core", "mosquitto"}
  @esphome {"core", "esphome"}
  @gone {"core", "gone"}
  @nope {"core", "nope"}

  setup context do
    assets =
      case context[:mode] do
        :disk -> Assets.init(:disk, root: Path.join(context.tmp_dir, "store_assets"))
        :memory -> Assets.init(:memory)
        nil -> Assets.init(:memory)
      end

    {:ok, assets: assets}
  end

  for mode <- [:memory, :disk] do
    describe "#{mode} mode" do
      @describetag :tmp_dir
      @describetag mode: mode

      test "put/get round-trips bytes verbatim", %{assets: assets} do
        assert :ok = Assets.put(@mosquitto, :icon, @png, assets)
        assert {:ok, @png} = Assets.get(@mosquitto, :icon, assets)
      end

      test "each kind is stored separately", %{assets: assets} do
        for kind <- Assets.kinds() do
          content = if kind in [:icon, :logo], do: png("#{kind}"), else: "#{kind} bytes"
          assert :ok = Assets.put(@mosquitto, kind, content, assets)
        end

        for kind <- Assets.kinds() do
          expected = if kind in [:icon, :logo], do: png("#{kind}"), else: "#{kind} bytes"
          assert Assets.get(@mosquitto, kind, assets) == {:ok, expected}
        end
      end

      test "slugs don't collide", %{assets: assets} do
        assert :ok = Assets.put(@mosquitto, :icon, png("a"), assets)
        assert :ok = Assets.put(@esphome, :icon, png("b"), assets)

        assert {:ok, png_a} = Assets.get(@mosquitto, :icon, assets)
        assert {:ok, png_b} = Assets.get(@esphome, :icon, assets)
        assert png_a == png("a")
        assert png_b == png("b")
      end

      test "put replaces what was there", %{assets: assets} do
        assert :ok = Assets.put(@mosquitto, :changelog, "old", assets)
        assert :ok = Assets.put(@mosquitto, :changelog, "new", assets)
        assert {:ok, "new"} = Assets.get(@mosquitto, :changelog, assets)
      end

      test "an unstored asset is :error, not a raise", %{assets: assets} do
        assert :error = Assets.get(@nope, :icon, assets)
      end

      test "delete drops one kind and leaves the rest", %{assets: assets} do
        assert :ok = Assets.put(@mosquitto, :icon, @png, assets)
        assert :ok = Assets.put(@mosquitto, :logo, @png, assets)
        assert :ok = Assets.delete(@mosquitto, :icon, assets)

        assert :error = Assets.get(@mosquitto, :icon, assets)
        assert {:ok, @png} = Assets.get(@mosquitto, :logo, assets)
      end

      test "deleting something absent is still :ok", %{assets: assets} do
        assert :ok = Assets.delete(@nope, :icon, assets)
      end

      test "prune drops slugs outside the catalog and keeps the rest", %{assets: assets} do
        for slug <- [@mosquitto, @esphome, @gone] do
          assert :ok = Assets.put(slug, :icon, @png, assets)
          assert :ok = Assets.put(slug, :changelog, "log", assets)
        end

        assert {:ok, 1} = Assets.prune([@mosquitto, @esphome], assets)

        assert :error = Assets.get(@gone, :icon, assets)
        assert :error = Assets.get(@gone, :changelog, assets)
        assert {:ok, @png} = Assets.get(@mosquitto, :icon, assets)
        assert {:ok, "log"} = Assets.get(@esphome, :changelog, assets)
      end

      test "prune with an empty catalog drops everything", %{assets: assets} do
        assert :ok = Assets.put(@mosquitto, :icon, @png, assets)
        assert {:ok, 1} = Assets.prune([], assets)
        assert :error = Assets.get(@mosquitto, :icon, assets)
      end

      test "prune with nothing stored is a no-op", %{assets: assets} do
        assert {:ok, 0} = Assets.prune([@mosquitto], assets)
      end

      test "an icon at the cap is retained", %{assets: assets} do
        at_cap = png(:binary.copy("x", Assets.max_bytes(:icon) - byte_size(@png)))
        assert byte_size(at_cap) == Assets.max_bytes(:icon)

        assert :ok = Assets.put(@mosquitto, :icon, at_cap, assets)
        assert Assets.get(@mosquitto, :icon, assets) == {:ok, at_cap}
      end

      test "one byte over the cap is refused and nothing is stored", %{assets: assets} do
        over = :binary.copy("x", Assets.max_bytes(:icon) + 1)

        assert {:error, :too_large} = Assets.put(@mosquitto, :icon, over, assets)
        assert :error = Assets.get(@mosquitto, :icon, assets)
      end

      test "an over-cap put does not clobber the asset already stored", %{assets: assets} do
        assert :ok = Assets.put(@mosquitto, :changelog, "good", assets)
        over = :binary.copy("x", Assets.max_bytes(:changelog) + 1)

        assert {:error, :too_large} = Assets.put(@mosquitto, :changelog, over, assets)
        assert {:ok, "good"} = Assets.get(@mosquitto, :changelog, assets)
      end

      # P2-A P4: the icon/logo leg is served unauthenticated and same-origin
      # with the HA frontend, so HTML masquerading as `icon.png` that a
      # browser content-sniffs would be stored XSS. Checked at write time so
      # nothing unvalidated is ever on disk to be served.
      test "a non-PNG icon/logo is refused, a non-PNG changelog/documentation is not",
           %{assets: assets} do
        html = "<script>alert(document.cookie)</script>"

        assert {:error, :invalid_content} = Assets.put(@mosquitto, :icon, html, assets)
        assert {:error, :invalid_content} = Assets.put(@mosquitto, :logo, html, assets)
        assert :error = Assets.get(@mosquitto, :icon, assets)
        assert :error = Assets.get(@mosquitto, :logo, assets)

        # Text kinds carry no such check — they're served as `text/plain`,
        # never sniffed as anything executable.
        assert :ok = Assets.put(@mosquitto, :changelog, html, assets)
        assert :ok = Assets.put(@mosquitto, :documentation, html, assets)
        assert {:ok, ^html} = Assets.get(@mosquitto, :changelog, assets)
        assert {:ok, ^html} = Assets.get(@mosquitto, :documentation, assets)
      end

      test "an over-cap put does not clobber the asset when both checks would fail",
           %{assets: assets} do
        # Size is checked before content, so an oversized non-PNG blob still
        # reports :too_large, not :invalid_content — the caller only needs
        # one reason, and :too_large is the more actionable one (it names a
        # concrete limit; :invalid_content doesn't tell you how far off).
        over_non_png = :binary.copy("x", Assets.max_bytes(:icon) + 1)
        assert {:error, :too_large} = Assets.put(@mosquitto, :icon, over_non_png, assets)
      end

      test "a traversal or otherwise invalid id is refused", %{assets: assets} do
        bad = ["../escape", "core/mosquitto", "..", ".", "a/../../b", ""]

        # Either half of the pair is enough to poison it.
        ids =
          Enum.flat_map(bad, &[{&1, "mosquitto"}, {"core", &1}]) ++
            [{"core", nil}, "core_mosquitto"]

        for id <- ids do
          assert {:error, :invalid_id} = Assets.put(id, :icon, @png, assets)
          assert :error = Assets.get(id, :icon, assets)
        end
      end
    end
  end

  describe "caps" do
    test "text assets have a tighter cap than images" do
      assert Assets.max_bytes(:changelog) < Assets.max_bytes(:icon)
      assert Assets.max_bytes(:changelog) == Assets.max_bytes(:documentation)
      assert Assets.max_bytes(:icon) == Assets.max_bytes(:logo)
    end
  end

  describe "id validation on disk" do
    @tag :tmp_dir
    test "a traversal segment never reaches the filesystem at all", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "store_assets")
      assets = Assets.init(:disk, root: root)

      bad = ["../escape", "core/mosquitto", "..", "a/../../b"]

      for segment <- bad, id <- [{segment, "mosquitto"}, {"core", segment}] do
        assert {:error, :invalid_id} = Assets.put(id, :icon, @png, assets)
      end

      # Not "nothing landed where I guessed it would" — nothing was written,
      # so the root was never even created.
      refute File.exists?(root)
      assert File.ls!(tmp_dir) == []
    end

    test "the charset the store's own slugs use is accepted" do
      assets = Assets.init(:memory)

      assert :ok = Assets.put({"a-repo", "an.addon"}, :icon, @png, assets)
      assert :ok = Assets.put({"core_mqtt", "broker"}, :icon, @png, assets)
    end

    test "two repos that collide into one store slug keep separate assets" do
      # Both of these render as the store slug "core_mqtt_broker". Keying on
      # the pair is what stops one repo's icon from overwriting the other's.
      assets = Assets.init(:memory)

      assert :ok = Assets.put({"core", "mqtt_broker"}, :icon, png("from core"), assets)
      assert :ok = Assets.put({"core_mqtt", "broker"}, :icon, png("from core_mqtt"), assets)

      assert {:ok, png("from core")} == Assets.get({"core", "mqtt_broker"}, :icon, assets)
      assert {:ok, png("from core_mqtt")} == Assets.get({"core_mqtt", "broker"}, :icon, assets)
    end

    @tag :tmp_dir
    test "the same collision stays separate on disk", %{tmp_dir: tmp_dir} do
      assets = Assets.init(:disk, root: Path.join(tmp_dir, "store_assets"))

      assert :ok = Assets.put({"core", "mqtt_broker"}, :icon, png("from core"), assets)
      assert :ok = Assets.put({"core_mqtt", "broker"}, :icon, png("from core_mqtt"), assets)

      assert {:ok, png("from core")} == Assets.get({"core", "mqtt_broker"}, :icon, assets)
      assert {:ok, png("from core_mqtt")} == Assets.get({"core_mqtt", "broker"}, :icon, assets)
    end
  end

  describe "id/1" do
    test "derives the pair from a catalog entry" do
      entry = %{config: %{slug: "mosquitto"}, repository: "core", assets: %{}}
      assert Assets.id(entry) == {"core", "mosquitto"}
    end
  end

  describe ":none" do
    test "retains nothing but still accepts the put" do
      assets = Assets.none()

      assert :ok = Assets.put(@mosquitto, :icon, @png, assets)
      assert :error = Assets.get(@mosquitto, :icon, assets)
      assert :ok = Assets.delete(@mosquitto, :icon, assets)
      assert {:ok, 0} = Assets.prune([], assets)
    end
  end

  describe ":disk layout" do
    @tag :tmp_dir
    test "is <root>/<repo_slug>/<addon_slug>/<upstream filename>", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "store_assets")
      assets = Assets.init(:disk, root: root)

      for kind <- Assets.kinds() do
        content = if kind in [:icon, :logo], do: png("x"), else: "x"
        assert :ok = Assets.put(@mosquitto, kind, content, assets)
      end

      assert File.ls!(root) == ["core"]

      assert Enum.sort(File.ls!(Path.join([root, "core", "mosquitto"]))) ==
               ["CHANGELOG.md", "DOCS.md", "README.md", "icon.png", "logo.png"]
    end

    @tag :tmp_dir
    test "leaves no .tmp files behind", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "store_assets")
      assets = Assets.init(:disk, root: root)

      assert :ok = Assets.put(@mosquitto, :icon, @png, assets)
      assert File.ls!(Path.join([root, "core", "mosquitto"])) == ["icon.png"]
    end

    @tag :tmp_dir
    test "a second handle over the same root reads the same bytes", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "store_assets")

      assert :ok = Assets.put(@mosquitto, :icon, @png, Assets.init(:disk, root: root))
      assert {:ok, @png} = Assets.get(@mosquitto, :icon, Assets.init(:disk, root: root))
    end

    @tag :tmp_dir
    test "prune leaves directories that aren't valid slugs alone", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "store_assets")
      assets = Assets.init(:disk, root: root)
      assert :ok = Assets.put(@mosquitto, :icon, @png, assets)

      strays = [Path.join(root, "not a repo"), Path.join([root, "core", "not an addon"])]
      Enum.each(strays, &File.mkdir_p!/1)

      assert {:ok, 0} = Assets.prune([@mosquitto], assets)
      assert Enum.all?(strays, &File.exists?/1)
    end

    @tag :tmp_dir
    test "prune removes a repository directory it emptied", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "store_assets")
      assets = Assets.init(:disk, root: root)

      assert :ok = Assets.put(@mosquitto, :icon, @png, assets)
      assert :ok = Assets.put({"esphome", "esphome"}, :icon, @png, assets)

      assert {:ok, 1} = Assets.prune([@mosquitto], assets)

      # The whole repository left the config, so its directory goes too.
      assert File.ls!(root) == ["core"]
    end

    @tag :tmp_dir
    test "a symlinked repo directory can't be written through", %{tmp_dir: tmp_dir} do
      # O_EXCL on the file alone does NOT stop this: the kernel traverses the
      # directories first, and a freshly-random-named scratch file has never
      # existed, so O_EXCL is satisfied while the write lands outside the root.
      # `File.mkdir_p/1` follows symlinked components without complaint.
      root = Path.join(tmp_dir, "store_assets")
      escape = Path.join(tmp_dir, "ESCAPED")
      File.mkdir_p!(root)
      File.mkdir_p!(escape)
      File.ln_s!(escape, Path.join(root, "core"))

      assets = Assets.init(:disk, root: root)

      assert {:error, {:unsafe_asset_dir, _dir, :symlink}} =
               Assets.put(@mosquitto, :icon, @png, assets)

      assert File.ls!(escape) == []
      assert :error = Assets.get(@mosquitto, :icon, assets)
    end

    @tag :tmp_dir
    test "a symlinked add-on directory can't be written through", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "store_assets")
      escape = Path.join(tmp_dir, "ESCAPED")
      File.mkdir_p!(Path.join(root, "core"))
      File.mkdir_p!(escape)
      File.ln_s!(escape, Path.join([root, "core", "mosquitto"]))

      assets = Assets.init(:disk, root: root)

      assert {:error, {:unsafe_asset_dir, _dir, :symlink}} =
               Assets.put(@mosquitto, :icon, @png, assets)

      assert File.ls!(escape) == []
    end

    @tag :tmp_dir
    test "reading through a symlinked component doesn't escape the root", %{tmp_dir: tmp_dir} do
      # The read path matters as much as the write path: Phase 4 serves
      # icon/logo unauthenticated, so this would be arbitrary file read as
      # root over HTTP.
      root = Path.join(tmp_dir, "store_assets")
      secrets = Path.join(tmp_dir, "SECRETS")
      File.mkdir_p!(root)
      File.mkdir_p!(Path.join(secrets, "mosquitto"))
      File.write!(Path.join([secrets, "mosquitto", "icon.png"]), "stolen")
      File.ln_s!(secrets, Path.join(root, "core"))

      assets = Assets.init(:disk, root: root)

      assert :error = Assets.get(@mosquitto, :icon, assets)
      assert :ok = Assets.delete(@mosquitto, :icon, assets)

      # delete didn't reach through the link either.
      assert File.read!(Path.join([secrets, "mosquitto", "icon.png"])) == "stolen"
    end

    @tag :tmp_dir
    test "a plain file where a directory belongs is refused, not clobbered", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "store_assets")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "core"), "i am not a directory")

      assets = Assets.init(:disk, root: root)

      assert {:error, {:unsafe_asset_dir, _dir, :regular}} =
               Assets.put(@mosquitto, :icon, @png, assets)

      assert File.read!(Path.join(root, "core")) == "i am not a directory"
    end

    @tag :tmp_dir
    test "an unwritable root returns an error rather than raising", %{tmp_dir: tmp_dir} do
      # The module promises it never raises — a full or read-only data
      # partition must degrade to "this add-on has no icon", not blow up a
      # store reload. (`IO.binwrite/2` raises on Elixir 1.20 where
      # `File.write/2` returned a tuple; hence `:raw` + `:file.write/2`.)
      root = Path.join(tmp_dir, "store_assets")
      File.mkdir_p!(root)
      File.chmod!(root, 0o500)
      on_exit(fn -> File.chmod(root, 0o700) end)

      assets = Assets.init(:disk, root: root)

      assert {:error, :eacces} = Assets.put(@mosquitto, :icon, @png, assets)
      assert :error = Assets.get(@mosquitto, :icon, assets)
    end

    @tag :tmp_dir
    test "an oversized file on disk is refused, not read", %{tmp_dir: tmp_dir} do
      # Writes are capped, so anything over the cap here was put there by
      # something else. Reading it would be a large allocation per request on
      # the small board `:disk` mode exists for.
      root = Path.join(tmp_dir, "store_assets")
      dir = Path.join([root, "core", "mosquitto"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "icon.png"), :binary.copy("x", Assets.max_bytes(:icon) + 1))

      assets = Assets.init(:disk, root: root)

      log = capture_log(fn -> assert :error = Assets.get(@mosquitto, :icon, assets) end)
      assert log =~ "refusing to read"
    end

    @tag :tmp_dir
    test "a symlinked asset file is refused, not followed", %{tmp_dir: tmp_dir} do
      # `asset_dir/3` guards the directory components; this guards the leaf.
      # Without it a symlink at icon.png is an arbitrary file read as root,
      # which phase 4 would serve unauthenticated.
      root = Path.join(tmp_dir, "store_assets")
      dir = Path.join([root, "core", "mosquitto"])
      File.mkdir_p!(dir)
      secret = Path.join(tmp_dir, "secret")
      File.write!(secret, "not yours")
      File.ln_s!(secret, Path.join(dir, "icon.png"))

      assets = Assets.init(:disk, root: root)

      log = capture_log(fn -> assert :error = Assets.get(@mosquitto, :icon, assets) end)
      assert log =~ "refusing to read"
      assert log =~ ":symlink"
    end

    @tag :tmp_dir
    test "a file exactly at the cap is still readable", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "store_assets")
      assets = Assets.init(:disk, root: root)
      at_cap = :binary.copy("x", Assets.max_bytes(:changelog))

      assert :ok = Assets.put(@mosquitto, :changelog, at_cap, assets)
      assert Assets.get(@mosquitto, :changelog, assets) == {:ok, at_cap}
    end

    test "with no root to anchor under, degrades to memory with a warning" do
      # `:addon_state_path` is nil under config/test.exs, which is exactly the
      # host/dev situation this guard exists for.
      assert Application.get_env(:vagus, :addon_state_path) == nil

      {assets, log} = with_log(fn -> Assets.init(:disk) end)

      assert log =~ "no :addon_state_path to anchor"
      assert :ok = Assets.put(@mosquitto, :icon, @png, assets)
      assert {:ok, @png} = Assets.get(@mosquitto, :icon, assets)
    end
  end

  describe "upstream filenames" do
    test "match what the real Supervisor reads out of a repository checkout" do
      assert Assets.filename(:icon) == "icon.png"
      assert Assets.filename(:logo) == "logo.png"
      assert Assets.filename(:changelog) == "CHANGELOG.md"
      assert Assets.filename(:documentation) == "DOCS.md"
    end

    test "kinds/0 is the four served endpoints plus the README behind long_description" do
      assert Enum.sort(Assets.kinds()) == [
               :changelog,
               :documentation,
               :icon,
               :logo,
               :readme
             ]
    end

    test "kinds/0 order is fixed, not derived from map key order" do
      # The @doc promises a stable order; deriving it from `Map.keys/1` would
      # make that a promise the runtime never made.
      assert Assets.kinds() == [:icon, :logo, :changelog, :documentation, :readme]
    end

    test "README.md is retained under its upstream filename" do
      assert Assets.filename(:readme) == "README.md"
      assert Assets.max_bytes(:readme) == 262_144
    end
  end
end
