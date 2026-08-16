defmodule Vagus.DSPTest do
  @moduledoc """
  Storage, validation and status for the operator-supplied QNN Hexagon skel.

  Every input is synthesised byte by byte. The premise of the whole feature is
  that the real skel cannot be redistributed, so a fixture binary is not an
  option — which is also why the module validates a 20-byte prefix and a
  content marker rather than anything a test could only assert against the
  genuine file.
  """
  # async: false — these tests point the :vagus application env's :dsp_root at
  # a tmp dir, and one of them deletes the key entirely.
  use ExUnit.Case, async: false

  alias Vagus.DSP

  @cdsp_blob "qcom/qcs6490/cdsp.mbn"
  @cdsp_version "CDSP.HT.2.5.c3-00134-KODIAK-1_20260305_004044"

  setup do
    dir = Path.join(System.tmp_dir!(), "vagus_dsp_#{System.unique_integer([:positive])}")
    Application.put_env(:vagus, :dsp_root, dir)

    on_exit(fn ->
      Application.delete_env(:vagus, :dsp_root)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  describe "store/1" do
    test "accepts a Hexagon skel and stores it under the name its content carries", %{dir: dir} do
      source = write_tmp(skel("V68"))

      assert {:ok, info} = DSP.store(source)
      assert info.filename == "libQnnHtpV68Skel.so"
      assert info.arch == "V68"
      assert info.version == "2.48.40"
      assert %DateTime{} = info.stored_at

      # The name is derived, so the source's own filename is irrelevant — this
      # is the property that keeps an uploaded filename out of the path.
      assert File.exists?(Path.join(dir, "libQnnHtpV68Skel.so"))
      assert info.size == byte_size(File.read!(Path.join(dir, "libQnnHtpV68Skel.so")))
    end

    test "a marker for another arch stores under that arch, no code change needed" do
      assert {:ok, %{filename: "libQnnHtpV73Skel.so", arch: "V73"}} =
               DSP.store(write_tmp(skel("V73")))
    end

    test "rejects a host x86-64 library on the machine field" do
      source = write_tmp(elf(class: 2, machine: 62) <> "libQnnHtpV68Skel.so")

      assert {:error, :not_hexagon} = DSP.store(source)
      assert nothing_stored?()
    end

    test "rejects a 64-bit Hexagon object on the ELF class" do
      source = write_tmp(elf(class: 2) <> "libQnnHtpV68Skel.so")

      assert {:error, :not_32bit} = DSP.store(source)
      assert nothing_stored?()
    end

    test "rejects input too short to carry a header" do
      assert {:error, :truncated} = DSP.store(write_tmp(binary_part(elf(), 0, 19)))
      assert {:error, :not_elf} = DSP.store(write_tmp("<html>Sign in to download</html>"))
      assert nothing_stored?()
    end

    test "rejects a Hexagon object that is not a skel" do
      # The aarch64 stub an operator most plausibly grabs by mistake is caught
      # earlier, on the machine field; this is the SDK's other Hexagon objects,
      # none of which name a skel.
      assert {:error, :no_skel_marker} = DSP.store(write_tmp(elf() <> "not a skeleton"))
      assert nothing_stored?()
    end

    test "rejects content naming more than one skel" do
      body = elf() <> "libQnnHtpV68Skel.so" <> "libQnnHtpV73Skel.so"

      assert {:error, :ambiguous_skel_marker} = DSP.store(write_tmp(body))
      assert nothing_stored?()
    end

    test "stores a skel with no version marker" do
      body = elf() <> String.duplicate("\0", 64) <> "libQnnHtpV68Skel.so"

      assert {:ok, %{version: nil, arch: "V68"}} = DSP.store(write_tmp(body))
    end

    test "rejects a file over the size cap before reading it" do
      assert {:error, :too_large} = DSP.store(sparse_tmp(64 * 1024 * 1024 + 1))
      assert nothing_stored?()
    end

    test "reports an unreadable source rather than crashing" do
      assert {:error, {:unreadable, :enoent}} =
               DSP.store(Path.join(System.tmp_dir!(), "vagus_dsp_absent"))
    end

    test "refuses to store on a target with no DSP" do
      Application.delete_env(:vagus, :dsp_root)

      assert {:error, :unsupported} = DSP.store(write_tmp(skel("V68")))
    end

    test "storing twice replaces cleanly and leaves no .tmp behind", %{dir: dir} do
      assert {:ok, _first} = DSP.store(write_tmp(skel("V68")))
      assert {:ok, second} = DSP.store(write_tmp(skel("V68", version: "2.50.0")))

      assert second.version == "2.50.0"
      assert Path.wildcard(Path.join(dir, "*")) == [Path.join(dir, "libQnnHtpV68Skel.so")]
      assert {:configured, %{version: "2.50.0"}} = DSP.status()
    end

    test "an upload for another arch replaces the stored skel", %{dir: dir} do
      assert {:ok, _v68} = DSP.store(write_tmp(skel("V68")))
      assert {:ok, _v73} = DSP.store(write_tmp(skel("V73")))

      assert Path.wildcard(Path.join(dir, "*")) == [Path.join(dir, "libQnnHtpV73Skel.so")]
    end
  end

  describe "validate/1" do
    test "accepts the real header's byte layout" do
      assert :ok = DSP.validate(write_tmp(elf()))
    end

    test "names which field failed" do
      assert {:error, :not_hexagon} = DSP.validate(write_tmp(elf(machine: 183)))
      assert {:error, :not_32bit} = DSP.validate(write_tmp(elf(class: 2)))
      assert {:error, :not_little_endian} = DSP.validate(write_tmp(elf(data: 2)))
      assert {:error, :not_shared_object} = DSP.validate(write_tmp(elf(type: 1)))
    end

    test "an empty or absent file is not an ELF" do
      assert {:error, :not_elf} = DSP.validate(write_tmp(""))

      assert {:error, {:unreadable, :enoent}} =
               DSP.validate(Path.join(System.tmp_dir!(), "vagus_dsp_absent"))
    end
  end

  describe "version/1" do
    test "reads the embedded AISW_VERSION" do
      assert DSP.version(write_tmp(skel("V68"))) == "2.48.40"
    end

    test "is nil when absent or unreadable, never an error" do
      assert DSP.version(write_tmp(elf())) == nil
      assert DSP.version(Path.join(System.tmp_dir!(), "vagus_dsp_absent")) == nil
    end
  end

  describe "status/0" do
    test "is :unsupported on a target with no DSP" do
      Application.delete_env(:vagus, :dsp_root)

      assert DSP.status() == :unsupported
    end

    test "is :not_configured before an upload, and with an empty store dir", %{dir: dir} do
      assert DSP.status() == :not_configured

      File.mkdir_p!(dir)
      assert DSP.status() == :not_configured
    end

    test "reports what is stored", %{dir: dir} do
      {:ok, _info} = DSP.store(write_tmp(skel("V68")))

      assert {:configured, info} = DSP.status()
      assert info.filename == "libQnnHtpV68Skel.so"
      assert info.arch == "V68"
      assert info.version == "2.48.40"
      assert info.size > 0
      assert %DateTime{} = info.stored_at

      {:ok, stat} = File.stat(Path.join(dir, info.filename), time: :posix)
      assert DateTime.to_unix(info.stored_at) == stat.mtime
    end

    test "ignores a file the loader would never ask for", %{dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "libQnnHtpVxSkel.so"), skel("V68"))

      assert DSP.status() == :not_configured
    end
  end

  # sysfs is the authority on which blob the running cDSP loaded, and the two
  # roots are overridable purely so this can be exercised off a board.
  describe "cdsp_version/0" do
    setup do
      # Memoised for the life of the boot, so every test here starts unread.
      :persistent_term.erase({DSP, :cdsp_version})
      on_exit(fn -> :persistent_term.erase({DSP, :cdsp_version}) end)

      on_exit(fn ->
        Application.delete_env(:vagus, :remoteproc_root)
        Application.delete_env(:vagus, :firmware_root)
      end)

      :ok
    end

    test "reads QC_IMAGE_VERSION_STRING out of the blob the cdsp node names" do
      fake_remoteproc(
        [{"remoteproc0", "adsp", "qcom/qcs6490/adsp.mbn"}, {"remoteproc1", "cdsp", @cdsp_blob}],
        %{@cdsp_blob => firmware(@cdsp_version)}
      )

      assert DSP.cdsp_version() == @cdsp_version
    end

    # `rubik_pi3` files its adsp blob under a vendor subdirectory, so the
    # firmware path is not a fixed one and the node's own answer must be used.
    test "follows a vendor subdirectory rather than a fixed path" do
      nested = "Thundercomm/RubikPi3/cdsp.mbn"

      fake_remoteproc([{"remoteproc4", "cdsp", nested}], %{nested => firmware(@cdsp_version)})

      assert DSP.cdsp_version() == @cdsp_version
    end

    test "is nil where no remoteproc is a cdsp" do
      fake_remoteproc([{"remoteproc0", "adsp", "qcom/adsp.mbn"}], %{})

      assert DSP.cdsp_version() == nil
    end

    test "is nil where there is no remoteproc tree at all, as on rpi3_64" do
      Application.put_env(:vagus, :remoteproc_root, Path.join(System.tmp_dir!(), "vagus_absent"))

      assert DSP.cdsp_version() == nil
    end

    test "is nil when the named blob is missing or carries no version string" do
      fake_remoteproc([{"remoteproc1", "cdsp", @cdsp_blob}], %{})
      assert DSP.cdsp_version() == nil

      :persistent_term.erase({DSP, :cdsp_version})
      fake_remoteproc([{"remoteproc1", "cdsp", @cdsp_blob}], %{@cdsp_blob => <<0::size(4096)>>})
      assert DSP.cdsp_version() == nil
    end

    test "is read once and memoised, since the rootfs it comes from is read-only" do
      fake_remoteproc([{"remoteproc1", "cdsp", @cdsp_blob}], %{
        @cdsp_blob => firmware(@cdsp_version)
      })

      assert DSP.cdsp_version() == @cdsp_version

      Application.put_env(:vagus, :remoteproc_root, Path.join(System.tmp_dir!(), "vagus_absent"))
      assert DSP.cdsp_version() == @cdsp_version
    end
  end

  # `{node, name, firmware}` per remoteproc, then the blobs to lay down under
  # the firmware root.
  defp fake_remoteproc(nodes, blobs) do
    base = Path.join(System.tmp_dir!(), "vagus_rproc_#{System.unique_integer([:positive])}")
    sysfs = Path.join(base, "sys")
    firmware_root = Path.join(base, "firmware")

    Enum.each(nodes, fn {node, name, blob} ->
      dir = Path.join(sysfs, node)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "name"), name <> "\n")
      File.write!(Path.join(dir, "firmware"), blob <> "\n")
    end)

    Enum.each(blobs, fn {relative, contents} ->
      path = Path.join(firmware_root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)

    Application.put_env(:vagus, :remoteproc_root, sysfs)
    Application.put_env(:vagus, :firmware_root, firmware_root)
    on_exit(fn -> File.rm_rf!(base) end)
  end

  # The real string sits ~69% into a 3.6 MB blob, so it is buried here too —
  # nothing about this may depend on a bounded read.
  defp firmware(version) do
    <<0::size(8192)>> <> "QC_IMAGE_VERSION_STRING=#{version}\0" <> <<0::size(8192)>>
  end

  # The measured prefix of the real file: magic, EI_CLASS = 1 (32-bit),
  # EI_DATA = 1 (LSB), EI_VERSION = 1, nine padding bytes, then e_type = 3
  # (ET_DYN) and e_machine = 164 (EM_QDSP6), both little-endian.
  defp elf(opts \\ []) do
    class = Keyword.get(opts, :class, 1)
    data = Keyword.get(opts, :data, 1)
    type = Keyword.get(opts, :type, 3)
    machine = Keyword.get(opts, :machine, 164)

    <<0x7F, "ELF", class, data, 1, 0::size(72), type::little-16, machine::little-16>>
  end

  defp skel(arch, opts \\ []) do
    version = Keyword.get(opts, :version, "2.48.40")

    elf() <>
      <<0::size(512)>> <>
      "AISW_VERSION: #{version}\0hexnn_ver_v#{version}.260702151143.\0" <>
      "libQnnHtpV#{String.trim_leading(arch, "V")}Skel.so\0"
  end

  defp write_tmp(contents) do
    path = Path.join(System.tmp_dir!(), "vagus_dsp_src_#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  # Sparse, so the cap can be exercised without writing 64 MB.
  defp sparse_tmp(size) do
    path = Path.join(System.tmp_dir!(), "vagus_dsp_big_#{System.unique_integer([:positive])}")
    {:ok, io} = File.open(path, [:write, :binary])
    :ok = :file.pwrite(io, size - 1, "x")
    :ok = File.close(io)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp nothing_stored?, do: DSP.status() == :not_configured
end
