defmodule Vagus.SSHAccess do
  @moduledoc """
  Device-managed SSH access key.

  On first boot Vagus generates a single ed25519 keypair, persists it, and
  authorizes its **public** half for SSH logins (via
  `NervesSSH.add_authorized_key/1`). The operator downloads the matching
  **private** half from the Vagus admin panel in the Home Assistant sidebar
  and uses it as their SSH identity:

      ssh -i vagus_key root@<hostname>.local

  This is **additive** to any operator keys baked in at build time via
  `NERVES_AUTHORIZED_KEYS` (see `config/target.exs`). `NervesSSH.add_authorized_key/1`
  de-duplicates and appends; this feature must never remove or replace
  existing authorized keys.

  The keypair is generated once and reused across reboots and firmware
  updates — it lives in a DETS file whose path is config-driven
  (`config :vagus, :ssh_access_path`; `/data/ssh_access.dets` on target,
  under `.dev/` on the host). Regeneration is intentionally not exposed; the
  key is the device's stable access identity.

  ## Invariant: the store must be provably `0600`

  The private key is persisted unencrypted, so a key is only ever generated,
  loaded or served once the store file's mode has been set to `0600` **and
  read back to confirm it**. If either step fails the server runs degraded:
  no keypair at all, and every accessor answers `{:error, :unavailable}`.
  It deliberately does not stop — this is a supervised child, and refusing
  to boot over a chmod failure would take the whole device down.

  Boot work (keygen, authorize) runs in `handle_continue/2` so a slow or
  not-yet-ready `nerves_ssh` daemon can't stall the supervisor; authorization
  is retried a few times to ride out the startup race.

  ## Why hand-rolled private-key serialization?

  OTP 28's `:ssh_file.encode/2` can emit an ed25519 *public* key
  (`:auth_keys`) but not the `openssh-key-v1` *private* key format, so the
  private PEM is serialized here (unencrypted, single key). `ssh-keygen -y`
  validates the output round-trips to the same public key.
  """

  use GenServer

  import Bitwise, only: [band: 2]

  require Logger

  alias Vagus.SSHAccess.Keypair

  @ed25519_oid {1, 3, 101, 112}
  @comment ~c"vagus-admin@vagus"
  @key :keypair
  @default_table :ssh_access

  # Authorization retry: nerves_ssh is an independent OTP application that may
  # not have started when we first try to register the key.
  @authorize_attempts 5
  @authorize_retry_ms 2_000

  # -- Client API --

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The OpenSSH `authorized_keys` line for the device's access key.

  `{:error, :unavailable}` when the server is running degraded — see the
  moduledoc's `0600` invariant.
  """
  @spec public_key(GenServer.server()) :: {:ok, String.t()} | {:error, :unavailable}
  def public_key(server \\ __MODULE__), do: GenServer.call(server, :public_key)

  @doc """
  The OpenSSH-format private key PEM. Sensitive — only stream on request.

  `{:error, :unavailable}` when the server is running degraded — see the
  moduledoc's `0600` invariant.
  """
  @spec private_key(GenServer.server()) :: {:ok, String.t()} | {:error, :unavailable}
  def private_key(server \\ __MODULE__), do: GenServer.call(server, :private_key)

  @doc """
  The `SHA256:...` fingerprint of the access key's public half.

  `{:error, :unavailable}` when the server is running degraded — see the
  moduledoc's `0600` invariant.
  """
  @spec fingerprint(GenServer.server()) :: {:ok, String.t()} | {:error, :unavailable}
  def fingerprint(server \\ __MODULE__), do: GenServer.call(server, :fingerprint)

  @doc "Algorithm name for display, e.g. `\"ed25519\"`."
  @spec key_type() :: String.t()
  def key_type, do: "ed25519"

  # -- Server callbacks --

  @impl true
  # path is config-derived (start-up opts / app env), not request input
  # sobelow_skip ["Traversal.FileModule"]
  def init(opts) do
    table_name = Keyword.get(opts, :table, @default_table)
    path = Keyword.get(opts, :dets_path) || dets_path()
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        secure_store(table, path, opts)

      {:error, reason} ->
        Logger.error("SSH access store failed to open #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  # The private key lives here unencrypted, so the mode is both set AND read
  # back: a `File.chmod/2` that silently fails would otherwise leave a
  # world-readable private key. Failing either step runs degraded (no
  # keypair, accessors answer `{:error, :unavailable}`) rather than stopping
  # — see the moduledoc's `0600` invariant.
  #
  # `:chmod_fun` is a test seam for exercising both failure branches.
  #
  # path is config-derived (start-up opts / app env), not request input
  # sobelow_skip ["Traversal.FileModule"]
  defp secure_store(table, path, opts) do
    chmod_fun = Keyword.get(opts, :chmod_fun, &File.chmod/2)

    with :ok <- chmod_fun.(path, 0o600),
         {:ok, %File.Stat{mode: mode}} <- File.stat(path),
         0o600 <- band(mode, 0o777) do
      {:ok, %{table: table, keypair: nil}, {:continue, :ensure_key}}
    else
      mode when is_integer(mode) -> degrade(table, path, "mode is 0#{Integer.to_string(mode, 8)}")
      other -> degrade(table, path, inspect(other))
    end
  end

  defp degrade(table, path, detail) do
    Logger.error(
      "SSH access store #{path} could not be proven mode 0600 (#{detail}) — " <>
        "refusing to generate or serve an SSH access key"
    )

    :dets.close(table)
    {:ok, %{table: nil, keypair: nil}}
  end

  @impl true
  def handle_continue(:ensure_key, state) do
    keypair = load_or_generate(state.table)
    schedule_authorize(keypair.public_key, 1)
    {:noreply, %{state | keypair: keypair}}
  end

  @impl true
  def terminate(_reason, %{table: table}) when table != nil, do: :dets.close(table)
  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call(:public_key, _from, state),
    do: {:reply, field(state, :public_key), state}

  def handle_call(:private_key, _from, state),
    do: {:reply, field(state, :private_key), state}

  def handle_call(:fingerprint, _from, state),
    do: {:reply, field(state, :fingerprint), state}

  defp field(%{keypair: %Keypair{} = keypair}, name), do: {:ok, Map.fetch!(keypair, name)}
  defp field(_state, _name), do: {:error, :unavailable}

  @impl true
  def handle_info({:retry_authorize, public_key, attempt}, state) do
    schedule_authorize(public_key, attempt)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Persistence --

  defp load_or_generate(table) do
    case :dets.lookup(table, @key) do
      [{@key, %{public_key: pub, private_key: priv, fingerprint: fp}}]
      when is_binary(pub) and is_binary(priv) and is_binary(fp) ->
        Logger.info("SSH access key loaded from store")
        %Keypair{public_key: pub, private_key: priv, fingerprint: fp}

      _ ->
        keypair = generate_keypair()

        case persist(table, keypair) do
          :ok ->
            Logger.info("SSH access key generated (#{keypair.fingerprint})")

          {:error, reason} ->
            # Degraded: usable this boot, regenerated next boot.
            Logger.error("SSH access key generated but NOT persisted: #{inspect(reason)}")
        end

        keypair
    end
  end

  defp persist(table, %Keypair{} = keypair) do
    with :ok <- :dets.insert(table, {@key, Map.from_struct(keypair)}) do
      :dets.sync(table)
    end
  end

  # -- Key generation --

  @doc false
  @spec generate_keypair() :: Keypair.t()
  def generate_keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    pub_rec = {{:ECPoint, pub}, {:namedCurve, @ed25519_oid}}

    public_key =
      [{pub_rec, [comment: @comment]}]
      |> :ssh_file.encode(:auth_keys)
      |> :erlang.iolist_to_binary()
      |> String.trim_trailing()

    fingerprint =
      :sha256
      |> :ssh.hostkey_fingerprint(pub_rec)
      |> to_string()

    %Keypair{
      public_key: public_key,
      private_key: encode_private_key(pub, priv),
      fingerprint: fingerprint
    }
  end

  # openssh-key-v1, unencrypted, single ed25519 key. See PROTOCOL.key in the
  # OpenSSH source for the wire layout.
  defp encode_private_key(pub, priv) do
    pub_blob = ssh_string("ssh-ed25519") <> ssh_string(pub)
    # Two equal check ints let a reader detect a bad passphrase; arbitrary for
    # an unencrypted key.
    check = :crypto.strong_rand_bytes(4)

    unpadded =
      check <>
        check <>
        ssh_string("ssh-ed25519") <>
        ssh_string(pub) <>
        ssh_string(priv <> pub) <>
        ssh_string(@comment)

    body =
      "openssh-key-v1\0" <>
        ssh_string("none") <>
        ssh_string("none") <>
        ssh_string("") <>
        <<1::32>> <>
        ssh_string(pub_blob) <>
        ssh_string(pad(unpadded, 8))

    wrapped =
      body
      |> Base.encode64()
      |> wrap(70)

    "-----BEGIN OPENSSH PRIVATE KEY-----\n" <> wrapped <> "\n-----END OPENSSH PRIVATE KEY-----\n"
  end

  defp ssh_string(bin) when is_binary(bin), do: <<byte_size(bin)::32, bin::binary>>
  defp ssh_string(list) when is_list(list), do: ssh_string(:erlang.list_to_binary(list))

  # Pad to a multiple of `block` with the sequence 1, 2, 3, ... as the spec
  # requires.
  defp pad(bin, block) do
    n = rem(block - rem(byte_size(bin), block), block)
    bin <> for(i <- 1..n//1, into: <<>>, do: <<i>>)
  end

  defp wrap(str, width) do
    str
    |> String.to_charlist()
    |> Enum.chunk_every(width)
    |> Enum.map_join("\n", &to_string/1)
  end

  # -- nerves_ssh wiring (target only) --

  # Try to authorize; on a not-yet-ready nerves_ssh daemon, retry a few times.
  defp schedule_authorize(public_key, attempt) do
    case authorize(public_key) do
      :ok ->
        :ok

      :retry when attempt < @authorize_attempts ->
        Process.send_after(
          self(),
          {:retry_authorize, public_key, attempt + 1},
          @authorize_retry_ms
        )

      :retry ->
        Logger.warning(
          "SSH access: gave up authorizing key after #{@authorize_attempts} attempts"
        )
    end
  end

  # `NervesSSH` ships with nerves_pack, a target-only dependency, so the module
  # is absent on the host. Adding is idempotent (the daemon de-dupes and
  # persists to its authorized_keys file).
  defp authorize(public_key) do
    if Code.ensure_loaded?(NervesSSH) do
      try do
        # `apply/3` keeps both the compiler and Dialyzer from resolving this
        # target-only module (nerves_ssh is absent from the host build/PLT).
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(NervesSSH, :add_authorized_key, [public_key])
        Logger.info("SSH access: public key authorized for ssh login")
        :ok
      rescue
        e ->
          Logger.warning("SSH access: could not authorize key: #{inspect(e)}")
          :ok
      catch
        :exit, reason ->
          Logger.debug("SSH access: nerves_ssh not ready yet (#{inspect(reason)})")
          :retry
      end
    else
      Logger.debug("SSH access: NervesSSH unavailable (host) — skipping authorize")
      :ok
    end
  end

  defp dets_path do
    Application.get_env(:vagus, :ssh_access_path) || default_dets_path()
  end

  # The real paths are config-driven (`:ssh_access_path`, set per environment
  # in config/target.exs and config/host.exs), same as every other writable
  # path in this app. This is only the last-resort fallback for the key being
  # unset — `mix test` (which injects `:dets_path` per instance) and a bare
  # `mix run` on the host.
  defp default_dets_path do
    Path.join([File.cwd!(), "_build", "ssh_access.dets"])
  end
end
