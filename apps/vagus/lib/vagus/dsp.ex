defmodule Vagus.DSP do
  @moduledoc """
  The operator-supplied QNN Hexagon skeleton library — where it lives, whether
  it is the right file, and what to report about it.

  Qualcomm does not permit redistributing `libQnnHtpV<NN>Skel.so`, so it cannot
  ship in `nerves_system_vagus` and no add-on image may carry it either. The
  operator extracts it from the QAIRT SDK and uploads it after install, via
  `Vagus.API.AdminPanel`; a later phase binds it into the container. This
  module owns the directory in between.

  ## The stored name comes from the file's own content, never from the uploader

  The DSP loader resolves a skel by exact filename along `libcdsprpc`'s built-in
  search path, so the name is load-bearing rather than cosmetic. Every skel in
  the SDK embeds exactly one `libQnnHtpV<NN>Skel.so` string and it is its own
  name — verified across all seven arches the SDK ships. Deriving the name from
  that marker rather than from a caller-supplied filename buys three things at
  once: the name is always the one the loader needs, an untrusted string never
  reaches `Path.join/2`, and a future V73 or V75 board works with no code
  change. It also means `store/1` takes a path and nothing else.

  ## `:dsp_root` is set per board, not in `config/target.exs`

  `nil` is the honest "this target has no DSP" answer on `rpi3_64`, which
  `status/0` reports as `:unsupported` — a capability check falling out of the
  configuration rather than sitting beside it.

  ## Nothing here rejects on a version or an arch

  The skel-vs-CDSP-firmware pairing is not checkable at all: `AISW_VERSION`
  and `QC_IMAGE_VERSION_STRING` are unrelated numbering schemes with no shared
  field, so `cdsp_version/0` is reported *beside* `version/1` and never
  compared with it. The arch pairing is checkable against `expected_arch/0`,
  but raising it is the panel's job — a skel for the wrong Hexagon version has
  to be warned about, not refused, because refusing would strand an operator
  whose board `:dsp_arch` is wrong for.
  """

  require Logger

  @type info :: %{
          filename: String.t(),
          arch: String.t(),
          version: String.t() | nil,
          size: non_neg_integer(),
          stored_at: DateTime.t()
        }

  @type reason ::
          :unsupported
          | :too_large
          | :truncated
          | :not_elf
          | :not_hexagon
          | :not_32bit
          | :not_little_endian
          | :not_shared_object
          | :no_skel_marker
          | :ambiguous_skel_marker
          | {:unreadable, File.posix()}
          | {:store_failed, File.posix()}

  # ELF identification and header fields, at their fixed offsets: EI_CLASS (4),
  # EI_DATA (5), e_type (16), e_machine (18). The last two sit at the same
  # offsets in ELF32 and ELF64, which is what lets one 20-byte read classify
  # both.
  @header_bytes 20
  @em_qdsp6 164
  @elfclass32 1
  @elfdata2lsb 1
  @et_dyn 3

  # ~10 MB today. The cap exists because this is an operator-supplied file
  # landing on a device with a finite data partition — a mistyped upload (the
  # SDK zip itself is 2.4 GB) must be refused rather than fill `/data`. It is
  # also what makes reading the file whole safe, so it is checked against
  # `stat` before any read.
  @max_bytes 64 * 1024 * 1024

  @skel_marker ~r/libQnnHtpV(\d+)Skel\.so/
  @aisw_version ~r/AISW_VERSION:\s*(\d+(?:\.\d+)+)/

  # Bounded so a long printable run with no terminating NUL cannot make the
  # match walk the rest of a 3.6 MB blob.
  @qc_image_version ~r/QC_IMAGE_VERSION_STRING=([\x20-\x7e]{1,255})/

  # `/lib/firmware` is on the read-only squashfs rootfs, so which blob the
  # running cDSP loaded is fixed for the life of the boot — the OTA that could
  # change it also reboots. Memoising is therefore not a cache-invalidation
  # problem, which is worth having because the answer costs a whole-file read.
  # The stored skel is the opposite case and must never be treated this way:
  # it changes under a running VM every time an operator uploads one.
  @cdsp_memo {__MODULE__, :cdsp_version}

  @doc """
  The store directory, or `nil` on a target with no DSP.
  """
  @spec root() :: Path.t() | nil
  def root, do: Application.get_env(:vagus, :dsp_root)

  @doc """
  The Hexagon architecture this board's DSP is (`"V68"`), or `nil` where the
  board did not say.

  Set per board beside `:dsp_root`. It exists so the panel can name the one
  right `hexagon-v*/unsigned/` directory out of the SDK's seven, and warn on a
  skel built for another one — see the moduledoc on why that is a warning.
  """
  @spec expected_arch() :: String.t() | nil
  def expected_arch, do: Application.get_env(:vagus, :dsp_arch)

  @doc """
  The largest file `store/1` will accept.

  Exposed so an upload surface bounds its own body parser with the same
  number `store/1` enforces, instead of a second one that can drift from it.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Validates an already-uploaded file, derives its name from its content, and
  moves it into the store.

  `{:error, reason}` is a term the panel renders as a sentence to an operator
  who just picked the wrong file out of a 2.4 GB SDK tree, so the reasons
  discriminate the plausible mistakes rather than collapsing into one.
  """
  @spec store(Path.t()) :: {:ok, info()} | {:error, reason()}
  def store(source) do
    with {:ok, dir} <- configured_root(),
         :ok <- check_size(source),
         :ok <- validate(source),
         {:ok, contents} <- read_file(source),
         {:ok, filename, arch} <- derive_name(contents),
         :ok <- install(dir, filename, contents) do
      version = version_in(contents)
      Logger.info("Vagus.DSP: stored #{filename} (#{arch}, version #{version || "not detected"})")
      describe(Path.join(dir, filename), arch, version)
    end
  end

  @doc """
  Checks the 20-byte ELF prefix.
  """
  @spec validate(Path.t()) :: :ok | {:error, reason()}
  def validate(path) do
    case read_header(path) do
      {:ok, header} -> check_header(header)
      {:error, posix} -> {:error, {:unreadable, posix}}
    end
  end

  @doc """
  The `AISW_VERSION` the skel carries, or `nil`.

  Absent is not a rejection. A future SDK could drop the string, and refusing a
  working skel over a field that only gets displayed would be the wrong
  failure — so an unreadable or unmarked file reports `nil` and still stores.
  """
  @spec version(Path.t()) :: String.t() | nil
  def version(path) do
    with :ok <- check_size(path),
         {:ok, contents} <- read_file(path) do
      version_in(contents)
    else
      {:error, _reason} -> nil
    end
  end

  @doc """
  The `QC_IMAGE_VERSION_STRING` of the cDSP firmware the running kernel
  loaded, or `nil` where there is no cDSP or the blob cannot be read.

  For display beside `version/1`, never for comparison with it.
  """
  @spec cdsp_version() :: String.t() | nil
  def cdsp_version do
    case :persistent_term.get(@cdsp_memo, :unread) do
      :unread ->
        version = read_cdsp_version()
        :persistent_term.put(@cdsp_memo, version)
        version

      memoised ->
        memoised
    end
  end

  @doc """
  `:unsupported` when the target has no DSP, `:not_configured` until the
  operator supplies a skel, `{:configured, info}` after.
  """
  @spec status() :: :unsupported | :not_configured | {:configured, info()}
  def status do
    case root() do
      nil -> :unsupported
      dir -> report(stored_skels(dir))
    end
  end

  @doc """
  The same three-way answer as `status/0`, without the info map.

  `status/0` reads the stored file whole to rescan its version, which is fine
  for the panel and wrong for anything on a hot path — a container start asks
  this per `dsp: true` add-on, and `Vagus.Addon.Watchdog` can drive starts in a
  loop. A directory listing settles the question this asks.
  """
  @spec state() :: :unsupported | :not_configured | :configured
  def state do
    case root() do
      nil -> :unsupported
      dir -> if stored_skels(dir) == [], do: :not_configured, else: :configured
    end
  end

  defp report([]), do: :not_configured

  defp report([path | _rest]) do
    case describe(path, arch(Path.basename(path)), version(path)) do
      {:ok, info} -> {:configured, info}
      # The file was listed and then vanished — report the state that is now
      # true rather than an error the operator cannot act on.
      {:error, _reason} -> :not_configured
    end
  end

  defp configured_root do
    case root() do
      nil -> {:error, :unsupported}
      dir -> {:ok, dir}
    end
  end

  defp check_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > @max_bytes -> {:error, :too_large}
      {:ok, _stat} -> :ok
      {:error, posix} -> {:error, {:unreadable, posix}}
    end
  end

  # Every reader here takes a path this module opens and never joins into
  # another: the caller's own upload temp file, the store's own entry, or the
  # firmware blob sysfs named.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(path), do: wrap_posix(File.read(path))

  # sobelow_skip ["Traversal.FileModule"]
  defp read_header(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @header_bytes) do
            :eof -> {:ok, ""}
            {:error, posix} -> {:error, posix}
            header -> {:ok, header}
          end
        after
          File.close(io)
        end

      {:error, posix} ->
        {:error, posix}
    end
  end

  defp wrap_posix({:ok, value}), do: {:ok, value}
  defp wrap_posix({:error, posix}), do: {:error, {:unreadable, posix}}

  # Machine is checked before class on purpose: it is the field that names the
  # actual mistake. The file an operator most plausibly grabs instead of the
  # skel is the aarch64 *stub* sitting one directory away, and "this is a host
  # library, not a DSP one" points at the right file — where "this is 64-bit"
  # would not. Class, data and type only ever fire for something already
  # claiming to be a Hexagon object, so they read as "corrupt or wrong build"
  # rather than "wrong directory".
  defp check_header(
         <<0x7F, "ELF", class, endianness, _rest_of_ident::binary-size(10), type::little-16,
           machine::little-16>>
       ) do
    cond do
      machine != @em_qdsp6 -> {:error, :not_hexagon}
      class != @elfclass32 -> {:error, :not_32bit}
      endianness != @elfdata2lsb -> {:error, :not_little_endian}
      type != @et_dyn -> {:error, :not_shared_object}
      true -> :ok
    end
  end

  defp check_header(<<0x7F, "ELF", _short::binary>>), do: {:error, :truncated}
  defp check_header(_header), do: {:error, :not_elf}

  # One distinct marker is the file naming itself. None means this is not a
  # skel at all; more than one means the content cannot say which name the
  # loader would need, and guessing would store a file no loader ever finds.
  defp derive_name(contents) do
    case @skel_marker |> Regex.scan(contents) |> Enum.uniq() do
      [[filename, arch]] -> {:ok, filename, "V" <> arch}
      [] -> {:error, :no_skel_marker}
      _several -> {:error, :ambiguous_skel_marker}
    end
  end

  defp version_in(contents) do
    case Regex.run(@aisw_version, contents) do
      [_match, version] -> version
      nil -> nil
    end
  end

  # The destination is built from the file's own content, so the usual
  # "config-derived, not request input" defence does not apply — what makes it
  # safe is the marker's shape. `libQnnHtpV<digits>Skel.so` admits no separator
  # and no `..`, so `Path.join/2` cannot leave the store directory.
  #
  # `.tmp` sibling then rename, like `Vagus.Addon.State.persist/2`: a power cut
  # mid-write must not leave a truncated `.so` that still passes a header check
  # and then fails inside the DSP loader, where nothing reports it.
  # sobelow_skip ["Traversal.FileModule"]
  defp install(dir, filename, contents) do
    dest = Path.join(dir, filename)
    tmp = dest <> ".tmp"

    result =
      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(tmp, contents),
           :ok <- File.rename(tmp, dest) do
        sweep(dir, dest)
      end

    case result do
      :ok -> :ok
      {:error, posix} -> {:error, {:store_failed, posix}}
    end
  end

  # A board has one Hexagon version, and `status/0` reports one file — so an
  # upload replaces the store rather than adding to it. Without this, uploading
  # V73 over V68 would leave both and make what is "stored" a question of sort
  # order. Sweeps stale `.tmp` files too: one left by an interrupted write is
  # invisible to the loader but not to an operator reading the directory.
  #
  # what is removed is whatever the store dir already holds, matched by shape
  # sobelow_skip ["Traversal.FileModule"]
  defp sweep(dir, keep) do
    dir
    |> Path.join("libQnnHtpV*Skel.so*")
    |> Path.wildcard()
    |> Enum.reject(&(&1 == keep))
    |> Enum.each(&File.rm/1)

    :ok
  end

  defp stored_skels(dir) do
    dir
    |> Path.join("libQnnHtpV*Skel.so")
    |> Path.wildcard()
    |> Enum.filter(&arch(Path.basename(&1)))
    |> Enum.sort()
  end

  # Pinned to the whole basename so a name the wildcard admits but the loader
  # would never ask for (`libQnnHtpVxSkel.so`) is not reported as configured.
  defp arch(filename) do
    case Regex.run(@skel_marker, filename) do
      [^filename, digits] -> "V" <> digits
      _other -> nil
    end
  end

  # mtime, not a sidecar: one file is the state, and a sidecar can disagree
  # with it.
  defp describe(path, arch, version) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        {:ok,
         %{
           filename: Path.basename(path),
           arch: arch,
           version: version,
           size: size,
           stored_at: DateTime.from_unix!(mtime)
         }}

      {:error, posix} ->
        {:error, {:unreadable, posix}}
    end
  end

  ## cDSP firmware version

  # The string sits ~69% into a 3.6 MB blob, so there is no bounded read;
  # `check_size/1` is what makes reading it whole safe, exactly as for an
  # upload.
  defp read_cdsp_version do
    with {:ok, path} <- cdsp_firmware_path(),
         :ok <- check_size(path),
         {:ok, contents} <- read_file(path),
         [_match, version] <- Regex.run(@qc_image_version, contents) do
      version
    else
      _absent -> nil
    end
  end

  # sysfs names the blob the running cDSP actually loaded, which is both the
  # authoritative answer and one that survives a board keeping its firmware
  # elsewhere — `rubik_pi3` files its adsp blob under a vendor subdirectory,
  # so this genuinely varies and a literal path would be wrong somewhere.
  defp cdsp_firmware_path do
    remoteproc_root()
    |> Path.join("*/name")
    |> Path.wildcard()
    |> Enum.find(&(sysfs_read(&1) == "cdsp"))
    |> case do
      nil -> :error
      name_path -> firmware_path(Path.dirname(name_path))
    end
  end

  # `Path.safe_relative/1` rather than a bare join: the kernel wrote this
  # value, but it is still the one path in this module derived from a file's
  # contents rather than from configuration.
  defp firmware_path(node_dir) do
    with entry when is_binary(entry) and entry != "" <-
           sysfs_read(Path.join(node_dir, "firmware")),
         {:ok, relative} <- Path.safe_relative(entry) do
      {:ok, Path.join(firmware_root(), relative)}
    else
      _unusable -> :error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp sysfs_read(path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      {:error, _posix} -> nil
    end
  end

  # Overridable only as a test seam; no target sets either.
  defp remoteproc_root,
    do: Application.get_env(:vagus, :remoteproc_root, "/sys/class/remoteproc")

  defp firmware_root, do: Application.get_env(:vagus, :firmware_root, "/lib/firmware")
end
